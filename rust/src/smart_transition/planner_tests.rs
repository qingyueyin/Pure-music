// 纯规划器测试。

use crate::smart_transition::config::AnalysisConfig;
use crate::smart_transition::model::{
    validate_transition_plan, RegionProfile, TempoProfile, TrackProfile, TransitionMode,
    TransitionPlan,
};
use crate::smart_transition::planner::{plan_transition, Relationship, RuntimeConstraints};

fn region(start_ms: f64, end_ms: f64) -> RegionProfile {
    RegionProfile {
        start_ms,
        end_ms,
        average_energy_dbfs: -12.0,
        onset_density: 0.3,
        boundary_confidence: 0.7,
    }
}

fn tempo(bpm: f64, stability: f64, beat_conf: f64, downbeat_conf: f64) -> TempoProfile {
    let beat_len = 60000.0 / bpm;
    let n = (240000.0 / beat_len).floor() as usize + 1;
    TempoProfile {
        bpm,
        beat_times_ms: (0..n).map(|i| i as f64 * beat_len).collect(),
        downbeat_offset_ms: 0.0,
        beat_confidence: beat_conf,
        downbeat_confidence: downbeat_conf,
        stability,
    }
}

fn profile(
    key: &str,
    bpm: f64,
    stability: f64,
    beat_conf: f64,
    downbeat_conf: f64,
    exit: RegionProfile,
) -> TrackProfile {
    TrackProfile {
        profile_key: key.to_string(),
        duration_ms: 240000,
        audible_start_ms: 200,
        audible_end_ms: 239000,
        integrated_rms_dbfs: -14.0,
        peak_dbfs: -2.0,
        tempo: Some(tempo(bpm, stability, beat_conf, downbeat_conf)),
        entrance: region(0.0, 8000.0),
        exit,
        analysis_version: 1,
        config_hash: "test".to_string(),
    }
}

fn constraints(speed: f64, tempo_at_cue: bool) -> RuntimeConstraints {
    RuntimeConstraints {
        user_speed: speed,
        pitch: 0.0,
        tempo_at_cue_available: tempo_at_cue,
        bass_tempo_min_percent: -50.0,
        bass_tempo_max_percent: 50.0,
        outgoing_replay_gain_db: 0.0,
        incoming_replay_gain_db: 0.0,
    }
}

fn config() -> AnalysisConfig {
    AnalysisConfig::default()
}

fn full_exit() -> RegionProfile {
    region(232000.0, 240000.0)
}

/// 场景输入（golden 生成与对比共用）。
struct Scenario {
    name: &'static str,
    outgoing: TrackProfile,
    incoming: TrackProfile,
    relationship: Relationship,
    constraints: RuntimeConstraints,
}

fn scenarios() -> Vec<Scenario> {
    let beat_out = profile("out-120", 120.0, 0.75, 0.8, 0.6, full_exit());
    let beat_in = profile("in-120", 120.0, 0.75, 0.8, 0.6, full_exit());
    let beat_match_in = profile("in-123", 123.0, 0.75, 0.8, 0.6, full_exit());
    let energy_out = profile("out-130", 130.0, 0.75, 0.8, 0.6, full_exit());
    let energy_in = profile("in-100", 100.0, 0.75, 0.8, 0.6, full_exit());
    let trim_out = profile(
        "out-trim",
        120.0,
        0.75,
        0.8,
        0.6,
        region(238500.0, 240000.0),
    );
    let trim_in = profile("in-trim", 120.0, 0.75, 0.8, 0.6, full_exit());
    vec![
        Scenario {
            name: "gapless",
            outgoing: beat_out.clone(),
            incoming: beat_in.clone(),
            relationship: Relationship {
                is_gapless_candidate: true,
                is_same_album: true,
            },
            constraints: constraints(1.0, false),
        },
        Scenario {
            name: "beat_aligned",
            outgoing: beat_out.clone(),
            incoming: beat_in.clone(),
            relationship: Relationship {
                is_gapless_candidate: false,
                is_same_album: true,
            },
            constraints: constraints(1.0, false),
        },
        Scenario {
            name: "beat_matched",
            outgoing: beat_out.clone(),
            incoming: beat_match_in,
            relationship: Relationship {
                is_gapless_candidate: false,
                is_same_album: true,
            },
            constraints: constraints(1.0, true),
        },
        Scenario {
            name: "energy",
            outgoing: energy_out,
            incoming: energy_in,
            relationship: Relationship {
                is_gapless_candidate: false,
                is_same_album: true,
            },
            constraints: constraints(1.0, false),
        },
        Scenario {
            name: "silence_trim",
            outgoing: trim_out,
            incoming: trim_in,
            relationship: Relationship {
                is_gapless_candidate: false,
                is_same_album: true,
            },
            constraints: constraints(1.0, false),
        },
    ]
}

fn plan_of(s: &Scenario) -> TransitionPlan {
    plan_transition(
        &s.outgoing,
        &s.incoming,
        &s.relationship,
        &s.constraints,
        &config(),
    )
    .unwrap()
}

fn assert_plan_eq(a: &TransitionPlan, b: &TransitionPlan, label: &str) {
    assert_eq!(a.mode, b.mode, "{label}: mode");
    assert_eq!(a.confidence_tier, b.confidence_tier, "{label}: tier");
    assert_eq!(a.outgoing_cue_ms, b.outgoing_cue_ms, "{label}: out_cue");
    assert_eq!(a.incoming_cue_ms, b.incoming_cue_ms, "{label}: in_cue");
    assert_eq!(a.duration_ms, b.duration_ms, "{label}: duration");
    for (field, x, y) in [
        ("confidence", a.confidence, b.confidence),
        ("outgoing_bpm", a.outgoing_bpm, b.outgoing_bpm),
        ("incoming_bpm", a.incoming_bpm, b.incoming_bpm),
        ("raw_ratio", a.raw_ratio, b.raw_ratio),
        ("matched_ratio", a.matched_ratio, b.matched_ratio),
        ("fold_factor", a.fold_factor, b.fold_factor),
        (
            "outgoing_effective_speed",
            a.outgoing_effective_speed,
            b.outgoing_effective_speed,
        ),
        (
            "bass_tempo_percent",
            a.bass_tempo_percent,
            b.bass_tempo_percent,
        ),
    ] {
        assert!((x - y).abs() < 1e-9, "{label}: {field} {x} vs {y}");
    }
    assert_eq!(a.gain_curve.len(), b.gain_curve.len(), "{label}: curve len");
    for (i, (ga, gb)) in a.gain_curve.iter().zip(b.gain_curve.iter()).enumerate() {
        assert!(
            (ga.outgoing - gb.outgoing).abs() < 1e-12,
            "{label}: curve[{i}].outgoing"
        );
        assert!(
            (ga.incoming - gb.incoming).abs() < 1e-12,
            "{label}: curve[{i}].incoming"
        );
    }
    assert_eq!(
        a.diagnostics.len(),
        b.diagnostics.len(),
        "{label}: diagnostics len"
    );
    for (da, db) in a.diagnostics.iter().zip(b.diagnostics.iter()) {
        assert_eq!(da.code, db.code, "{label}: diag code");
        assert_eq!(da.detail, db.detail, "{label}: diag detail");
    }
}

#[test]
fn plan_goldens_match() {
    let golden: serde_json::Value =
        serde_json::from_str(include_str!("golden/plans_v1.json")).unwrap();
    for s in scenarios() {
        let expected: TransitionPlan = serde_json::from_value(golden[s.name].clone()).unwrap();
        let actual = plan_of(&s);
        assert_plan_eq(&actual, &expected, s.name);
    }
}

#[test]
fn threshold_boundaries_are_exact() {
    // stability 0.60 边界：0.5999 不过，0.60 过
    let out = profile("out-b1", 120.0, 0.5999, 0.8, 0.6, full_exit());
    let inc = profile("in-b1", 120.0, 0.75, 0.8, 0.6, full_exit());
    let rel = Relationship {
        is_gapless_candidate: false,
        is_same_album: true,
    };
    let p = plan_transition(&out, &inc, &rel, &constraints(1.0, false), &config()).unwrap();
    assert_eq!(
        p.mode,
        TransitionMode::EnergyCrossfade,
        "stability 0.5999 must not pass"
    );
    let out2 = profile("out-b2", 120.0, 0.60, 0.8, 0.6, full_exit());
    let p2 = plan_transition(&out2, &inc, &rel, &constraints(1.0, false), &config()).unwrap();
    assert_eq!(
        p2.mode,
        TransitionMode::BeatAligned,
        "stability 0.60 must pass"
    );

    // beat_confidence 0.48 边界
    let out3 = profile("out-b3", 120.0, 0.75, 0.479, 0.6, full_exit());
    let p3 = plan_transition(&out3, &inc, &rel, &constraints(1.0, false), &config()).unwrap();
    assert_eq!(
        p3.mode,
        TransitionMode::EnergyCrossfade,
        "beat_confidence 0.479 must not pass"
    );

    // matched_ratio 0.04 边界：124 BPM 对 120 -> 1.0333 通过；129 -> 1.075 不通过
    let out4 = profile("out-b4", 120.0, 0.75, 0.8, 0.6, full_exit());
    let inc4 = profile("in-b4", 124.0, 0.75, 0.8, 0.6, full_exit());
    let p4 = plan_transition(&out4, &inc4, &rel, &constraints(1.0, true), &config()).unwrap();
    assert_eq!(
        p4.mode,
        TransitionMode::BeatMatched,
        "matched 1.0333 must be beat_matched"
    );
    let inc5 = profile("in-b5", 129.0, 0.75, 0.8, 0.6, full_exit());
    let p5 = plan_transition(&out4, &inc5, &rel, &constraints(1.0, true), &config()).unwrap();
    assert_eq!(
        p5.mode,
        TransitionMode::EnergyCrossfade,
        "matched 1.075 must downgrade"
    );
}

#[test]
fn degradation_reason_is_preserved() {
    // 130 vs 100 BPM：matched_ratio 偏离 0.06 → 降级 energy 时必须携带失败原因
    let out = profile("out-dr", 130.0, 0.75, 0.8, 0.6, full_exit());
    let inc = profile("in-dr", 100.0, 0.75, 0.8, 0.6, full_exit());
    let rel = Relationship {
        is_gapless_candidate: false,
        is_same_album: true,
    };
    let p = plan_transition(&out, &inc, &rel, &constraints(1.0, false), &config()).unwrap();
    assert_eq!(p.mode, TransitionMode::EnergyCrossfade);
    assert!(
        p.diagnostics.iter().any(|d| d.code == "beat_admission"),
        "降级原因必须保留在 energy 计划的 diagnostics 中"
    );
}

fn region_with_density(start_ms: f64, end_ms: f64, density: f64) -> RegionProfile {
    let mut r = region(start_ms, end_ms);
    r.onset_density = density;
    r
}

#[test]
fn beat_cue_stays_in_analysis_region() {
    // beat_matched（有效速度 1.025）+ 4 拍网格 + 高活跃度（4 beats -> duration 2000ms）：
    // target=237950 时 238000 边界会让淡出落界（238000+2050>240000），必须被过滤到 236000
    let out = TrackProfile {
        profile_key: "out-cue2".to_string(),
        duration_ms: 240000,
        audible_start_ms: 200,
        audible_end_ms: 239000,
        integrated_rms_dbfs: -14.0,
        peak_dbfs: -2.0,
        tempo: Some(tempo(120.0, 0.75, 0.8, 0.5)),
        entrance: region_with_density(0.0, 8000.0, 0.4),
        exit: region_with_density(232000.0, 240000.0, 0.4),
        analysis_version: 1,
        config_hash: "test".to_string(),
    };
    let inc = TrackProfile {
        profile_key: "in-cue2".to_string(),
        duration_ms: 240000,
        audible_start_ms: 200,
        audible_end_ms: 239000,
        integrated_rms_dbfs: -14.0,
        peak_dbfs: -2.0,
        tempo: Some(tempo(123.0, 0.75, 0.8, 0.5)),
        entrance: region_with_density(0.0, 8000.0, 0.4),
        exit: full_exit(),
        analysis_version: 1,
        config_hash: "test".to_string(),
    };
    let rel = Relationship {
        is_gapless_candidate: false,
        is_same_album: true,
    };
    let p = plan_transition(&out, &inc, &rel, &constraints(1.0, true), &config()).unwrap();
    if p.mode == TransitionMode::BeatMatched {
        let cue_end = p.outgoing_cue_ms as f64 + p.duration_ms as f64 * p.outgoing_effective_speed;
        assert!(
            cue_end <= 240000.0 + 1.0,
            "淡出窗口必须落在出口区内：cue_end={cue_end}"
        );
    }
    validate_transition_plan(&p).unwrap();
}

#[test]
fn beat_incoming_cue_stays_in_entrance() {
    // incoming 入口区 [3000, 5500]：唯一网格边界 4000 会让淡入落界（4000+2000>5500），
    // 必须被过滤 → 无法 cue → 降级 energy（旧实现会给出落界的 BeatAligned 计划）
    let out = TrackProfile {
        profile_key: "out-inc".to_string(),
        duration_ms: 240000,
        audible_start_ms: 200,
        audible_end_ms: 239000,
        integrated_rms_dbfs: -14.0,
        peak_dbfs: -2.0,
        tempo: Some(tempo(120.0, 0.75, 0.8, 0.5)),
        entrance: region_with_density(0.0, 8000.0, 0.4),
        exit: region_with_density(232000.0, 240000.0, 0.4),
        analysis_version: 1,
        config_hash: "test".to_string(),
    };
    let inc = TrackProfile {
        profile_key: "in-inc".to_string(),
        duration_ms: 240000,
        audible_start_ms: 200,
        audible_end_ms: 239000,
        integrated_rms_dbfs: -14.0,
        peak_dbfs: -2.0,
        tempo: Some(tempo(120.0, 0.75, 0.8, 0.5)),
        entrance: RegionProfile {
            start_ms: 3000.0,
            end_ms: 5500.0,
            ..region_with_density(0.0, 8000.0, 0.4)
        },
        exit: full_exit(),
        analysis_version: 1,
        config_hash: "test".to_string(),
    };
    let rel = Relationship {
        is_gapless_candidate: false,
        is_same_album: true,
    };
    let p = plan_transition(&out, &inc, &rel, &constraints(1.0, false), &config()).unwrap();
    assert_eq!(
        p.mode,
        TransitionMode::EnergyCrossfade,
        "入口区无窗口适配边界时必须降级，不得给出落界 cue"
    );
    assert!(p.diagnostics.iter().any(|d| d.code == "beat_cue"));
    validate_transition_plan(&p).unwrap();
}

#[test]
fn explicit_gapless_relationship_selects_gapless() {
    let s = &scenarios()[0];
    assert_eq!(s.name, "gapless");
    let p = plan_of(s);
    assert_eq!(p.mode, TransitionMode::Gapless);
    assert_eq!(p.duration_ms, 0);
    assert_eq!(p.incoming_cue_ms, 0);
    assert_eq!(p.outgoing_cue_ms, s.outgoing.duration_ms);
    validate_transition_plan(&p).unwrap();
}

#[test]
fn shuffle_blocks_gapless() {
    let beat_out = profile("out-sh", 120.0, 0.75, 0.8, 0.6, full_exit());
    let beat_in = profile("in-sh", 120.0, 0.75, 0.8, 0.6, full_exit());
    let rel = Relationship {
        is_gapless_candidate: false,
        is_same_album: true,
    };
    let p = plan_transition(
        &beat_out,
        &beat_in,
        &rel,
        &constraints(1.0, false),
        &config(),
    )
    .unwrap();
    assert_ne!(
        p.mode,
        TransitionMode::Gapless,
        "shuffle must block gapless"
    );
}

#[test]
fn different_album_uses_short_boundary_crossfade_for_calm_edges() {
    let mut outgoing = profile("out-cross-album-calm", 120.0, 0.75, 0.8, 0.6, full_exit());
    outgoing.exit.onset_density = 0.05;
    outgoing.exit.average_energy_dbfs = -18.0;
    let mut incoming = profile("in-cross-album-calm", 120.0, 0.75, 0.8, 0.6, full_exit());
    incoming.entrance.onset_density = 0.05;
    incoming.entrance.average_energy_dbfs = -18.0;
    let plan = plan_transition(
        &outgoing,
        &incoming,
        &Relationship {
            is_gapless_candidate: false,
            is_same_album: false,
        },
        &constraints(1.0, true),
        &config(),
    )
    .unwrap();
    assert_eq!(plan.mode, TransitionMode::EnergyCrossfade);
    assert!((2000..=3000).contains(&plan.duration_ms));
    assert_eq!(plan.bass_tempo_percent, 0.0);
    assert!(plan
        .diagnostics
        .iter()
        .any(|diagnostic| diagnostic.detail == "different_album"));
    validate_transition_plan(&plan).unwrap();
}

#[test]
fn different_album_keeps_a_short_crossfade_for_active_edges() {
    let outgoing = profile("out-cross-album-active", 120.0, 0.75, 0.8, 0.6, full_exit());
    let incoming = profile("in-cross-album-active", 123.0, 0.75, 0.8, 0.6, full_exit());
    let plan = plan_transition(
        &outgoing,
        &incoming,
        &Relationship {
            is_gapless_candidate: false,
            is_same_album: false,
        },
        &constraints(1.0, true),
        &config(),
    )
    .unwrap();
    assert_eq!(plan.mode, TransitionMode::EnergyCrossfade);
    assert!((2000..=3000).contains(&plan.duration_ms));
    assert_eq!(plan.bass_tempo_percent, 0.0);
    validate_transition_plan(&plan).unwrap();
}

#[test]
fn unsupported_tempo_uses_phase_alignment() {
    // 无 tempo profile -> 能量交叉淡化
    let mut out = profile("out-nt", 120.0, 0.75, 0.8, 0.6, full_exit());
    out.tempo = None;
    let inc = profile("in-nt", 120.0, 0.75, 0.8, 0.6, full_exit());
    let rel = Relationship {
        is_gapless_candidate: false,
        is_same_album: true,
    };
    let p = plan_transition(&out, &inc, &rel, &constraints(1.0, false), &config()).unwrap();
    assert_eq!(p.mode, TransitionMode::EnergyCrossfade);
    // tempo_at_cue 不可用但 BPM 接近 -> 8 拍相位对齐，不修改播放速度
    let out2 = profile("out-nt2", 120.0, 0.75, 0.8, 0.6, full_exit());
    let inc2 = profile("in-nt2", 123.0, 0.75, 0.8, 0.6, full_exit());
    let p2 = plan_transition(&out2, &inc2, &rel, &constraints(1.0, false), &config()).unwrap();
    assert_eq!(
        p2.mode,
        TransitionMode::BeatAligned,
        "near-tempo tracks should align without tempo capability"
    );
    assert_eq!(p2.duration_ms, 3902);
    assert_eq!(p2.bass_tempo_percent, 0.0);
    assert!(p2.diagnostics.iter().any(|d| d.code == "phase_alignment"));
    // 所有计划必须通过结构化校验
    validate_transition_plan(&p).unwrap();
    validate_transition_plan(&p2).unwrap();
}

#[test]
fn observed_near_tempo_profiles_use_phase_alignment() {
    let outgoing = profile("out-observed", 117.45, 0.621, 0.569, 0.02, full_exit());
    let incoming = profile("in-observed", 123.05, 0.603, 0.491, 0.02, full_exit());
    let plan = plan_transition(
        &outgoing,
        &incoming,
        &Relationship {
            is_gapless_candidate: false,
            is_same_album: true,
        },
        &constraints(1.0, false),
        &config(),
    )
    .unwrap();
    assert_eq!(plan.mode, TransitionMode::BeatAligned);
    assert_eq!(plan.duration_ms, 3901);
    assert_eq!(plan.bass_tempo_percent, 0.0);
    assert!(plan.diagnostics.iter().any(|d| d.code == "phase_alignment"));
    validate_transition_plan(&plan).unwrap();
}

#[test]
fn exact_ratio_boundary_and_capability_range_are_enforced() {
    let outgoing = profile("out-ratio", 120.0, 0.75, 0.8, 0.5, full_exit());
    let incoming = profile("in-ratio", 124.8, 0.75, 0.8, 0.5, full_exit());
    let relationship = Relationship {
        is_gapless_candidate: false,
        is_same_album: true,
    };
    let plan = plan_transition(
        &outgoing,
        &incoming,
        &relationship,
        &constraints(1.0, true),
        &config(),
    )
    .unwrap();
    assert_eq!(plan.mode, TransitionMode::BeatMatched);

    let mut limited = constraints(1.0, true);
    limited.bass_tempo_max_percent = 3.0;
    let downgraded =
        plan_transition(&outgoing, &incoming, &relationship, &limited, &config()).unwrap();
    assert_eq!(downgraded.mode, TransitionMode::EnergyCrossfade);
    assert!(downgraded
        .diagnostics
        .iter()
        .any(|diagnostic| diagnostic.detail.contains("capability range")));
}

#[test]
fn silence_trim_uses_audible_boundaries() {
    let outgoing = profile(
        "out-silence",
        120.0,
        0.75,
        0.8,
        0.6,
        region(238500.0, 240000.0),
    );
    let incoming = profile("in-silence", 120.0, 0.75, 0.8, 0.6, full_exit());
    let plan = plan_transition(
        &outgoing,
        &incoming,
        &Relationship {
            is_gapless_candidate: false,
            is_same_album: true,
        },
        &constraints(1.0, false),
        &config(),
    )
    .unwrap();
    assert_eq!(plan.mode, TransitionMode::SilenceTrim);
    assert_eq!(plan.outgoing_cue_ms, outgoing.audible_end_ms);
    assert_eq!(plan.incoming_cue_ms, incoming.audible_start_ms);
}

#[test]
fn planner_rejects_invalid_runtime_input() {
    let outgoing = profile("out-invalid", 120.0, 0.75, 0.8, 0.6, full_exit());
    let incoming = profile("in-invalid", 120.0, 0.75, 0.8, 0.6, full_exit());
    let mut invalid = constraints(0.0, false);
    invalid.pitch = f64::NAN;
    assert!(plan_transition(
        &outgoing,
        &incoming,
        &Relationship {
            is_gapless_candidate: false,
            is_same_album: true,
        },
        &invalid,
        &config(),
    )
    .is_err());
}

#[test]
fn energy_plan_preserves_tempo_ratio() {
    let outgoing = profile("out-energy-ratio", 130.0, 0.75, 0.8, 0.6, full_exit());
    let incoming = profile("in-energy-ratio", 100.0, 0.75, 0.8, 0.6, full_exit());
    let plan = plan_transition(
        &outgoing,
        &incoming,
        &Relationship {
            is_gapless_candidate: false,
            is_same_album: true,
        },
        &constraints(1.0, false),
        &config(),
    )
    .unwrap();
    assert!((plan.raw_ratio - 100.0 / 130.0).abs() < 1e-9);
    validate_transition_plan(&plan).unwrap();
}

#[test]
fn energy_plan_scales_source_window_with_user_speed() {
    let outgoing = profile("out-energy-speed", 130.0, 0.5, 0.5, 0.5, full_exit());
    let incoming = profile("in-energy-speed", 100.0, 0.5, 0.5, 0.5, full_exit());
    let plan = plan_transition(
        &outgoing,
        &incoming,
        &Relationship {
            is_gapless_candidate: false,
            is_same_album: true,
        },
        &constraints(2.0, false),
        &config(),
    )
    .unwrap();
    assert_eq!(plan.mode, TransitionMode::EnergyCrossfade);
    let source_window = plan.duration_ms as f64 * 2.0;
    assert!(
        plan.outgoing_cue_ms as f64 + source_window <= outgoing.exit.end_ms + 1.0,
        "outgoing source window must fit exit region"
    );
    assert!(source_window <= incoming.entrance.end_ms - incoming.entrance.start_ms + 1.0);
}
