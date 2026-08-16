// 智能衔接领域模型与结构化校验。
// 单位固定：毫秒（ms）、dBFS。字段名、枚举值与 analysisVersion/profileSchemaVersion 是冻结接口。

use serde::{Deserialize, Serialize};

pub const GAIN_CURVE_POINTS: usize = 33;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TransitionMode {
    Gapless,
    SilenceTrim,
    EnergyCrossfade,
    BeatAligned,
    BeatMatched,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TempoProfile {
    /// 原始文件 BPM，不含用户速度。
    pub bpm: f64,
    /// 拍点时间（ms），单调递增。
    pub beat_times_ms: Vec<f64>,
    /// 强拍相位偏移（ms）。
    pub downbeat_offset_ms: f64,
    /// 0..=1
    pub beat_confidence: f64,
    /// 0..=1
    pub downbeat_confidence: f64,
    /// 0..=1
    pub stability: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegionProfile {
    pub start_ms: f64,
    pub end_ms: f64,
    pub average_energy_dbfs: f64,
    /// 0..=1 归一化 onset 密度。
    pub onset_density: f64,
    /// 0..=1
    pub boundary_confidence: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackProfile {
    /// 稳定媒体 ID，缺失时退化为规范化路径。
    pub profile_key: String,
    pub duration_ms: u64,
    pub audible_start_ms: u64,
    pub audible_end_ms: u64,
    /// 整首歌 RMS dBFS，不是 LUFS。
    pub integrated_rms_dbfs: f64,
    pub peak_dbfs: f64,
    pub tempo: Option<TempoProfile>,
    pub entrance: RegionProfile,
    pub exit: RegionProfile,
    pub analysis_version: u32,
    pub config_hash: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct GainPoint {
    pub outgoing: f64,
    pub incoming: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TransitionDiagnostic {
    pub code: String,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TransitionPlan {
    pub mode: TransitionMode,
    pub confidence: f64,
    pub confidence_tier: u8,
    pub outgoing_bpm: f64,
    pub incoming_bpm: f64,
    pub outgoing_cue_ms: u64,
    pub incoming_cue_ms: u64,
    pub duration_ms: u64,
    /// incomingRawBpm / outgoingRawBpm。
    pub raw_ratio: f64,
    /// 折叠后的匹配倍率。
    pub matched_ratio: f64,
    /// 选中的倍频因子：0.5 / 1.0 / 2.0。
    pub fold_factor: f64,
    /// outgoing 临时有效播放倍率（userSpeed * matchedRatio）。
    pub outgoing_effective_speed: f64,
    /// BASS tempo 百分比，按文件自然速率计算。
    pub bass_tempo_percent: f64,
    pub gain_curve: Vec<GainPoint>,
    pub diagnostics: Vec<TransitionDiagnostic>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ValidationError {
    NonFinite { field: String },
    OutOfRange { field: String, min: f64, max: f64 },
    InvertedTime { field: String },
    NonMonotonicBeats { index: usize },
    InvalidValue { field: String, reason: String },
    InvalidGainCurve { reason: String },
}

impl std::fmt::Display for ValidationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ValidationError::NonFinite { field } => write!(f, "field {field} must be finite"),
            ValidationError::OutOfRange { field, min, max } => {
                write!(f, "field {field} must be in [{min}, {max}]")
            }
            ValidationError::InvertedTime { field } => {
                write!(f, "field {field} has inverted time order")
            }
            ValidationError::NonMonotonicBeats { index } => {
                write!(f, "beat_times_ms not strictly increasing at index {index}")
            }
            ValidationError::InvalidValue { field, reason } => {
                write!(f, "field {field} is invalid: {reason}")
            }
            ValidationError::InvalidGainCurve { reason } => {
                write!(f, "invalid gain curve: {reason}")
            }
        }
    }
}

fn check_finite(v: f64, field: &str) -> Result<(), ValidationError> {
    if v.is_finite() {
        Ok(())
    } else {
        Err(ValidationError::NonFinite {
            field: field.to_string(),
        })
    }
}

fn check_range(v: f64, field: &str, min: f64, max: f64) -> Result<(), ValidationError> {
    check_finite(v, field)?;
    if (min..=max).contains(&v) {
        Ok(())
    } else {
        Err(ValidationError::OutOfRange {
            field: field.to_string(),
            min,
            max,
        })
    }
}

fn validate_region(
    r: &RegionProfile,
    label: &str,
    duration_ms: u64,
) -> Result<(), ValidationError> {
    check_finite(r.start_ms, &format!("{label}.start_ms"))?;
    check_finite(r.end_ms, &format!("{label}.end_ms"))?;
    check_range(
        r.average_energy_dbfs,
        &format!("{label}.average_energy_dbfs"),
        -160.0,
        24.0,
    )?;
    check_range(r.onset_density, &format!("{label}.onset_density"), 0.0, 1.0)?;
    check_range(
        r.boundary_confidence,
        &format!("{label}.boundary_confidence"),
        0.0,
        1.0,
    )?;
    let dur = duration_ms as f64;
    if r.start_ms < 0.0 || r.end_ms < r.start_ms || r.end_ms > dur {
        return Err(ValidationError::InvertedTime {
            field: format!("{label} time range"),
        });
    }
    Ok(())
}

/// 校验 TrackProfile：有限数、时间顺序、置信度范围、拍点单调性。
pub fn validate_track_profile(p: &TrackProfile) -> Result<(), ValidationError> {
    if p.profile_key.is_empty() {
        return Err(ValidationError::InvalidValue {
            field: "profile_key".to_string(),
            reason: "must not be empty".to_string(),
        });
    }
    if p.duration_ms == 0 || p.analysis_version == 0 || p.config_hash.is_empty() {
        return Err(ValidationError::InvalidValue {
            field: "profile metadata".to_string(),
            reason: "duration, analysis version, and config hash must be present".to_string(),
        });
    }
    check_range(p.integrated_rms_dbfs, "integrated_rms_dbfs", -160.0, 24.0)?;
    check_range(p.peak_dbfs, "peak_dbfs", -160.0, 24.0)?;
    if p.peak_dbfs < p.integrated_rms_dbfs {
        return Err(ValidationError::InvalidValue {
            field: "peak_dbfs".to_string(),
            reason: "must not be below integrated_rms_dbfs".to_string(),
        });
    }
    if p.audible_start_ms > p.audible_end_ms || p.audible_end_ms > p.duration_ms {
        return Err(ValidationError::InvertedTime {
            field: "audible range".to_string(),
        });
    }
    validate_region(&p.entrance, "entrance", p.duration_ms)?;
    validate_region(&p.exit, "exit", p.duration_ms)?;
    if let Some(t) = &p.tempo {
        check_finite(t.bpm, "tempo.bpm")?;
        if t.bpm <= 0.0 {
            return Err(ValidationError::OutOfRange {
                field: "tempo.bpm".to_string(),
                min: 0.0,
                max: f64::INFINITY,
            });
        }
        check_range(t.beat_confidence, "tempo.beat_confidence", 0.0, 1.0)?;
        check_range(t.downbeat_confidence, "tempo.downbeat_confidence", 0.0, 1.0)?;
        check_range(t.stability, "tempo.stability", 0.0, 1.0)?;
        check_finite(t.downbeat_offset_ms, "tempo.downbeat_offset_ms")?;
        if t.downbeat_offset_ms < 0.0 || t.downbeat_offset_ms > p.duration_ms as f64 {
            return Err(ValidationError::OutOfRange {
                field: "tempo.downbeat_offset_ms".to_string(),
                min: 0.0,
                max: f64::INFINITY,
            });
        }
        if t.beat_times_ms.len() < 2 {
            return Err(ValidationError::InvalidValue {
                field: "tempo.beat_times_ms".to_string(),
                reason: "must contain at least two beats".to_string(),
            });
        }
        let mut prev = f64::NEG_INFINITY;
        for (i, &b) in t.beat_times_ms.iter().enumerate() {
            check_finite(b, "tempo.beat_times_ms")?;
            if b < 0.0 || b > p.duration_ms as f64 {
                return Err(ValidationError::OutOfRange {
                    field: format!("tempo.beat_times_ms[{i}]"),
                    min: 0.0,
                    max: p.duration_ms as f64,
                });
            }
            if b <= prev {
                return Err(ValidationError::NonMonotonicBeats { index: i });
            }
            prev = b;
        }
    }
    Ok(())
}

/// 校验 33 点增益曲线：长度必须为 33，每点有限、[0,1]、平方和不超过 1 + 1e-6。
pub fn validate_gain_curve(curve: &[GainPoint]) -> Result<(), ValidationError> {
    if curve.len() != GAIN_CURVE_POINTS {
        return Err(ValidationError::InvalidGainCurve {
            reason: format!("curve length {} != {GAIN_CURVE_POINTS}", curve.len()),
        });
    }
    if curve[0].outgoing != 1.0 || curve[0].incoming != 0.0 {
        return Err(ValidationError::InvalidGainCurve {
            reason: "first point must be (1, 0)".to_string(),
        });
    }
    if curve[GAIN_CURVE_POINTS - 1].outgoing != 0.0 || curve[GAIN_CURVE_POINTS - 1].incoming != 1.0
    {
        return Err(ValidationError::InvalidGainCurve {
            reason: "last point must be (0, 1)".to_string(),
        });
    }
    for (i, g) in curve.iter().enumerate() {
        check_finite(g.outgoing, "gain_curve.outgoing")?;
        check_finite(g.incoming, "gain_curve.incoming")?;
        if !(0.0..=1.0).contains(&g.outgoing) {
            return Err(ValidationError::InvalidGainCurve {
                reason: format!("outgoing[{i}] = {} outside [0,1]", g.outgoing),
            });
        }
        if !(0.0..=1.0).contains(&g.incoming) {
            return Err(ValidationError::InvalidGainCurve {
                reason: format!("incoming[{i}] = {} outside [0,1]", g.incoming),
            });
        }
        let power = g.outgoing * g.outgoing + g.incoming * g.incoming;
        if power > 1.0 + 1e-6 {
            return Err(ValidationError::InvalidGainCurve {
                reason: format!("point {i} power {power} exceeds 1 + 1e-6"),
            });
        }
    }
    Ok(())
}

/// 校验 TransitionPlan：置信度、倍率、BPM 与增益曲线。
pub fn validate_transition_plan(p: &TransitionPlan) -> Result<(), ValidationError> {
    check_range(p.confidence, "confidence", 0.0, 1.0)?;
    if !(1..=3).contains(&p.confidence_tier) {
        return Err(ValidationError::InvalidValue {
            field: "confidence_tier".to_string(),
            reason: "must be in 1..=3".to_string(),
        });
    }
    check_finite(p.outgoing_bpm, "outgoing_bpm")?;
    check_finite(p.incoming_bpm, "incoming_bpm")?;
    if p.outgoing_bpm < 0.0 || p.incoming_bpm < 0.0 {
        return Err(ValidationError::OutOfRange {
            field: "bpm".to_string(),
            min: 0.0,
            max: f64::INFINITY,
        });
    }
    check_finite(p.raw_ratio, "raw_ratio")?;
    check_finite(p.matched_ratio, "matched_ratio")?;
    if p.raw_ratio <= 0.0 || p.matched_ratio <= 0.0 {
        return Err(ValidationError::OutOfRange {
            field: "ratio".to_string(),
            min: 0.0,
            max: f64::INFINITY,
        });
    }
    check_finite(p.fold_factor, "fold_factor")?;
    if ![0.5, 1.0, 2.0]
        .iter()
        .any(|candidate| (p.fold_factor - candidate).abs() <= 1e-9)
    {
        return Err(ValidationError::OutOfRange {
            field: "fold_factor".to_string(),
            min: 0.5,
            max: 2.0,
        });
    }
    if (p.matched_ratio - p.raw_ratio * p.fold_factor).abs() > 1e-9 {
        return Err(ValidationError::InvalidGainCurve {
            reason: format!(
                "matched_ratio {} != raw_ratio {} * fold_factor {}",
                p.matched_ratio, p.raw_ratio, p.fold_factor
            ),
        });
    }
    check_finite(p.outgoing_effective_speed, "outgoing_effective_speed")?;
    if p.outgoing_effective_speed <= 0.0 {
        return Err(ValidationError::OutOfRange {
            field: "outgoing_effective_speed".to_string(),
            min: 0.0,
            max: f64::INFINITY,
        });
    }
    check_finite(p.bass_tempo_percent, "bass_tempo_percent")?;
    if p.outgoing_bpm > 0.0 && p.incoming_bpm > 0.0 {
        let expected_raw_ratio = p.incoming_bpm / p.outgoing_bpm;
        if (p.raw_ratio - expected_raw_ratio).abs() > 1e-6 {
            return Err(ValidationError::InvalidValue {
                field: "raw_ratio".to_string(),
                reason: "must equal incoming_bpm / outgoing_bpm".to_string(),
            });
        }
    }
    match p.mode {
        TransitionMode::Gapless | TransitionMode::SilenceTrim if p.duration_ms != 0 => {
            return Err(ValidationError::InvalidValue {
                field: "duration_ms".to_string(),
                reason: "non-overlap modes must have zero duration".to_string(),
            });
        }
        TransitionMode::EnergyCrossfade
        | TransitionMode::BeatAligned
        | TransitionMode::BeatMatched
            if !(2000..=12000).contains(&p.duration_ms) =>
        {
            return Err(ValidationError::InvalidValue {
                field: "duration_ms".to_string(),
                reason: "overlap modes must be in 2000..=12000 ms".to_string(),
            });
        }
        _ => {}
    }
    if p.gain_curve.len() != GAIN_CURVE_POINTS {
        return Err(ValidationError::InvalidGainCurve {
            reason: format!("curve length {} != {GAIN_CURVE_POINTS}", p.gain_curve.len()),
        });
    }
    // 无交叉模式（GAPLESS/SILENCE_TRIM）的曲线表达"各自满音量"，不参与同时功率约束
    match p.mode {
        TransitionMode::Gapless | TransitionMode::SilenceTrim => {
            for (i, g) in p.gain_curve.iter().enumerate() {
                check_finite(g.outgoing, "gain_curve.outgoing")?;
                check_finite(g.incoming, "gain_curve.incoming")?;
                if g.outgoing != 1.0 || g.incoming != 1.0 {
                    return Err(ValidationError::InvalidGainCurve {
                        reason: format!("non-overlap point {i} must be (1, 1)"),
                    });
                }
            }
        }
        _ => validate_gain_curve(&p.gain_curve)?,
    }
    Ok(())
}
