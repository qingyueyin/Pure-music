// 分析阈值配置与 canonical config hash。
// 所有阈值集中在 AnalysisConfig，按字段名排序的 canonical JSON 序列化后计算 SHA-256 小写十六进制。

use serde::{Deserialize, Serialize};

pub const PROFILE_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AnalysisConfig {
    pub sample_rate_hz: u32,
    pub analysis_chunk_samples: usize,
    pub fft_window: usize,
    pub fft_hop: usize,
    pub audible_floor_dbfs: f64,
    pub audible_margin_db: f64,
    pub audible_min_ms: f64,
    pub region_window_beats: u32,
    pub region_window_ms_min: f64,
    pub region_window_ms_max: f64,
    pub region_window_no_tempo_ms: f64,
    pub tempo_min_content_ms: f64,
    pub onset_mean_window_s: f64,
    pub onset_mean_scale: f64,
    pub onset_norm_percentile: f64,
    pub bpm_min: f64,
    pub bpm_max: f64,
    pub bpm_center_prior: f64,
    pub beat_snap_window: f64,
    pub beat_min_spacing: f64,
    pub min_beats: usize,
    pub downbeat_threshold: f64,
    pub corr_lag2_weight: f64,
    pub corr_half_lag_weight: f64,
    pub stability_tolerance: f64,
    pub beat_conf_stability_weight: f64,
    pub beat_conf_onset_weight: f64,
    pub beat_conf_corr_weight: f64,
    pub downbeat_full_flux_weight: f64,
    pub downbeat_low_flux_weight: f64,
    pub analysis_version: u32,
}

impl Default for AnalysisConfig {
    fn default() -> Self {
        AnalysisConfig {
            sample_rate_hz: 11025,
            analysis_chunk_samples: 4096,
            fft_window: 1024,
            fft_hop: 256,
            audible_floor_dbfs: -60.0,
            audible_margin_db: 36.0,
            audible_min_ms: 140.0,
            region_window_beats: 16,
            region_window_ms_min: 3000.0,
            region_window_ms_max: 12000.0,
            region_window_no_tempo_ms: 7000.0,
            tempo_min_content_ms: 8000.0,
            onset_mean_window_s: 1.0,
            onset_mean_scale: 0.65,
            onset_norm_percentile: 0.95,
            bpm_min: 65.0,
            bpm_max: 190.0,
            bpm_center_prior: 115.0,
            beat_snap_window: 0.16,
            beat_min_spacing: 0.55,
            min_beats: 8,
            downbeat_threshold: 0.58,
            corr_lag2_weight: 0.35,
            corr_half_lag_weight: 0.12,
            stability_tolerance: 0.12,
            beat_conf_stability_weight: 0.20,
            beat_conf_onset_weight: 0.34,
            beat_conf_corr_weight: 0.46,
            downbeat_full_flux_weight: 0.25,
            downbeat_low_flux_weight: 0.75,
            analysis_version: 1,
        }
    }
}

/// canonical config hash：按字段名排序的 JSON 序列化（serde_json 默认 Map 为 BTreeMap）后做 SHA-256。
pub fn analysis_config_hash(config: &AnalysisConfig) -> Result<String, ConfigError> {
    validate_analysis_config(config)?;
    let value = serde_json::to_value(config)
        .map_err(|error| ConfigError::Serialization(error.to_string()))?;
    let canonical = serde_json::to_string(&value)
        .map_err(|error| ConfigError::Serialization(error.to_string()))?;
    Ok(sha256_hex(canonical.as_bytes()))
}

/// 校验 AnalysisConfig：所有阈值有限，幅度/时长/比例字段为正，顺序约束成立。任何非法配置在分析前拒绝。
pub fn validate_analysis_config(c: &AnalysisConfig) -> Result<(), ConfigError> {
    // dBFS 类字段只要求有限（可为负）
    for (name, v) in [("audible_floor_dbfs", c.audible_floor_dbfs)] {
        if !v.is_finite() {
            return Err(ConfigError::NonFinite(name.to_string()));
        }
    }
    // 幅度差/时长/比例/权重类字段必须为正
    for (name, v) in [
        ("audible_margin_db", c.audible_margin_db),
        ("audible_min_ms", c.audible_min_ms),
        ("region_window_ms_min", c.region_window_ms_min),
        ("region_window_ms_max", c.region_window_ms_max),
        ("region_window_no_tempo_ms", c.region_window_no_tempo_ms),
        ("tempo_min_content_ms", c.tempo_min_content_ms),
        ("onset_mean_window_s", c.onset_mean_window_s),
        ("onset_mean_scale", c.onset_mean_scale),
        ("onset_norm_percentile", c.onset_norm_percentile),
        ("bpm_min", c.bpm_min),
        ("bpm_max", c.bpm_max),
        ("bpm_center_prior", c.bpm_center_prior),
        ("beat_snap_window", c.beat_snap_window),
        ("beat_min_spacing", c.beat_min_spacing),
        ("downbeat_threshold", c.downbeat_threshold),
        ("corr_lag2_weight", c.corr_lag2_weight),
        ("corr_half_lag_weight", c.corr_half_lag_weight),
        ("stability_tolerance", c.stability_tolerance),
        ("beat_conf_stability_weight", c.beat_conf_stability_weight),
        ("beat_conf_onset_weight", c.beat_conf_onset_weight),
        ("beat_conf_corr_weight", c.beat_conf_corr_weight),
        ("downbeat_full_flux_weight", c.downbeat_full_flux_weight),
        ("downbeat_low_flux_weight", c.downbeat_low_flux_weight),
    ] {
        if !v.is_finite() {
            return Err(ConfigError::NonFinite(name.to_string()));
        }
        if v <= 0.0 {
            return Err(ConfigError::OutOfRange(name.to_string()));
        }
    }
    if c.sample_rate_hz == 0
        || c.analysis_chunk_samples == 0
        || c.fft_window == 0
        || c.fft_hop == 0
        || c.min_beats == 0
        || c.region_window_beats == 0
    {
        return Err(ConfigError::OutOfRange(
            "count/rate field must be > 0".to_string(),
        ));
    }
    if c.fft_hop >= c.fft_window {
        return Err(ConfigError::Order(
            "fft_hop must be < fft_window".to_string(),
        ));
    }
    if c.bpm_min >= c.bpm_max {
        return Err(ConfigError::Order("bpm_min must be < bpm_max".to_string()));
    }
    if c.region_window_ms_min > c.region_window_ms_max {
        return Err(ConfigError::Order(
            "region_window_ms_min must be <= region_window_ms_max".to_string(),
        ));
    }
    if !c.fft_window.is_power_of_two() {
        return Err(ConfigError::Order(
            "fft_window must be a power of two".to_string(),
        ));
    }
    if c.analysis_version == 0 {
        return Err(ConfigError::OutOfRange(
            "analysis_version must be > 0".to_string(),
        ));
    }
    if c.audible_floor_dbfs > 0.0 {
        return Err(ConfigError::OutOfRange(
            "audible_floor_dbfs must be <= 0".to_string(),
        ));
    }
    if c.onset_mean_scale > 1.0
        || c.beat_snap_window > 1.0
        || c.beat_min_spacing > 1.0
        || c.downbeat_threshold > 1.0
        || c.corr_lag2_weight > 1.0
        || c.corr_half_lag_weight > 1.0
        || c.stability_tolerance > 1.0
        || c.beat_conf_stability_weight > 1.0
        || c.beat_conf_onset_weight > 1.0
        || c.beat_conf_corr_weight > 1.0
        || c.downbeat_full_flux_weight > 1.0
        || c.downbeat_low_flux_weight > 1.0
    {
        return Err(ConfigError::OutOfRange(
            "ratio and weight fields must be <= 1".to_string(),
        ));
    }
    if !(0.0..=1.0).contains(&c.onset_norm_percentile) || c.onset_norm_percentile == 0.0 {
        return Err(ConfigError::OutOfRange(
            "onset_norm_percentile must be in (0, 1]".to_string(),
        ));
    }
    if !(c.bpm_min..=c.bpm_max).contains(&c.bpm_center_prior) {
        return Err(ConfigError::OutOfRange(
            "bpm_center_prior must be within bpm_min..=bpm_max".to_string(),
        ));
    }
    if (c.beat_conf_stability_weight + c.beat_conf_onset_weight + c.beat_conf_corr_weight - 1.0)
        .abs()
        > 1e-9
        || (c.downbeat_full_flux_weight + c.downbeat_low_flux_weight - 1.0).abs() > 1e-9
    {
        return Err(ConfigError::Order(
            "confidence weights must sum to 1".to_string(),
        ));
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq)]
pub enum ConfigError {
    NonFinite(String),
    OutOfRange(String),
    Order(String),
    Serialization(String),
}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConfigError::NonFinite(field) => write!(f, "config field {field} must be finite"),
            ConfigError::OutOfRange(msg) => write!(f, "config out of range: {msg}"),
            ConfigError::Order(msg) => write!(f, "config order violation: {msg}"),
            ConfigError::Serialization(msg) => write!(f, "config serialization failed: {msg}"),
        }
    }
}

// ---- 内联 SHA-256：标准 FIPS 180-4 实现，避免引入新 crate。----

fn sha256(data: &[u8]) -> [u8; 32] {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];

    let bit_len = (data.len() as u64).wrapping_mul(8);
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bit_len.to_be_bytes());

    let mut w = [0u32; 64];
    for block in msg.chunks_exact(64) {
        for (i, chunk) in w.iter_mut().take(16).enumerate() {
            *chunk = u32::from_be_bytes([
                block[i * 4],
                block[i * 4 + 1],
                block[i * 4 + 2],
                block[i * 4 + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let temp1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }

    let mut out = [0u8; 32];
    for (i, v) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&v.to_be_bytes());
    }
    out
}

fn sha256_hex(data: &[u8]) -> String {
    sha256(data).iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod unit_tests {
    use super::*;

    #[test]
    fn sha256_matches_known_vectors() {
        // FIPS 180-4 标准测试向量
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
    }
}
