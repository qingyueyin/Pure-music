// 分析数学模块测试。

use crate::smart_transition::audible_range::{
    find_audible_range, normalize_onset, AnalysisMathError, AudibleRangeDetector,
};
use crate::smart_transition::channel_fold::{fold_frame, rms_peak_dbfs};
use crate::smart_transition::resample::{LinearResampler, LowPassState};

fn tone(sample_rate: u32, frequency_hz: f64, gain: f64, frames: usize) -> Vec<f32> {
    (0..frames)
        .map(|i| {
            (gain
                * (2.0 * std::f64::consts::PI * frequency_hz * i as f64 / sample_rate as f64).sin())
                as f32
        })
        .collect()
}

#[test]
fn anti_phase_fold_keeps_signal() {
    let left = tone(48000, 440.0, 0.5, 4800);
    // 反相立体声：每帧 [s, -s]。mean=0 < 0.125*rms，走 peak 分支，folded == left
    let folded: Vec<f32> = left.iter().map(|&s| fold_frame(&[s, -s])).collect();
    for (a, b) in folded.iter().zip(left.iter()) {
        assert!((a - b).abs() < 1e-6);
    }
    let (rms_db, _) = rms_peak_dbfs(&folded);
    assert!(rms_db > -10.0, "rms={rms_db}");
    // 同相帧走 mean 分支
    let mono_folded: Vec<f32> = left.iter().map(|&s| fold_frame(&[s, s])).collect();
    assert!((mono_folded[0] - left[0]).abs() < 1e-6);
}

#[test]
fn chunked_resample_matches_single_pass() {
    let src = 48000u32;
    let dst = 11025u32;
    let input = tone(src, 440.0, 0.5, 48000);
    let mut single = LinearResampler::new(src, dst);
    let whole = single.push(&input);
    let mut chunked = LinearResampler::new(src, dst);
    let mut parts = Vec::new();
    for chunk in input.chunks(1000) {
        parts.extend(chunked.push(chunk));
    }
    assert_eq!(parts.len(), whole.len());
    for (a, b) in parts.iter().zip(whole.iter()) {
        assert!((a - b).abs() < 1e-6, "{a} vs {b}");
    }
    // 输出采样率正确：约 dst/src 比例，且输出值合法
    let expected_len = (input.len() as f64 * dst as f64 / src as f64).round() as usize;
    assert!((whole.len() as isize - expected_len as isize).abs() <= 1);
    assert!(whole
        .iter()
        .all(|&v| v.is_finite() && (-1.0..=1.0).contains(&v)));
}

#[test]
fn low_pass_is_stable_and_reduces_high_frequency() {
    let sr = 48000u32;
    let input = tone(sr, 4000.0, 0.5, 48000);
    let mut lp = LowPassState::new(sr, 1000.0);
    let mut out = Vec::with_capacity(input.len());
    for &s in &input {
        out.push(lp.process(s as f64) as f32);
    }
    assert!(out.iter().all(|v| v.is_finite()));
    let (_, peak_in) = rms_peak_dbfs(&input);
    let (_, peak_out) = rms_peak_dbfs(&out);
    // 4 kHz 信号被 1 kHz 低通衰减
    assert!(
        peak_out < peak_in - 3.0,
        "peak_in={peak_in} peak_out={peak_out}"
    );
}

#[test]
fn audible_range_requires_140ms() {
    let sr = 48000u32;
    let window = (sr as f64 * 0.140).round() as usize; // 6720
                                                       // 100 ms 短音：不足 140 ms，不算可听边界
    let short = tone(sr, 440.0, 0.5, (sr as f64 * 0.100) as usize);
    assert_eq!(find_audible_range(&short, sr, -12.0, 140.0).unwrap(), None);
    // 150 ms 长音：达到门槛
    let long = tone(sr, 440.0, 0.5, (sr as f64 * 0.150) as usize);
    let r = find_audible_range(&long, sr, -12.0, 140.0).unwrap();
    assert_eq!(r, Some((0, (sr as f64 * 0.150) as usize)));
    // 短音 + 静音 + 长音：范围从长音段开始（滑动峰值窗口允许 start 提前最多一个峰值窗口）
    let mut mixed = short.clone();
    mixed.extend(std::iter::repeat(0.0f32).take(sr as usize));
    mixed.extend(long.iter().copied());
    let r = find_audible_range(&mixed, sr, -12.0, 140.0).unwrap();
    let (start, end) = r.expect("mixed should have audible range");
    let long_start = short.len() + sr as usize;
    let peak_win = ((sr as f64) * 0.010) as usize;
    assert!(
        start <= long_start && start + peak_win >= long_start,
        "start={start} long_start={long_start}"
    );
    assert_eq!(end, mixed.len());
    assert!(end - start >= window);
}

#[test]
fn silence_floor_is_clamped() {
    let sr = 48000u32;
    // integrated_rms 极低时门限钳到 -60 dBFS，-66 dBFS 的小信号不被当作可听
    let tiny = tone(sr, 440.0, 0.0005, sr as usize); // -66 dBFS
    assert_eq!(find_audible_range(&tiny, sr, -200.0, 140.0).unwrap(), None);
    // 但 -40 dBFS 的信号超过 -60 门限
    let audible = tone(sr, 440.0, 0.01, sr as usize);
    assert!(find_audible_range(&audible, sr, -200.0, 140.0)
        .unwrap()
        .is_some());
    // 全零输入无范围
    let silence = vec![0.0f32; sr as usize];
    assert_eq!(
        find_audible_range(&silence, sr, -12.0, 140.0).unwrap(),
        None
    );
    // 空输入无范围
    assert_eq!(find_audible_range(&[], sr, -12.0, 140.0).unwrap(), None);
}

#[test]
fn onset_normalization_uses_p95() {
    // 100 帧：前 95 帧 1.0，后 5 帧 0；帧率 100/s，均值窗口 1 s（半径 50）
    let onset: Vec<f64> = (0..100).map(|i| if i < 95 { 1.0 } else { 0.0 }).collect();
    let out = normalize_onset(&onset, 100.0, 1.0, 0.65, 0.95).unwrap();
    assert_eq!(out.len(), 100);
    // 非平凡：既有非零也有 0
    assert!(out.iter().any(|&v| v > 0.0));
    assert!(out.iter().any(|&v| v == 0.0));
    // p95 归一化：约 95% 的值不超过 1，最大值 >= 1（p95 <= max）
    assert!(out.iter().all(|&v| v >= 0.0));
    let count_le_one = out.iter().filter(|&&v| v <= 1.0 + 1e-9).count();
    assert!(count_le_one >= 95, "only {count_le_one} of 100 <= 1.0");
    let max_v = out.iter().cloned().fold(0.0f64, f64::max);
    assert!(max_v >= 1.0 - 1e-9, "max={max_v}");
    // 尾部 5 帧保持 0
    assert!(out[95..].iter().all(|&v| v == 0.0));
    // 全零输入：全零输出
    let zeros = vec![0.0f64; 50];
    assert!(normalize_onset(&zeros, 100.0, 1.0, 0.65, 0.95)
        .unwrap()
        .iter()
        .all(|&v| v == 0.0));
    // 空输入
    assert!(normalize_onset(&[], 100.0, 1.0, 0.65, 0.95)
        .unwrap()
        .is_empty());
}

#[test]
fn audible_range_streaming_matches_single_pass() {
    let sample_rate = 48000u32;
    let mut samples = vec![0.0f32; sample_rate as usize];
    samples.extend(tone(sample_rate, 440.0, 0.5, sample_rate as usize * 2));
    samples.extend(vec![0.0f32; sample_rate as usize]);
    let expected = find_audible_range(&samples, sample_rate, -12.0, 140.0).unwrap();
    let mut detector = AudibleRangeDetector::new(sample_rate, -12.0, 140.0).unwrap();
    for chunk in samples.chunks(997) {
        detector.push(chunk).unwrap();
        assert!(detector.buffered_samples() <= sample_rate as usize / 100);
    }
    assert_eq!(detector.finish(), expected);
}

#[test]
fn analysis_math_rejects_non_finite_input() {
    assert!(matches!(
        find_audible_range(&[f32::NAN], 48000, -12.0, 140.0),
        Err(AnalysisMathError::NonFinite(_))
    ));
    assert!(matches!(
        normalize_onset(&[0.0, f64::NAN], 100.0, 1.0, 0.65, 0.95),
        Err(AnalysisMathError::NonFinite(_))
    ));
    assert!(matches!(
        normalize_onset(&[0.0, 1.0], 100.0, 1.0, 0.65, 1.5),
        Err(AnalysisMathError::OutOfRange(_))
    ));
}
