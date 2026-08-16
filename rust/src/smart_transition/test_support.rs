// 合成 PCM 与测量工具。
// 全部函数确定性且不依赖外部输入；相同输入必须逐 sample 相等，值有限且位于 [-1, 1]。
// 除 band_rms 外所有函数都做参数校验：非法输入直接 panic，不做静默修正。

/// 确定性正弦标记音，交错采样输出。
/// 每帧所有声道写入同一值，便于后续分离两路贡献。
pub fn tone_pcm(
    sample_rate: u32,
    channels: u16,
    duration_ms: u32,
    frequency_hz: f64,
    gain: f64,
) -> Vec<f32> {
    assert!(sample_rate > 0, "sample_rate must be > 0");
    assert!(channels > 0, "channels must be > 0");
    assert!(duration_ms > 0, "duration_ms must be > 0");
    assert!(
        frequency_hz.is_finite() && frequency_hz > 0.0,
        "frequency_hz must be finite and > 0"
    );
    assert!(
        frequency_hz < sample_rate as f64 / 2.0,
        "frequency_hz must be below Nyquist"
    );
    assert!(gain.is_finite(), "gain must be finite");
    let frames = (sample_rate as u64 * duration_ms as u64 / 1000) as usize;
    let ch = channels as usize;
    let mut out = Vec::with_capacity(frames * ch);
    for i in 0..frames {
        let t = i as f64 / sample_rate as f64;
        // clamp 保证任意 gain 输入下输出仍满足 [-1, 1] 硬不变量
        let v = ((gain * (2.0 * std::f64::consts::PI * frequency_hz * t).sin()) as f32)
            .clamp(-1.0, 1.0);
        for _ in 0..ch {
            out.push(v);
        }
    }
    out
}

/// 点击轨：每拍一个线性衰减短脉冲，脉冲持续 10 ms。
/// 点击起始位置精确落在 `round(beat * samples_per_beat)`。
pub fn click_track_pcm(
    sample_rate: u32,
    channels: u16,
    bpm: f64,
    beats: usize,
    gain: f64,
) -> Vec<f32> {
    assert!(sample_rate > 0, "sample_rate must be > 0");
    assert!(channels > 0, "channels must be > 0");
    assert!(bpm.is_finite() && bpm > 0.0, "bpm must be finite and > 0");
    assert!(beats > 0, "beats must be > 0");
    assert!(gain.is_finite(), "gain must be finite");
    let ch = channels as usize;
    let spb = sample_rate as f64 * 60.0 / bpm;
    let click_len = ((sample_rate as f64 * 0.01) as usize).max(1);
    let total_frames = (spb * beats as f64).ceil() as usize;
    let mut out = vec![0.0f32; total_frames * ch];
    for b in 0..beats {
        let start = (b as f64 * spb).round() as usize;
        for k in 0..click_len.min(total_frames.saturating_sub(start)) {
            let env = 1.0 - k as f64 / click_len as f64;
            let v = ((gain * env) as f32).clamp(-1.0, 1.0);
            for c in 0..ch {
                out[(start + k) * ch + c] = v;
            }
        }
    }
    out
}

/// 前后各加一段静音，返回交错采样。
pub fn with_silence(
    samples: &[f32],
    channels: u16,
    sample_rate: u32,
    front_ms: u32,
    back_ms: u32,
) -> Vec<f32> {
    assert!(sample_rate > 0, "sample_rate must be > 0");
    assert!(channels > 0, "channels must be > 0");
    let ch = channels as usize;
    assert!(
        samples.len() % ch == 0,
        "samples must contain complete frames"
    );
    assert!(
        samples
            .iter()
            .all(|sample| sample.is_finite() && (-1.0..=1.0).contains(sample)),
        "samples must be finite and within [-1, 1]"
    );
    let front = (sample_rate as usize * front_ms as usize / 1000) * ch;
    let back = (sample_rate as usize * back_ms as usize / 1000) * ch;
    let mut out = Vec::with_capacity(front + samples.len() + back);
    out.extend(std::iter::repeat(0.0f32).take(front));
    out.extend_from_slice(samples);
    out.extend(std::iter::repeat(0.0f32).take(back));
    out
}

/// 反相立体声：右声道为左声道逐 sample 取反，输出交错采样。
pub fn anti_phase_stereo(left: &[f32]) -> Vec<f32> {
    assert!(
        left.iter()
            .all(|sample| sample.is_finite() && (-1.0..=1.0).contains(sample)),
        "samples must be finite and within [-1, 1]"
    );
    let mut out = Vec::with_capacity(left.len() * 2);
    for &s in left {
        out.push(s);
        out.push(-s);
    }
    out
}

struct Biquad {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    x1: f64,
    x2: f64,
    y1: f64,
    y2: f64,
}

impl Biquad {
    /// RBJ cookbook 带通（0 dB 峰值增益）。
    fn bandpass(sample_rate: f64, center_hz: f64, bandwidth_hz: f64) -> Self {
        let w0 = 2.0 * std::f64::consts::PI * center_hz / sample_rate;
        let q = center_hz / bandwidth_hz;
        let alpha = w0.sin() / (2.0 * q);
        let a0 = 1.0 + alpha;
        Biquad {
            b0: alpha / a0,
            b1: 0.0,
            b2: -alpha / a0,
            a1: (-2.0 * w0.cos()) / a0,
            a2: (1.0 - alpha) / a0,
            x1: 0.0,
            x2: 0.0,
            y1: 0.0,
            y2: 0.0,
        }
    }

    fn process(&mut self, x: f64) -> f64 {
        let y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2
            - self.a1 * self.y1
            - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        y
    }
}

/// 分频 RMS（dBFS）：逐帧折叠交错声道后做带通滤波。
/// 先处理前 50 ms 输入以预热滤波器，但不把这段输出计入 RMS。
/// `low_hz` 必须大于 0 且 `high_hz > low_hz`。
pub fn band_rms(
    samples: &[f32],
    channels: u16,
    sample_rate: u32,
    low_hz: f32,
    high_hz: f32,
) -> f64 {
    assert!(sample_rate > 0, "sample_rate must be > 0");
    assert!(channels > 0, "channels must be > 0");
    assert!(
        low_hz > 0.0 && high_hz > low_hz,
        "band must satisfy 0 < low_hz < high_hz"
    );
    assert!(
        high_hz < sample_rate as f32 / 2.0,
        "band must be below Nyquist"
    );
    let ch = channels as usize;
    assert!(
        samples.len() % ch == 0,
        "samples must contain complete frames"
    );
    assert!(
        samples
            .iter()
            .all(|sample| sample.is_finite() && (-1.0..=1.0).contains(sample)),
        "samples must be finite and within [-1, 1]"
    );
    let fs = sample_rate as f64;
    let center = (low_hz as f64 * high_hz as f64).sqrt();
    let bandwidth = (high_hz - low_hz) as f64;
    let mut filter = Biquad::bandpass(fs, center, bandwidth);
    let warmup = (fs * 0.05) as usize;
    let mut sum_sq = 0.0f64;
    let mut count = 0usize;
    for (frame_index, frame) in samples.chunks_exact(ch).enumerate() {
        let mono = crate::smart_transition::channel_fold::fold_frame(frame);
        let y = filter.process(mono as f64);
        if frame_index >= warmup {
            sum_sq += y * y;
            count += 1;
        }
    }
    if count == 0 {
        return -f64::INFINITY;
    }
    let rms = (sum_sq / count as f64).sqrt();
    if rms <= 0.0 {
        return -f64::INFINITY;
    }
    20.0 * rms.log10()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tone_is_deterministic() {
        let a = tone_pcm(48000, 2, 250, 440.0, 0.5);
        let b = tone_pcm(48000, 2, 250, 440.0, 0.5);
        assert_eq!(a, b);
        assert_eq!(a.len(), 48000 * 250 / 1000 * 2);
        assert!(a.iter().all(|v| v.is_finite() && (-1.0..=1.0).contains(v)));
        // 不全是静音
        assert!(a.iter().any(|&v| v.abs() > 1e-3));
        // 越界 gain 也必须满足 [-1, 1] 硬不变量
        let clipped = tone_pcm(48000, 1, 100, 440.0, 3.0);
        assert!(clipped
            .iter()
            .all(|v| v.is_finite() && (-1.0..=1.0).contains(v)));
        assert!(clipped.iter().any(|&v| v.abs() > 0.999));
    }

    #[test]
    fn click_positions_are_exact() {
        let sr = 48000u32;
        let bpm = 60.0f64;
        let beats = 5usize;
        let gain = 0.8f64;
        let c = click_track_pcm(sr, 1, bpm, beats, gain);
        let spb = (sr as f64 * 60.0 / bpm).round() as usize;
        assert_eq!(c.len(), spb * beats);
        for b in 0..beats {
            let start = b * spb;
            assert!(
                (c[start] - gain as f32).abs() < 1e-6,
                "beat {b} 起始值应为 gain"
            );
            // 拍点之间应为静音
            if b > 0 {
                let prev_end = (b - 1) * spb + (sr as f64 * 0.01) as usize;
                assert!(c[prev_end..start].iter().all(|&v| v == 0.0));
            }
        }
    }

    #[test]
    fn anti_phase_is_preserved() {
        let left = tone_pcm(48000, 1, 200, 440.0, 0.5);
        let stereo = anti_phase_stereo(&left);
        assert_eq!(stereo.len(), left.len() * 2);
        for (i, &l) in left.iter().enumerate() {
            assert!((stereo[i * 2] - l).abs() < 1e-7);
            assert!((stereo[i * 2 + 1] + l).abs() < 1e-7);
        }
        // 反相结构成立：声道平均折叠为 0，但总能量精确保留（每声道各一份）
        let folded: Vec<f32> = stereo.chunks(2).map(|f| (f[0] + f[1]) * 0.5).collect();
        assert!(folded.iter().all(|&v| v.abs() < 1e-7));
        let energy_stereo: f64 = stereo.iter().map(|&v| (v as f64).powi(2)).sum();
        let energy_left: f64 = left.iter().map(|&v| (v as f64).powi(2)).sum();
        assert!(
            (energy_stereo - 2.0 * energy_left).abs() < 1e-6,
            "反相不应丢失能量"
        );
    }

    #[test]
    fn band_rms_separates_markers() {
        let t440 = tone_pcm(48000, 1, 300, 440.0, 0.5);
        let t880 = tone_pcm(48000, 1, 300, 880.0, 0.5);
        let r440_440 = band_rms(&t440, 1, 48000, 400.0, 480.0);
        let r880_440 = band_rms(&t880, 1, 48000, 400.0, 480.0);
        assert!(
            r440_440 > r880_440 + 12.0,
            "440 带通应显著分离 440 与 880：{r440_440} vs {r880_440}"
        );
        let r440_880 = band_rms(&t440, 1, 48000, 840.0, 920.0);
        let r880_880 = band_rms(&t880, 1, 48000, 840.0, 920.0);
        assert!(
            r880_880 > r440_880 + 12.0,
            "880 带通应显著分离 880 与 440：{r880_880} vs {r440_880}"
        );
    }

    #[test]
    fn band_rms_handles_interleaved_stereo() {
        let mono = tone_pcm(48000, 1, 300, 440.0, 0.5);
        let interleaved = tone_pcm(48000, 2, 300, 440.0, 0.5);
        let stereo_rms = band_rms(&interleaved, 2, 48000, 400.0, 480.0);
        let mono_rms = band_rms(&mono, 1, 48000, 400.0, 480.0);
        assert!(
            (stereo_rms - mono_rms).abs() < 1e-9,
            "同相立体声应与单声道测量一致：{stereo_rms} vs {mono_rms}"
        );
    }

    #[test]
    fn band_rms_skips_warmup_transient() {
        // 前 50 ms 的通带内强干扰必须被预热丢弃，测量只反映稳态信号
        let sr = 48000u32;
        let warmup = (sr as f64 * 0.05) as usize;
        let mut samples = tone_pcm(sr, 1, 300, 440.0, 0.9);
        let steady = tone_pcm(sr, 1, 250, 440.0, 0.5);
        samples[warmup..].copy_from_slice(&steady);
        let rms = band_rms(&samples, 1, sr, 400.0, 480.0);
        let pure = band_rms(&steady, 1, sr, 400.0, 480.0);
        assert!(rms < -7.5, "预热应丢弃前 50 ms 强干扰，rms={rms}");
        assert!(
            (rms - pure).abs() < 1.0,
            "预热后应接近纯 0.5 gain 的 440 音：{rms} vs {pure}"
        );
    }

    #[test]
    fn band_rms_processes_warmup_input() {
        let sr = 48000u32;
        let warmup = (sr as f64 * 0.05) as usize;
        let mut samples = vec![0.0f32; warmup + sr as usize / 10];
        samples[warmup - 1] = 1.0;
        let rms = band_rms(&samples, 1, sr, 400.0, 480.0);
        assert!(rms.is_finite(), "预热输入必须进入滤波器状态");
    }

    #[test]
    fn silence_padding_preserves_complete_frames() {
        let source = tone_pcm(48000, 2, 100, 440.0, 0.5);
        let padded = with_silence(&source, 2, 48000, 25, 50);
        let front = 48000 * 25 / 1000 * 2;
        let back = 48000 * 50 / 1000 * 2;
        assert_eq!(padded.len(), front + source.len() + back);
        assert!(padded[..front].iter().all(|&sample| sample == 0.0));
        assert_eq!(&padded[front..front + source.len()], source.as_slice());
        assert!(padded[front + source.len()..]
            .iter()
            .all(|&sample| sample == 0.0));
    }

    #[test]
    #[should_panic(expected = "sample_rate must be > 0")]
    fn tone_rejects_zero_sample_rate() {
        let _ = tone_pcm(0, 1, 100, 440.0, 0.5);
    }

    #[test]
    #[should_panic(expected = "channels must be > 0")]
    fn tone_rejects_zero_channels() {
        let _ = tone_pcm(48000, 0, 100, 440.0, 0.5);
    }

    #[test]
    #[should_panic(expected = "bpm must be finite and > 0")]
    fn click_rejects_non_positive_bpm() {
        let _ = click_track_pcm(48000, 1, 0.0, 4, 0.5);
    }

    #[test]
    #[should_panic(expected = "band must satisfy 0 < low_hz < high_hz")]
    fn band_rms_rejects_invalid_band() {
        let t = tone_pcm(48000, 1, 100, 440.0, 0.5);
        let _ = band_rms(&t, 1, 48000, 500.0, 400.0);
    }

    #[test]
    #[should_panic(expected = "gain must be finite")]
    fn tone_rejects_nan_gain() {
        let _ = tone_pcm(48000, 1, 100, 440.0, f64::NAN);
    }

    #[test]
    #[should_panic(expected = "frequency_hz must be below Nyquist")]
    fn tone_rejects_frequency_above_nyquist() {
        let _ = tone_pcm(48000, 1, 100, 24000.0, 0.5);
    }

    #[test]
    #[should_panic(expected = "gain must be finite")]
    fn click_rejects_nan_gain() {
        let _ = click_track_pcm(48000, 1, 120.0, 4, f64::INFINITY);
    }

    #[test]
    #[should_panic(expected = "samples must be finite and within [-1, 1]")]
    fn anti_phase_rejects_invalid_samples() {
        let _ = anti_phase_stereo(&[f32::NAN]);
    }

    #[test]
    #[should_panic(expected = "samples must be finite and within [-1, 1]")]
    fn silence_padding_rejects_invalid_samples() {
        let _ = with_silence(&[1.5], 1, 48000, 0, 0);
    }

    #[test]
    #[should_panic(expected = "samples must be finite and within [-1, 1]")]
    fn band_rms_rejects_invalid_samples() {
        let _ = band_rms(&[f32::INFINITY], 1, 48000, 400.0, 480.0);
    }
}
