// 33 点增益曲线。公式、端点、阈值固定，见文档 7.5 节。

use crate::smart_transition::model::{GainPoint, RegionProfile, GAIN_CURVE_POINTS};

#[derive(Debug, Clone, PartialEq)]
pub enum PlanError {
    InvalidInput(String),
}

impl std::fmt::Display for PlanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PlanError::InvalidInput(msg) => write!(f, "invalid input: {msg}"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct GainInputs {
    pub outgoing_exit: RegionProfile,
    pub incoming_entrance: RegionProfile,
    pub incoming_integrated_rms_dbfs: f64,
    pub outgoing_peak_dbfs: f64,
    pub incoming_peak_dbfs: f64,
    pub outgoing_replay_gain_db: f64,
    pub incoming_replay_gain_db: f64,
}

fn clamp(v: f64, lo: f64, hi: f64) -> f64 {
    v.clamp(lo, hi)
}

fn smoothstep(x: f64) -> f64 {
    let x = clamp(x, 0.0, 1.0);
    x * x * (3.0 - 2.0 * x)
}

/// 计算 introProtection（文档 7.5 固定公式），供 planner 复用。
pub fn intro_protection_of(inputs: &GainInputs) -> f64 {
    let in_energy = clamp(inputs.incoming_entrance.average_energy_dbfs, -160.0, 24.0);
    let onset_score = clamp(
        (inputs.incoming_entrance.onset_density - 0.18) / 0.24,
        0.0,
        1.0,
    );
    let level_score = clamp(
        (in_energy - clamp(inputs.incoming_integrated_rms_dbfs, -160.0, 24.0) + 3.0) / 6.0,
        0.0,
        1.0,
    );
    clamp(
        (0.55 + 0.45 * inputs.incoming_entrance.boundary_confidence)
            * (0.72 * onset_score + 0.28 * level_score).max(0.62 * level_score),
        0.0,
        1.0,
    )
}

/// 按文档 7.5 固定公式构建 33 点曲线。
/// 第 0 点和第 32 点强制写入精确端点 (1,0)/(0,1)；峰值收缩只作用于内部点。
/// 结合两侧 ReplayGain 预测峰值，超过 -1 dBFS 时对内部点等比例收缩。
pub fn build_gain_curve(inputs: &GainInputs) -> Result<[GainPoint; GAIN_CURVE_POINTS], PlanError> {
    let finite_fields: [(&str, f64); 10] = [
        (
            "outgoing_exit.average_energy_dbfs",
            inputs.outgoing_exit.average_energy_dbfs,
        ),
        (
            "outgoing_exit.boundary_confidence",
            inputs.outgoing_exit.boundary_confidence,
        ),
        (
            "incoming_entrance.average_energy_dbfs",
            inputs.incoming_entrance.average_energy_dbfs,
        ),
        (
            "incoming_entrance.onset_density",
            inputs.incoming_entrance.onset_density,
        ),
        (
            "incoming_entrance.boundary_confidence",
            inputs.incoming_entrance.boundary_confidence,
        ),
        (
            "incoming_integrated_rms_dbfs",
            inputs.incoming_integrated_rms_dbfs,
        ),
        ("outgoing_peak_dbfs", inputs.outgoing_peak_dbfs),
        ("incoming_peak_dbfs", inputs.incoming_peak_dbfs),
        ("outgoing_replay_gain_db", inputs.outgoing_replay_gain_db),
        ("incoming_replay_gain_db", inputs.incoming_replay_gain_db),
    ];
    for (name, v) in finite_fields {
        if !v.is_finite() {
            return Err(PlanError::InvalidInput(format!("{name} must be finite")));
        }
    }
    if !(0.0..=1.0).contains(&inputs.outgoing_exit.boundary_confidence)
        || !(0.0..=1.0).contains(&inputs.incoming_entrance.boundary_confidence)
        || !(0.0..=1.0).contains(&inputs.incoming_entrance.onset_density)
    {
        return Err(PlanError::InvalidInput(
            "confidence and onset density must be in [0, 1]".to_string(),
        ));
    }

    let in_energy = clamp(inputs.incoming_entrance.average_energy_dbfs, -160.0, 24.0);
    let out_energy = clamp(inputs.outgoing_exit.average_energy_dbfs, -160.0, 24.0);
    let regional_delta = clamp(in_energy - out_energy, -120.0, 120.0);

    let boundary_blend = (inputs.outgoing_exit.boundary_confidence
        * inputs.incoming_entrance.boundary_confidence)
        .sqrt();

    let loudness_adjust_db =
        0.72 * clamp(regional_delta, -9.0, 9.0) * (0.55 + 0.45 * boundary_blend);

    let intro_protection = intro_protection_of(inputs);

    let mut curve = [GainPoint {
        outgoing: 0.0,
        incoming: 0.0,
    }; GAIN_CURVE_POINTS];
    let last = GAIN_CURVE_POINTS - 1;
    for i in 1..last {
        let p = i as f64 / last as f64;
        let transition_progress = smoothstep(p);
        let angle = transition_progress * std::f64::consts::FRAC_PI_2;
        let outgoing_base = angle.cos();
        let incoming_base = angle.sin();
        let late_window = 1.0 - smoothstep((p - 0.58) / 0.42);
        let intro_guard = 1.0 - 0.18 * intro_protection * (1.0 - transition_progress);
        let applied_db = loudness_adjust_db * late_window;
        let incoming_adjusted = incoming_base * intro_guard * 10f64.powf(-applied_db / 20.0);
        let combined_power = (outgoing_base.powi(2) + incoming_adjusted.powi(2)).sqrt();
        let scale = (1.0 / combined_power.max(1e-12)).min(1.0);
        curve[i] = GainPoint {
            outgoing: (outgoing_base * scale).clamp(0.0, 1.0),
            incoming: (incoming_adjusted * scale).clamp(0.0, 1.0),
        };
    }
    curve[0] = GainPoint {
        outgoing: 1.0,
        incoming: 0.0,
    };
    curve[last] = GainPoint {
        outgoing: 0.0,
        incoming: 1.0,
    };

    // ReplayGain 后按两路能量估算峰值，避免独立信号按完全相关叠加而过度衰减。
    let peak_out = 10f64.powf((inputs.outgoing_peak_dbfs + inputs.outgoing_replay_gain_db) / 20.0);
    let peak_in = 10f64.powf((inputs.incoming_peak_dbfs + inputs.incoming_replay_gain_db) / 20.0);
    let peak_limit = 10f64.powf(-1.0 / 20.0);
    for g in curve.iter_mut().take(last).skip(1) {
        let peak = ((g.outgoing * peak_out).powi(2) + (g.incoming * peak_in).powi(2)).sqrt();
        if peak > peak_limit {
            let s = peak_limit / peak;
            g.outgoing *= s;
            g.incoming *= s;
        }
    }
    Ok(curve)
}
