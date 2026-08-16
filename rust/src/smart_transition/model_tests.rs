// 模型与配置校验测试。

use crate::smart_transition::config::{
    analysis_config_hash, validate_analysis_config, AnalysisConfig, ConfigError,
    PROFILE_SCHEMA_VERSION,
};
use crate::smart_transition::model::{
    validate_gain_curve, validate_track_profile, validate_transition_plan, GainPoint,
    RegionProfile, TempoProfile, TrackProfile, TransitionDiagnostic, TransitionMode,
    TransitionPlan, ValidationError, GAIN_CURVE_POINTS,
};

fn tempo() -> TempoProfile {
    TempoProfile {
        bpm: 120.0,
        beat_times_ms: (0..16).map(|i| i as f64 * 500.0).collect(),
        downbeat_offset_ms: 0.0,
        beat_confidence: 0.8,
        downbeat_confidence: 0.6,
        stability: 0.75,
    }
}

fn region() -> RegionProfile {
    RegionProfile {
        start_ms: 0.0,
        end_ms: 8000.0,
        average_energy_dbfs: -12.0,
        onset_density: 0.35,
        boundary_confidence: 0.7,
    }
}

fn profile() -> TrackProfile {
    TrackProfile {
        profile_key: "test-key".to_string(),
        duration_ms: 240000,
        audible_start_ms: 200,
        audible_end_ms: 239000,
        integrated_rms_dbfs: -14.0,
        peak_dbfs: -2.0,
        tempo: Some(tempo()),
        entrance: region(),
        exit: RegionProfile {
            start_ms: 232000.0,
            end_ms: 240000.0,
            ..region()
        },
        analysis_version: 1,
        config_hash: "unused".to_string(),
    }
}

fn gain_curve() -> Vec<GainPoint> {
    let mut curve = vec![
        GainPoint {
            outgoing: 0.0,
            incoming: 0.0
        };
        GAIN_CURVE_POINTS
    ];
    for (i, g) in curve.iter_mut().enumerate() {
        let p = i as f64 / (GAIN_CURVE_POINTS - 1) as f64;
        let a = p * std::f64::consts::FRAC_PI_2;
        g.outgoing = a.cos();
        g.incoming = a.sin();
    }
    curve[0] = GainPoint {
        outgoing: 1.0,
        incoming: 0.0,
    };
    curve[GAIN_CURVE_POINTS - 1] = GainPoint {
        outgoing: 0.0,
        incoming: 1.0,
    };
    curve
}

fn plan() -> TransitionPlan {
    TransitionPlan {
        mode: TransitionMode::EnergyCrossfade,
        confidence: 0.9,
        confidence_tier: 2,
        outgoing_bpm: 120.0,
        incoming_bpm: 120.0,
        outgoing_cue_ms: 236000,
        incoming_cue_ms: 0,
        duration_ms: 4500,
        raw_ratio: 1.0,
        matched_ratio: 1.0,
        fold_factor: 1.0,
        outgoing_effective_speed: 1.0,
        bass_tempo_percent: 0.0,
        gain_curve: gain_curve(),
        diagnostics: vec![TransitionDiagnostic {
            code: "mode".to_string(),
            detail: "energy_crossfade".to_string(),
        }],
    }
}

#[test]
fn profile_round_trip() {
    let p = profile();
    let json = serde_json::to_string(&p).unwrap();
    let back: TrackProfile = serde_json::from_str(&json).unwrap();
    assert_eq!(p, back);
    validate_track_profile(&p).unwrap();
    // TransitionPlan 的 gain_curve 是 cos/sin 结果，JSON 往返允许 1e-12 容差
    let pl = plan();
    let json = serde_json::to_string(&pl).unwrap();
    let back: TransitionPlan = serde_json::from_str(&json).unwrap();
    assert_eq!(pl.mode, back.mode);
    assert_eq!(pl.confidence_tier, back.confidence_tier);
    assert_eq!(pl.outgoing_cue_ms, back.outgoing_cue_ms);
    assert_eq!(pl.incoming_cue_ms, back.incoming_cue_ms);
    assert_eq!(pl.duration_ms, back.duration_ms);
    assert_eq!(pl.diagnostics, back.diagnostics);
    for (f, g) in [
        (pl.confidence, back.confidence),
        (pl.outgoing_bpm, back.outgoing_bpm),
        (pl.incoming_bpm, back.incoming_bpm),
        (pl.raw_ratio, back.raw_ratio),
        (pl.matched_ratio, back.matched_ratio),
        (pl.fold_factor, back.fold_factor),
        (pl.outgoing_effective_speed, back.outgoing_effective_speed),
        (pl.bass_tempo_percent, back.bass_tempo_percent),
    ] {
        assert!((f - g).abs() < 1e-12);
    }
    assert_eq!(pl.gain_curve.len(), back.gain_curve.len());
    for (a, b) in pl.gain_curve.iter().zip(back.gain_curve.iter()) {
        assert!((a.outgoing - b.outgoing).abs() < 1e-12);
        assert!((a.incoming - b.incoming).abs() < 1e-12);
    }
    validate_transition_plan(&pl).unwrap();
}

#[test]
fn config_hash_is_canonical() {
    let c = AnalysisConfig::default();
    let h1 = analysis_config_hash(&c).unwrap();
    let h2 = analysis_config_hash(&c).unwrap();
    assert_eq!(h1, h2);
    assert_eq!(h1.len(), 64);
    assert!(h1
        .chars()
        .all(|ch| ch.is_ascii_hexdigit() && !ch.is_ascii_uppercase()));
    // canonical：序列化键按字段名排序（serde_json 默认 Object 为 BTreeMap）
    let v = serde_json::to_value(&c).unwrap();
    let serde_json::Value::Object(map) = v else {
        panic!("config must serialize to object")
    };
    let keys: Vec<&String> = map.keys().collect();
    let mut sorted = keys.clone();
    sorted.sort();
    assert_eq!(keys, sorted);
    assert_eq!(c.analysis_version, 1);
    assert_eq!(PROFILE_SCHEMA_VERSION, 1);
}

#[test]
fn rejects_non_finite_values() {
    let mut p = profile();
    p.integrated_rms_dbfs = f64::NAN;
    assert!(matches!(
        validate_track_profile(&p),
        Err(ValidationError::NonFinite { .. })
    ));
    let mut p2 = profile();
    p2.peak_dbfs = f64::INFINITY;
    assert!(matches!(
        validate_track_profile(&p2),
        Err(ValidationError::NonFinite { .. })
    ));
    let mut p3 = profile();
    p3.tempo.as_mut().unwrap().bpm = f64::NEG_INFINITY;
    assert!(matches!(
        validate_track_profile(&p3),
        Err(ValidationError::NonFinite { .. })
    ));
    let mut pl = plan();
    pl.confidence = f64::NAN;
    assert!(matches!(
        validate_transition_plan(&pl),
        Err(ValidationError::NonFinite { .. })
    ));
}

#[test]
fn rejects_invalid_gain_curve() {
    assert!(validate_gain_curve(&gain_curve()).is_ok());
    // 非 33 点曲线
    let short: Vec<GainPoint> = gain_curve().into_iter().take(32).collect();
    assert!(matches!(
        validate_gain_curve(&short),
        Err(ValidationError::InvalidGainCurve { .. })
    ));
    // 越界增益
    let mut curve = gain_curve();
    curve[10].outgoing = 1.5;
    assert!(matches!(
        validate_gain_curve(&curve),
        Err(ValidationError::InvalidGainCurve { .. })
    ));
    // 平方和超过 1 + 1e-6
    let mut curve = gain_curve();
    curve[5] = GainPoint {
        outgoing: 1.0,
        incoming: 1.0,
    };
    assert!(matches!(
        validate_gain_curve(&curve),
        Err(ValidationError::InvalidGainCurve { .. })
    ));
    let mut curve = gain_curve();
    curve[0] = GainPoint {
        outgoing: 0.99,
        incoming: 0.0,
    };
    assert!(matches!(
        validate_gain_curve(&curve),
        Err(ValidationError::InvalidGainCurve { .. })
    ));
    let mut curve = gain_curve();
    curve[GAIN_CURVE_POINTS - 1] = GainPoint {
        outgoing: 0.0,
        incoming: 0.99,
    };
    assert!(matches!(
        validate_gain_curve(&curve),
        Err(ValidationError::InvalidGainCurve { .. })
    ));
}

#[test]
fn config_validation_rejects_invalid_values() {
    let c = AnalysisConfig::default();
    validate_analysis_config(&c).unwrap();
    let mut bad = c.clone();
    bad.audible_floor_dbfs = f64::NAN;
    assert!(matches!(
        validate_analysis_config(&bad),
        Err(ConfigError::NonFinite(_))
    ));
    let mut bad = c.clone();
    bad.onset_mean_scale = -1.0;
    assert!(matches!(
        validate_analysis_config(&bad),
        Err(ConfigError::OutOfRange(_))
    ));
    let mut bad = c.clone();
    bad.fft_hop = bad.fft_window;
    assert!(matches!(
        validate_analysis_config(&bad),
        Err(ConfigError::Order(_))
    ));
    let mut bad = c.clone();
    bad.bpm_min = 200.0;
    assert!(matches!(
        validate_analysis_config(&bad),
        Err(ConfigError::Order(_))
    ));
    let mut bad = c.clone();
    bad.sample_rate_hz = 0;
    assert!(matches!(
        validate_analysis_config(&bad),
        Err(ConfigError::OutOfRange(_))
    ));
    let mut bad = c.clone();
    bad.onset_norm_percentile = 1.5;
    assert!(matches!(
        validate_analysis_config(&bad),
        Err(ConfigError::OutOfRange(_))
    ));
    let mut bad = c.clone();
    bad.bpm_center_prior = 10.0;
    assert!(matches!(
        validate_analysis_config(&bad),
        Err(ConfigError::OutOfRange(_))
    ));
    let mut bad = c.clone();
    bad.beat_conf_corr_weight = 0.45;
    assert!(matches!(
        validate_analysis_config(&bad),
        Err(ConfigError::Order(_))
    ));
    let mut bad = c.clone();
    bad.audible_floor_dbfs = 1.0;
    assert!(matches!(
        validate_analysis_config(&bad),
        Err(ConfigError::OutOfRange(_))
    ));
    let mut bad = c.clone();
    bad.audible_floor_dbfs = f64::NAN;
    assert!(matches!(
        analysis_config_hash(&bad),
        Err(ConfigError::NonFinite(_))
    ));
}

#[test]
fn rejects_non_monotonic_beats() {
    let mut t = tempo();
    t.beat_times_ms = vec![0.0, 500.0, 500.0, 1500.0];
    let mut p = profile();
    p.tempo = Some(t);
    assert!(matches!(
        validate_track_profile(&p),
        Err(ValidationError::NonMonotonicBeats { .. })
    ));
    let mut t2 = tempo();
    t2.beat_times_ms = vec![0.0, 500.0, 400.0];
    let mut p2 = profile();
    p2.tempo = Some(t2);
    assert!(matches!(
        validate_track_profile(&p2),
        Err(ValidationError::NonMonotonicBeats { .. })
    ));
}

#[test]
fn validates_tempo_bounds_and_short_track_regions() {
    let mut overlapping = profile();
    overlapping.duration_ms = 10000;
    overlapping.audible_end_ms = 9900;
    overlapping.entrance.end_ms = 7000.0;
    overlapping.exit.start_ms = 3000.0;
    overlapping.exit.end_ms = 10000.0;
    overlapping.tempo.as_mut().unwrap().beat_times_ms =
        (0..20).map(|index| index as f64 * 500.0).collect();
    assert!(validate_track_profile(&overlapping).is_ok());

    let mut outside = profile();
    outside.tempo.as_mut().unwrap().beat_times_ms.push(250000.0);
    assert!(matches!(
        validate_track_profile(&outside),
        Err(ValidationError::OutOfRange { .. })
    ));

    let mut too_short = profile();
    too_short.tempo.as_mut().unwrap().beat_times_ms = vec![0.0];
    assert!(matches!(
        validate_track_profile(&too_short),
        Err(ValidationError::InvalidValue { .. })
    ));
}

#[test]
fn all_transition_modes_require_33_gain_points() {
    let mut non_overlap = plan();
    non_overlap.mode = TransitionMode::Gapless;
    non_overlap.duration_ms = 0;
    non_overlap.gain_curve.clear();
    assert!(matches!(
        validate_transition_plan(&non_overlap),
        Err(ValidationError::InvalidGainCurve { .. })
    ));

    let mut invalid_flat = plan();
    invalid_flat.mode = TransitionMode::SilenceTrim;
    invalid_flat.duration_ms = 0;
    invalid_flat.gain_curve = vec![
        GainPoint {
            outgoing: 1.0,
            incoming: 1.0,
        };
        GAIN_CURVE_POINTS
    ];
    invalid_flat.gain_curve[10].incoming = 0.5;
    assert!(matches!(
        validate_transition_plan(&invalid_flat),
        Err(ValidationError::InvalidGainCurve { .. })
    ));
}
