// 增益曲线测试。

use crate::smart_transition::gain_curve::{build_gain_curve, GainInputs, PlanError};
use crate::smart_transition::model::{GainPoint, RegionProfile, GAIN_CURVE_POINTS};

fn fixed_inputs() -> GainInputs {
    GainInputs {
        outgoing_exit: RegionProfile {
            start_ms: 232000.0,
            end_ms: 240000.0,
            average_energy_dbfs: -10.0,
            onset_density: 0.30,
            boundary_confidence: 0.7,
        },
        incoming_entrance: RegionProfile {
            start_ms: 0.0,
            end_ms: 8000.0,
            average_energy_dbfs: -8.0,
            onset_density: 0.30,
            boundary_confidence: 0.75,
        },
        incoming_integrated_rms_dbfs: -14.0,
        outgoing_peak_dbfs: -2.0,
        incoming_peak_dbfs: -2.0,
        outgoing_replay_gain_db: 0.0,
        incoming_replay_gain_db: 0.0,
    }
}

fn inputs_from_json(v: &serde_json::Value) -> GainInputs {
    let out = &v["outgoing_exit"];
    let inc = &v["incoming_entrance"];
    GainInputs {
        outgoing_exit: RegionProfile {
            start_ms: out["start_ms"].as_f64().unwrap(),
            end_ms: out["end_ms"].as_f64().unwrap(),
            average_energy_dbfs: out["average_energy_dbfs"].as_f64().unwrap(),
            onset_density: out["onset_density"].as_f64().unwrap(),
            boundary_confidence: out["boundary_confidence"].as_f64().unwrap(),
        },
        incoming_entrance: RegionProfile {
            start_ms: inc["start_ms"].as_f64().unwrap(),
            end_ms: inc["end_ms"].as_f64().unwrap(),
            average_energy_dbfs: inc["average_energy_dbfs"].as_f64().unwrap(),
            onset_density: inc["onset_density"].as_f64().unwrap(),
            boundary_confidence: inc["boundary_confidence"].as_f64().unwrap(),
        },
        incoming_integrated_rms_dbfs: v["incoming_integrated_rms_dbfs"].as_f64().unwrap(),
        outgoing_peak_dbfs: v["outgoing_peak_dbfs"].as_f64().unwrap(),
        incoming_peak_dbfs: v["incoming_peak_dbfs"].as_f64().unwrap(),
        outgoing_replay_gain_db: v["outgoing_replay_gain_db"].as_f64().unwrap(),
        incoming_replay_gain_db: v["incoming_replay_gain_db"].as_f64().unwrap(),
    }
}

#[test]
fn golden_curve_matches() {
    let golden: serde_json::Value =
        serde_json::from_str(include_str!("golden/gain_curve_v1.json")).unwrap();
    let inputs = inputs_from_json(&golden["inputs"]);
    let curve = build_gain_curve(&inputs).unwrap();
    let expected: Vec<GainPoint> = serde_json::from_value(golden["curve"].clone()).unwrap();
    assert_eq!(curve.len(), expected.len());
    for (i, (a, b)) in curve.iter().zip(expected.iter()).enumerate() {
        assert!(
            (a.outgoing - b.outgoing).abs() < 1e-12,
            "point {i} outgoing {} vs {}",
            a.outgoing,
            b.outgoing
        );
        assert!(
            (a.incoming - b.incoming).abs() < 1e-12,
            "point {i} incoming {} vs {}",
            a.incoming,
            b.incoming
        );
    }
    // 相同输入必须生成相同曲线（确定性）
    let again = build_gain_curve(&inputs).unwrap();
    for (a, b) in curve.iter().zip(again.iter()) {
        assert_eq!(a, b);
    }
}

#[test]
fn endpoints_are_exact() {
    let curve = build_gain_curve(&fixed_inputs()).unwrap();
    assert_eq!(
        curve[0],
        GainPoint {
            outgoing: 1.0,
            incoming: 0.0
        }
    );
    assert_eq!(
        curve[GAIN_CURVE_POINTS - 1],
        GainPoint {
            outgoing: 0.0,
            incoming: 1.0
        }
    );
    assert_eq!(curve.len(), GAIN_CURVE_POINTS);
}

#[test]
fn power_bound_holds() {
    let curve = build_gain_curve(&fixed_inputs()).unwrap();
    for (i, g) in curve.iter().enumerate() {
        assert!(g.outgoing.is_finite() && g.incoming.is_finite());
        assert!(
            (0.0..=1.0).contains(&g.outgoing),
            "outgoing[{i}] = {}",
            g.outgoing
        );
        assert!(
            (0.0..=1.0).contains(&g.incoming),
            "incoming[{i}] = {}",
            g.incoming
        );
        let power = g.outgoing * g.outgoing + g.incoming * g.incoming;
        assert!(power <= 1.0 + 1e-6, "point {i} power {power}");
    }
}

#[test]
fn overlap_keeps_the_outgoing_track_present() {
    let curve = build_gain_curve(&fixed_inputs()).unwrap();
    assert!(curve[8].outgoing > 0.9);
    assert!(curve[8].incoming < 0.3);
    assert!(curve[16].outgoing > 0.65);
    assert!(curve[16].incoming > 0.5);
    assert!(curve[16].outgoing + curve[16].incoming > 1.15);
}

#[test]
fn replay_gain_peak_is_limited() {
    // 高 ReplayGain：两路能量估算峰值必须被压到 -1 dBFS 以内
    let mut inputs = fixed_inputs();
    inputs.outgoing_replay_gain_db = 9.0;
    inputs.incoming_replay_gain_db = 9.0;
    let curve = build_gain_curve(&inputs).unwrap();
    let peak_out = 10f64.powf((-2.0 + 9.0) / 20.0);
    let peak_in = 10f64.powf((-2.0 + 9.0) / 20.0);
    let peak_limit = 10f64.powf(-1.0 / 20.0);
    // 端点是不参与收缩的单路播放，只有内部点受转场峰值约束
    for g in curve.iter().take(GAIN_CURVE_POINTS - 1).skip(1) {
        let peak = ((g.outgoing * peak_out).powi(2) + (g.incoming * peak_in).powi(2)).sqrt();
        assert!(
            peak <= peak_limit + 1e-9,
            "peak {peak} exceeds -1 dBFS limit"
        );
    }
    // 端点不参与收缩
    assert_eq!(
        curve[0],
        GainPoint {
            outgoing: 1.0,
            incoming: 0.0
        }
    );
    assert_eq!(
        curve[GAIN_CURVE_POINTS - 1],
        GainPoint {
            outgoing: 0.0,
            incoming: 1.0
        }
    );
    // 输入非法时报结构化错误
    let mut bad = fixed_inputs();
    bad.incoming_integrated_rms_dbfs = f64::NAN;
    assert!(matches!(
        build_gain_curve(&bad),
        Err(PlanError::InvalidInput(_))
    ));
}
