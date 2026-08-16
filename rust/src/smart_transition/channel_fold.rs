// 多声道折叠与信号度量。

/// 逐 frame 折叠多声道为 mono：先算 mean/rms/peak（保留符号），
/// abs(mean) >= 0.125*rms 用 mean，否则用 peak，避免反相立体声被当成静音。
pub fn fold_frame(frame: &[f32]) -> f32 {
    debug_assert!(!frame.is_empty());
    let n = frame.len() as f64;
    let mean = frame.iter().map(|&s| s as f64).sum::<f64>() / n;
    let rms = (frame.iter().map(|&s| (s as f64) * (s as f64)).sum::<f64>() / n).sqrt();
    let mut peak = 0.0f64;
    for &s in frame {
        let v = s as f64;
        if v.abs() > peak.abs() {
            peak = v;
        }
    }
    if mean.abs() >= 0.125 * rms {
        mean as f32
    } else {
        peak as f32
    }
}

/// 整段采样的 RMS dBFS 与峰值 dBFS；空输入或静音返回 (-inf, -inf)。
pub fn rms_peak_dbfs(samples: &[f32]) -> (f64, f64) {
    if samples.is_empty() {
        return (f64::NEG_INFINITY, f64::NEG_INFINITY);
    }
    let mut sum_sq = 0.0f64;
    let mut peak_abs = 0.0f64;
    for &s in samples {
        let v = s as f64;
        sum_sq += v * v;
        let a = v.abs();
        if a > peak_abs {
            peak_abs = a;
        }
    }
    let rms = (sum_sq / samples.len() as f64).sqrt();
    let dbfs = |v: f64| {
        if v > 0.0 {
            20.0 * v.log10()
        } else {
            f64::NEG_INFINITY
        }
    };
    (dbfs(rms), dbfs(peak_abs))
}
