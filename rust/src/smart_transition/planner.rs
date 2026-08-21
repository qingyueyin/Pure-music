// 纯规划器。确定性分派：相同输入永远生成相同计划。
// 规划阈值与规则固定（文档第 7 节），不读取文件、不查询播放列表或数据库。

use crate::smart_transition::config::{validate_analysis_config, AnalysisConfig};
use crate::smart_transition::gain_curve::{
    build_gain_curve, intro_protection_of, GainInputs, PlanError,
};
use crate::smart_transition::model::{
    validate_track_profile, GainPoint, TrackProfile, TransitionDiagnostic, TransitionMode,
    TransitionPlan, GAIN_CURVE_POINTS,
};

pub const FLOAT_EPS: f64 = 1e-6;
pub const BEAT_STABILITY_MIN: f64 = 0.60;
pub const BEAT_CONFIDENCE_MIN: f64 = 0.48;
pub const TEMPO_RATIO_TOLERANCE: f64 = 0.04;
pub const PHASE_ALIGNMENT_RATIO_TOLERANCE: f64 = 0.06;
pub const MIN_DURATION_MS: f64 = 2000.0;
pub const MAX_DURATION_MS: f64 = 12000.0;
pub const CROSS_ALBUM_MIN_DURATION_MS: f64 = 2000.0;
pub const CROSS_ALBUM_MAX_DURATION_MS: f64 = 3000.0;
pub const DOWNBEAD_GRID_THRESHOLD: f64 = 0.58;
pub const FOLD_CANDIDATES: [f64; 3] = [0.5, 1.0, 2.0];
pub const RATIO_RANGE_MIN: f64 = 2.0 / 3.0;
pub const RATIO_RANGE_MAX: f64 = 1.5;

#[derive(Debug, Clone)]
pub struct Relationship {
    /// 调用方提供的明确连续媒体标记；专辑和曲号不能单独作为依据。
    pub is_gapless_candidate: bool,
    pub is_same_album: bool,
}

#[derive(Debug, Clone)]
pub struct RuntimeConstraints {
    pub user_speed: f64,
    pub pitch: f64,
    pub tempo_at_cue_available: bool,
    /// BASS_FX tempo 的 capability 范围（百分比）。
    pub bass_tempo_min_percent: f64,
    pub bass_tempo_max_percent: f64,
    /// 两侧 ReplayGain（dB），用于增益曲线峰值约束。
    pub outgoing_replay_gain_db: f64,
    pub incoming_replay_gain_db: f64,
}

fn diag(code: &str, detail: &str) -> TransitionDiagnostic {
    TransitionDiagnostic {
        code: code.to_string(),
        detail: detail.to_string(),
    }
}

fn flat_curve() -> Vec<GainPoint> {
    vec![
        GainPoint {
            outgoing: 1.0,
            incoming: 1.0
        };
        GAIN_CURVE_POINTS
    ]
}

fn gain_inputs(
    outgoing: &TrackProfile,
    incoming: &TrackProfile,
    constraints: &RuntimeConstraints,
) -> GainInputs {
    GainInputs {
        outgoing_exit: outgoing.exit.clone(),
        incoming_entrance: incoming.entrance.clone(),
        incoming_integrated_rms_dbfs: incoming.integrated_rms_dbfs,
        outgoing_peak_dbfs: outgoing.peak_dbfs,
        incoming_peak_dbfs: incoming.peak_dbfs,
        outgoing_replay_gain_db: constraints.outgoing_replay_gain_db,
        incoming_replay_gain_db: constraints.incoming_replay_gain_db,
    }
}

/// 7.1 分派：GAPLESS -> 跨专辑保守衔接 -> SILENCE_TRIM（区域不足）-> 节拍 -> ENERGY_CROSSFADE。
/// 节拍准入失败或无法 cue 时，失败原因合并进 ENERGY_CROSSFADE 的 diagnostics，不丢失降级依据。
pub fn plan_transition(
    outgoing: &TrackProfile,
    incoming: &TrackProfile,
    relationship: &Relationship,
    constraints: &RuntimeConstraints,
    config: &AnalysisConfig,
) -> Result<TransitionPlan, PlanError> {
    validate_track_profile(outgoing)
        .map_err(|error| PlanError::InvalidInput(format!("outgoing profile: {error}")))?;
    validate_track_profile(incoming)
        .map_err(|error| PlanError::InvalidInput(format!("incoming profile: {error}")))?;
    validate_analysis_config(config)
        .map_err(|error| PlanError::InvalidInput(format!("analysis config: {error}")))?;
    validate_constraints(constraints)?;
    if relationship.is_gapless_candidate {
        return Ok(gapless_plan(outgoing, incoming, constraints));
    }
    if !relationship.is_same_album {
        return conservative_cross_album_plan(outgoing, incoming, constraints);
    }
    let exit_len = outgoing.exit.end_ms - outgoing.exit.start_ms;
    let entrance_len = incoming.entrance.end_ms - incoming.entrance.start_ms;
    if exit_len < MIN_DURATION_MS || entrance_len < MIN_DURATION_MS {
        return Ok(silence_trim_plan(
            outgoing,
            incoming,
            constraints,
            "region shorter than 2000 ms",
        ));
    }
    let (beat, beat_notes) = beat_transition_plan(outgoing, incoming, constraints, config)?;
    if let Some(plan) = beat {
        return Ok(plan);
    }
    let mut plan = energy_crossfade_plan(outgoing, incoming, constraints)?;
    plan.diagnostics.extend(beat_notes);
    Ok(plan)
}

fn conservative_cross_album_plan(
    outgoing: &TrackProfile,
    incoming: &TrackProfile,
    constraints: &RuntimeConstraints,
) -> Result<TransitionPlan, PlanError> {
    let inputs = gain_inputs(outgoing, incoming, constraints);
    let intro = intro_protection_of(&inputs);
    let activity = outgoing
        .exit
        .onset_density
        .max(incoming.entrance.onset_density);
    let intensity = activity.max(intro).clamp(0.0, 1.0);
    let requested_ms = CROSS_ALBUM_MAX_DURATION_MS
        - intensity * (CROSS_ALBUM_MAX_DURATION_MS - CROSS_ALBUM_MIN_DURATION_MS);
    let exit_len = outgoing.exit.end_ms - outgoing.exit.start_ms;
    let entrance_len = incoming.entrance.end_ms - incoming.entrance.start_ms;
    let available_duration_ms =
        (exit_len / constraints.user_speed).min(entrance_len / constraints.user_speed);
    let duration_ms = requested_ms.min(available_duration_ms);
    if duration_ms < CROSS_ALBUM_MIN_DURATION_MS {
        let mut plan = silence_trim_plan(
            outgoing,
            incoming,
            constraints,
            "cross-album boundary window is too short",
        );
        plan.diagnostics
            .push(diag("relationship", "different_album"));
        return Ok(plan);
    }

    let (outgoing_bpm, incoming_bpm, raw_ratio, matched_ratio, fold_factor) =
        tempo_fields(outgoing, incoming);
    let confidence = (outgoing.exit.boundary_confidence * incoming.entrance.boundary_confidence)
        .sqrt()
        .clamp(0.0, 1.0);
    Ok(TransitionPlan {
        mode: TransitionMode::EnergyCrossfade,
        confidence,
        confidence_tier: 1,
        outgoing_bpm,
        incoming_bpm,
        outgoing_cue_ms: (outgoing.exit.end_ms - duration_ms * constraints.user_speed).round()
            as u64,
        incoming_cue_ms: incoming.entrance.start_ms.round() as u64,
        duration_ms: duration_ms.round() as u64,
        raw_ratio,
        matched_ratio,
        fold_factor,
        outgoing_effective_speed: constraints.user_speed,
        bass_tempo_percent: 0.0,
        gain_curve: build_gain_curve(&inputs)?.to_vec(),
        diagnostics: vec![
            diag("mode", "energy_crossfade"),
            diag("relationship", "different_album"),
            diag(
                "boundary",
                &format!("activity={activity:.4} intro={intro:.4}"),
            ),
        ],
    })
}

fn validate_constraints(constraints: &RuntimeConstraints) -> Result<(), PlanError> {
    for (name, value) in [
        ("user_speed", constraints.user_speed),
        ("pitch", constraints.pitch),
        ("bass_tempo_min_percent", constraints.bass_tempo_min_percent),
        ("bass_tempo_max_percent", constraints.bass_tempo_max_percent),
        (
            "outgoing_replay_gain_db",
            constraints.outgoing_replay_gain_db,
        ),
        (
            "incoming_replay_gain_db",
            constraints.incoming_replay_gain_db,
        ),
    ] {
        if !value.is_finite() {
            return Err(PlanError::InvalidInput(format!("{name} must be finite")));
        }
    }
    if constraints.user_speed <= 0.0 {
        return Err(PlanError::InvalidInput(
            "user_speed must be greater than zero".to_string(),
        ));
    }
    if constraints.bass_tempo_min_percent > constraints.bass_tempo_max_percent {
        return Err(PlanError::InvalidInput(
            "tempo capability range is inverted".to_string(),
        ));
    }
    Ok(())
}

fn tempo_fields(outgoing: &TrackProfile, incoming: &TrackProfile) -> (f64, f64, f64, f64, f64) {
    let outgoing_bpm = outgoing.tempo.as_ref().map_or(0.0, |tempo| tempo.bpm);
    let incoming_bpm = incoming.tempo.as_ref().map_or(0.0, |tempo| tempo.bpm);
    if outgoing_bpm <= 0.0 || incoming_bpm <= 0.0 {
        return (outgoing_bpm, incoming_bpm, 1.0, 1.0, 1.0);
    }
    let raw_ratio = incoming_bpm / outgoing_bpm;
    let (matched_ratio, fold_factor) = select_fold(raw_ratio).unwrap_or((raw_ratio, 1.0));
    (
        outgoing_bpm,
        incoming_bpm,
        raw_ratio,
        matched_ratio,
        fold_factor,
    )
}

fn gapless_plan(
    outgoing: &TrackProfile,
    incoming: &TrackProfile,
    constraints: &RuntimeConstraints,
) -> TransitionPlan {
    let (outgoing_bpm, incoming_bpm, raw_ratio, matched_ratio, fold_factor) =
        tempo_fields(outgoing, incoming);
    TransitionPlan {
        mode: TransitionMode::Gapless,
        confidence: 1.0,
        confidence_tier: 3,
        outgoing_bpm,
        incoming_bpm,
        outgoing_cue_ms: outgoing.duration_ms,
        incoming_cue_ms: 0,
        duration_ms: 0,
        raw_ratio,
        matched_ratio,
        fold_factor,
        outgoing_effective_speed: constraints.user_speed,
        bass_tempo_percent: 0.0,
        gain_curve: flat_curve(),
        diagnostics: vec![diag("mode", "gapless")],
    }
}

fn silence_trim_plan(
    outgoing: &TrackProfile,
    incoming: &TrackProfile,
    constraints: &RuntimeConstraints,
    reason: &str,
) -> TransitionPlan {
    let (outgoing_bpm, incoming_bpm, raw_ratio, matched_ratio, fold_factor) =
        tempo_fields(outgoing, incoming);
    TransitionPlan {
        mode: TransitionMode::SilenceTrim,
        confidence: 1.0,
        confidence_tier: 1,
        outgoing_bpm,
        incoming_bpm,
        outgoing_cue_ms: outgoing.audible_end_ms,
        incoming_cue_ms: incoming.audible_start_ms,
        duration_ms: 0,
        raw_ratio,
        matched_ratio,
        fold_factor,
        outgoing_effective_speed: constraints.user_speed,
        bass_tempo_percent: 0.0,
        gain_curve: flat_curve(),
        diagnostics: vec![diag("mode", "silence_trim"), diag("reason", reason)],
    }
}

/// 节拍准入与规划（7.2/7.3）。返回 None 表示不满足准入或无法 cue，降级到能量交叉淡化。
/// 节拍准入与规划（7.2/7.3）。失败时返回 (None, diagnostics)，降级原因由调用方合并进 fallback 计划。
fn beat_transition_plan(
    outgoing: &TrackProfile,
    incoming: &TrackProfile,
    constraints: &RuntimeConstraints,
    config: &AnalysisConfig,
) -> Result<(Option<TransitionPlan>, Vec<TransitionDiagnostic>), PlanError> {
    let (out_tempo, inc_tempo) = match (&outgoing.tempo, &incoming.tempo) {
        (Some(a), Some(b)) => (a, b),
        _ => return Ok((None, Vec::new())),
    };
    let mut diagnostics = Vec::new();
    if out_tempo.stability < BEAT_STABILITY_MIN || inc_tempo.stability < BEAT_STABILITY_MIN {
        diagnostics.push(diag("beat_admission", "stability below 0.60"));
        return Ok((None, diagnostics));
    }
    if out_tempo.beat_confidence < BEAT_CONFIDENCE_MIN
        || inc_tempo.beat_confidence < BEAT_CONFIDENCE_MIN
    {
        diagnostics.push(diag("beat_admission", "beat_confidence below 0.48"));
        return Ok((None, diagnostics));
    }
    if constraints.pitch.abs() > FLOAT_EPS {
        diagnostics.push(diag("beat_admission", "pitch not zero"));
        return Ok((None, diagnostics));
    }
    let raw_ratio = inc_tempo.bpm / out_tempo.bpm;
    let fold = select_fold(raw_ratio);
    let (matched_ratio, fold_factor) = match fold {
        Some(v) => v,
        None => {
            diagnostics.push(diag("beat_admission", "no fold candidate in [2/3, 1.5]"));
            return Ok((None, diagnostics));
        }
    };
    let ratio_delta = (matched_ratio - 1.0).abs();
    if ratio_delta - PHASE_ALIGNMENT_RATIO_TOLERANCE > FLOAT_EPS {
        diagnostics.push(diag(
            "beat_admission",
            "matched_ratio deviates more than 0.06",
        ));
        return Ok((None, diagnostics));
    }

    let aligned = ratio_delta <= FLOAT_EPS;
    let (mode, outgoing_effective_speed, bass_tempo_percent) = if aligned {
        (TransitionMode::BeatAligned, constraints.user_speed, 0.0)
    } else if constraints.tempo_at_cue_available
        && (constraints.user_speed - 1.0).abs() <= FLOAT_EPS
        && ratio_delta - TEMPO_RATIO_TOLERANCE <= FLOAT_EPS
    {
        let percent = ((constraints.user_speed * matched_ratio - 1.0) * 1000.0).round() / 10.0;
        if percent < constraints.bass_tempo_min_percent - FLOAT_EPS
            || percent > constraints.bass_tempo_max_percent + FLOAT_EPS
        {
            diagnostics.push(diag(
                "beat_admission",
                "required tempo is outside capability range",
            ));
            return Ok((None, diagnostics));
        }
        let effective = 1.0 + percent / 100.0;
        (TransitionMode::BeatMatched, effective, percent)
    } else {
        diagnostics.push(diag(
            "phase_alignment",
            "near-tempo alignment without tempo change",
        ));
        (TransitionMode::BeatAligned, constraints.user_speed, 0.0)
    };
    diagnostics.push(diag(
        "mode",
        match mode {
            TransitionMode::BeatMatched => "beat_matched",
            _ => "beat_aligned",
        },
    ));

    // 拍数与网格（7.3）
    let phase_only = !aligned && mode == TransitionMode::BeatAligned;
    let grid_beats: u32 = if phase_only {
        4
    } else if out_tempo.downbeat_confidence >= config.downbeat_threshold
        && inc_tempo.downbeat_confidence >= config.downbeat_threshold
    {
        16
    } else {
        4
    };
    let activity = (outgoing.exit.onset_density + incoming.entrance.onset_density) / 2.0;
    let intro = intro_protection_of(&gain_inputs(outgoing, incoming, constraints));
    let transition_beats: u32 = if phase_only {
        8
    } else if activity >= 0.36 || intro >= 0.72 {
        4
    } else if activity >= 0.24 || intro >= 0.45 {
        8
    } else {
        16
    };
    diagnostics.push(diag(
        "grid",
        &format!(
            "grid={grid_beats} beats={transition_beats} activity={activity:.4} intro={intro:.4}"
        ),
    ));

    let beat_ms = 60000.0 / (inc_tempo.bpm * constraints.user_speed);
    let mut duration_ms = transition_beats as f64 * beat_ms;
    duration_ms = duration_ms.clamp(MIN_DURATION_MS, MAX_DURATION_MS);

    // 可用时长检查：转场窗口不能超出两侧区域
    let exit_len = outgoing.exit.end_ms - outgoing.exit.start_ms;
    let entrance_len = incoming.entrance.end_ms - incoming.entrance.start_ms;
    if duration_ms * outgoing_effective_speed > exit_len
        || duration_ms * constraints.user_speed > entrance_len
    {
        diagnostics.push(diag("beat_cue", "available duration below 2000 ms"));
        return Ok((None, diagnostics));
    }

    // incoming cue：入口区内第一个合法网格边界，淡入窗口必须完整落在入口区内
    let max_inc_pos = duration_ms * constraints.user_speed;
    let incoming_grid_anchor =
        closest_beat_index(&inc_tempo.beat_times_ms, inc_tempo.downbeat_offset_ms)
            .ok_or_else(|| PlanError::InvalidInput("incoming beat grid is empty".to_string()))?;
    let incoming_cue_ms = match first_grid_boundary(
        &inc_tempo.beat_times_ms,
        incoming_grid_anchor,
        grid_beats,
        incoming.entrance.start_ms,
        incoming.entrance.end_ms,
        max_inc_pos,
    ) {
        Some(v) => v,
        None => {
            diagnostics.push(diag("beat_cue", "no in-bounds grid boundary in entrance"));
            return Ok((None, diagnostics));
        }
    };
    // outgoing cue：出口区内最接近目标的网格边界，且淡出窗口必须完整落在出口区内
    let target_out = outgoing.exit.end_ms - duration_ms * outgoing_effective_speed;
    let max_cue_pos = duration_ms * outgoing_effective_speed;
    let outgoing_grid_anchor =
        closest_beat_index(&out_tempo.beat_times_ms, out_tempo.downbeat_offset_ms)
            .ok_or_else(|| PlanError::InvalidInput("outgoing beat grid is empty".to_string()))?;
    let outgoing_cue_ms = match closest_grid_boundary(
        &out_tempo.beat_times_ms,
        outgoing_grid_anchor,
        grid_beats,
        outgoing.exit.start_ms,
        outgoing.exit.end_ms,
        target_out,
        max_cue_pos,
    ) {
        Some(v) => v,
        None => {
            diagnostics.push(diag("beat_cue", "no in-bounds grid boundary in exit"));
            return Ok((None, diagnostics));
        }
    };

    let confidence = out_tempo.beat_confidence.min(inc_tempo.beat_confidence);
    let confidence_tier = match mode {
        TransitionMode::BeatMatched => 3,
        _ => 2,
    };
    let gain_curve = build_gain_curve(&gain_inputs(outgoing, incoming, constraints))?;
    let plan = TransitionPlan {
        mode,
        confidence,
        confidence_tier,
        outgoing_bpm: out_tempo.bpm,
        incoming_bpm: inc_tempo.bpm,
        outgoing_cue_ms: outgoing_cue_ms.round() as u64,
        incoming_cue_ms: incoming_cue_ms.round() as u64,
        duration_ms: duration_ms.round() as u64,
        raw_ratio,
        matched_ratio,
        fold_factor,
        outgoing_effective_speed,
        bass_tempo_percent,
        gain_curve: gain_curve.to_vec(),
        diagnostics,
    };
    Ok((Some(plan), Vec::new()))
}

/// 折叠选择（7.2）：尝试 raw/2、raw、raw*2，保留 [2/3, 1.5]，选离 1.0 最近者；
/// 距离相同优先不折叠，再选数值较小者。返回 (matched_ratio, fold_factor)。
fn select_fold(raw_ratio: f64) -> Option<(f64, f64)> {
    let mut best: Option<(f64, f64)> = None;
    let mut best_dist = f64::INFINITY;
    for factor in FOLD_CANDIDATES {
        let m = raw_ratio * factor;
        if m < RATIO_RANGE_MIN || m > RATIO_RANGE_MAX {
            continue;
        }
        let dist = (m - 1.0).abs();
        let tie = (dist - best_dist).abs() <= FLOAT_EPS;
        let prefer = match best {
            None => true,
            Some((bm, bf)) => {
                if !tie {
                    dist < best_dist
                } else {
                    let cf = (factor - 1.0).abs();
                    let bf = (bf - 1.0).abs();
                    if (cf - bf).abs() > FLOAT_EPS {
                        cf < bf
                    } else {
                        m < bm
                    }
                }
            }
        };
        if prefer {
            best = Some((m, factor));
            best_dist = dist;
        }
    }
    best
}

/// 入口区 [start, end] 内第一个合法网格边界；
/// 候选还需满足 `t + max_cue_pos <= end`，保证淡入窗口完整落在入口区内（与出口侧对称）。
fn first_grid_boundary(
    beats: &[f64],
    grid_anchor: usize,
    grid_beats: u32,
    start_ms: f64,
    end_ms: f64,
    max_cue_pos: f64,
) -> Option<f64> {
    beats
        .iter()
        .enumerate()
        .filter(|(i, &t)| {
            is_grid_boundary(*i, grid_anchor, grid_beats as usize)
                && t >= start_ms
                && t <= end_ms
                && t + max_cue_pos <= end_ms
        })
        .map(|(_, &t)| t)
        .next()
}

/// 出口区 [start, end] 内最接近 target 的网格边界；
/// 候选还需满足 `t + max_cue_pos <= end`，保证淡出窗口完整落在出口区内，不落出分析区域。
fn closest_grid_boundary(
    beats: &[f64],
    grid_anchor: usize,
    grid_beats: u32,
    start_ms: f64,
    end_ms: f64,
    target_ms: f64,
    max_cue_pos: f64,
) -> Option<f64> {
    beats
        .iter()
        .enumerate()
        .filter(|(i, &t)| {
            is_grid_boundary(*i, grid_anchor, grid_beats as usize)
                && t >= start_ms
                && t <= end_ms
                && t + max_cue_pos <= end_ms
        })
        .map(|(_, &t)| t)
        .min_by(|a, b| {
            let da = (a - target_ms).abs();
            let db = (b - target_ms).abs();
            da.total_cmp(&db)
        })
}

fn closest_beat_index(beats: &[f64], target_ms: f64) -> Option<usize> {
    beats
        .iter()
        .enumerate()
        .min_by(|(_, left), (_, right)| {
            (*left - target_ms)
                .abs()
                .total_cmp(&(*right - target_ms).abs())
        })
        .map(|(index, _)| index)
}

fn is_grid_boundary(index: usize, anchor: usize, grid_beats: usize) -> bool {
    index.abs_diff(anchor) % grid_beats == 0
}

/// 能量交叉淡化（7.4）。
fn energy_crossfade_plan(
    outgoing: &TrackProfile,
    incoming: &TrackProfile,
    constraints: &RuntimeConstraints,
) -> Result<TransitionPlan, PlanError> {
    let intro = intro_protection_of(&gain_inputs(outgoing, incoming, constraints));
    let requested_ms = ((1.0 - 0.35 * intro) * 4500.0).round().max(MIN_DURATION_MS);
    let exit_len = outgoing.exit.end_ms - outgoing.exit.start_ms;
    let entrance_len = incoming.entrance.end_ms - incoming.entrance.start_ms;
    let available_duration_ms =
        (exit_len / constraints.user_speed).min(entrance_len / constraints.user_speed);
    let duration_ms = requested_ms.min(available_duration_ms);
    if duration_ms < MIN_DURATION_MS {
        return Ok(silence_trim_plan(
            outgoing,
            incoming,
            constraints,
            "energy duration below 2000 ms",
        ));
    }
    let outgoing_cue_ms =
        (outgoing.exit.end_ms - duration_ms * constraints.user_speed).round() as u64;
    let incoming_cue_ms = incoming.entrance.start_ms.round() as u64;
    let confidence = (outgoing.exit.boundary_confidence * incoming.entrance.boundary_confidence)
        .sqrt()
        .clamp(0.0, 1.0);
    let gain_curve = build_gain_curve(&gain_inputs(outgoing, incoming, constraints))?.to_vec();
    let (outgoing_bpm, incoming_bpm, raw_ratio, matched_ratio, fold_factor) =
        tempo_fields(outgoing, incoming);
    Ok(TransitionPlan {
        mode: TransitionMode::EnergyCrossfade,
        confidence,
        confidence_tier: 1,
        outgoing_bpm,
        incoming_bpm,
        outgoing_cue_ms,
        incoming_cue_ms,
        duration_ms: duration_ms.round() as u64,
        raw_ratio,
        matched_ratio,
        fold_factor,
        outgoing_effective_speed: constraints.user_speed,
        bass_tempo_percent: 0.0,
        gain_curve,
        diagnostics: vec![diag("mode", "energy_crossfade")],
    })
}
