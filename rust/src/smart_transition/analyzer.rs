use std::collections::VecDeque;
use std::fs::File;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

use symphonia::core::audio::sample::Sample;
use symphonia::core::codecs::audio::AudioDecoderOptions;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;

use super::channel_fold::fold_frame;
use super::config::{analysis_config_hash, validate_analysis_config, AnalysisConfig};
use super::model::{validate_track_profile, RegionProfile, TempoProfile, TrackProfile};
use super::resample::{LinearResampler, LowPassState};

#[derive(Debug)]
pub enum AnalyzerError {
    Cancelled,
    InvalidConfig(String),
    Io(String),
    Unsupported(String),
    Decode(String),
    InvalidProfile(String),
}

impl std::fmt::Display for AnalyzerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Cancelled => write!(f, "analysis cancelled"),
            Self::InvalidConfig(message) => write!(f, "invalid analysis config: {message}"),
            Self::Io(message) => write!(f, "audio open failed: {message}"),
            Self::Unsupported(message) => write!(f, "unsupported audio: {message}"),
            Self::Decode(message) => write!(f, "audio decode failed: {message}"),
            Self::InvalidProfile(message) => write!(f, "invalid analysis result: {message}"),
        }
    }
}

#[derive(Clone, Copy)]
struct EnergyWindow {
    start_sample: usize,
    end_sample: usize,
    sum_sq: f64,
    peak: f64,
}

struct SpectralFrame {
    time_ms: f64,
    full_flux: f64,
    low_flux: f64,
}

struct StreamingAnalysis {
    config: AnalysisConfig,
    sample_count: usize,
    sum_sq: f64,
    peak: f64,
    energy_start: usize,
    energy_sum_sq: f64,
    energy_peak: f64,
    energy_count: usize,
    energy_windows: Vec<EnergyWindow>,
    spectral_samples: VecDeque<f32>,
    spectral_start_sample: usize,
    hann: Vec<f64>,
    previous_spectrum: Option<Vec<f64>>,
    spectral_frames: Vec<SpectralFrame>,
}

impl StreamingAnalysis {
    fn new(config: &AnalysisConfig) -> Self {
        let hann = (0..config.fft_window)
            .map(|index| {
                let phase = 2.0 * std::f64::consts::PI * index as f64
                    / (config.fft_window.saturating_sub(1).max(1)) as f64;
                0.5 - 0.5 * phase.cos()
            })
            .collect();
        Self {
            config: config.clone(),
            sample_count: 0,
            sum_sq: 0.0,
            peak: 0.0,
            energy_start: 0,
            energy_sum_sq: 0.0,
            energy_peak: 0.0,
            energy_count: 0,
            energy_windows: Vec::new(),
            spectral_samples: VecDeque::with_capacity(config.fft_window),
            spectral_start_sample: 0,
            hann,
            previous_spectrum: None,
            spectral_frames: Vec::new(),
        }
    }

    fn push_chunk(&mut self, samples: &[f32]) {
        let energy_window_samples = (self.config.sample_rate_hz as usize / 100).max(1);
        for &sample in samples {
            let value = if sample.is_finite() {
                sample as f64
            } else {
                0.0
            };
            self.sum_sq += value * value;
            self.peak = self.peak.max(value.abs());
            self.sample_count += 1;

            self.energy_sum_sq += value * value;
            self.energy_peak = self.energy_peak.max(value.abs());
            self.energy_count += 1;
            if self.energy_count >= energy_window_samples {
                self.finish_energy_window();
            }

            self.spectral_samples.push_back(value as f32);
            if self.spectral_samples.len() >= self.config.fft_window {
                self.finish_spectral_frame();
                let remove = self.config.fft_hop.min(self.spectral_samples.len());
                for _ in 0..remove {
                    self.spectral_samples.pop_front();
                }
                self.spectral_start_sample += remove;
            }
        }
    }

    fn finish_energy_window(&mut self) {
        if self.energy_count == 0 {
            return;
        }
        self.energy_windows.push(EnergyWindow {
            start_sample: self.energy_start,
            end_sample: self.energy_start + self.energy_count,
            sum_sq: self.energy_sum_sq,
            peak: self.energy_peak,
        });
        self.energy_start += self.energy_count;
        self.energy_sum_sq = 0.0;
        self.energy_peak = 0.0;
        self.energy_count = 0;
    }

    fn finish_spectral_frame(&mut self) {
        let mut real = vec![0.0; self.config.fft_window];
        let mut imag = vec![0.0; self.config.fft_window];
        for (index, sample) in self.spectral_samples.iter().take(real.len()).enumerate() {
            real[index] = *sample as f64 * self.hann[index];
        }
        fft_in_place(&mut real, &mut imag);
        let bins = self.config.fft_window / 2 + 1;
        let mut spectrum = Vec::with_capacity(bins);
        for index in 0..bins {
            spectrum.push((real[index] * real[index] + imag[index] * imag[index]).sqrt());
        }

        if let Some(previous) = &self.previous_spectrum {
            let low_bin = ((220.0 * self.config.fft_window as f64
                / self.config.sample_rate_hz as f64)
                .floor() as usize)
                .min(bins.saturating_sub(1));
            let mut full_flux = 0.0;
            let mut low_flux = 0.0;
            for index in 1..bins {
                let difference = (spectrum[index] - previous[index]).max(0.0);
                full_flux += difference;
                if index <= low_bin {
                    low_flux += difference;
                }
            }
            let center_sample = self.spectral_start_sample + self.config.fft_window / 2;
            self.spectral_frames.push(SpectralFrame {
                time_ms: center_sample as f64 * 1000.0 / self.config.sample_rate_hz as f64,
                full_flux,
                low_flux,
            });
        }
        self.previous_spectrum = Some(spectrum);
    }

    fn finish(mut self, profile_key: String) -> Result<TrackProfile, AnalyzerError> {
        self.finish_energy_window();
        if self.sample_count == 0 {
            return Err(AnalyzerError::Decode(
                "decoder produced no samples".to_string(),
            ));
        }
        let sample_rate = self.config.sample_rate_hz as f64;
        let duration_ms = ((self.sample_count as f64 * 1000.0 / sample_rate).round() as u64).max(1);
        let rms = (self.sum_sq / self.sample_count as f64).sqrt();
        let integrated_rms_dbfs = amplitude_dbfs(rms);
        let peak_dbfs = amplitude_dbfs(self.peak);
        let threshold_dbfs = (-60.0f64).max(integrated_rms_dbfs - self.config.audible_margin_db);
        let (audible_start_sample, audible_end_sample) = audible_range_from_windows(
            &self.energy_windows,
            threshold_dbfs,
            self.config.audible_min_ms,
            self.config.sample_rate_hz,
            self.sample_count,
        );
        let audible_start_ms = (audible_start_sample as f64 * 1000.0 / sample_rate).round() as u64;
        let audible_end_ms = (audible_end_sample as f64 * 1000.0 / sample_rate).round() as u64;

        let (tempo, normalized_full, normalized_low) = tempo_profile(
            &self.spectral_frames,
            duration_ms,
            &self.config,
            audible_start_ms as f64,
            audible_end_ms as f64,
        );
        let region_window_ms = tempo
            .as_ref()
            .filter(|tempo| tempo.beat_confidence >= 0.58)
            .map(|tempo| {
                (self.config.region_window_beats as f64 * 60_000.0 / tempo.bpm).clamp(
                    self.config.region_window_ms_min,
                    self.config.region_window_ms_max,
                )
            })
            .unwrap_or(self.config.region_window_no_tempo_ms);
        let audible_start = audible_start_ms as f64;
        let audible_end = audible_end_ms.max(audible_start_ms) as f64;
        let entrance_end = (audible_start + region_window_ms).min(audible_end);
        let exit_start = (audible_end - region_window_ms).max(audible_start);
        let entrance = region_profile(
            audible_start,
            entrance_end,
            threshold_dbfs,
            &self.energy_windows,
            &self.spectral_frames,
            &normalized_full,
            true,
            self.config.sample_rate_hz,
        );
        let exit = region_profile(
            exit_start,
            audible_end,
            threshold_dbfs,
            &self.energy_windows,
            &self.spectral_frames,
            &normalized_full,
            false,
            self.config.sample_rate_hz,
        );

        let profile = TrackProfile {
            profile_key,
            duration_ms,
            audible_start_ms: audible_start_ms.min(duration_ms),
            audible_end_ms: audible_end_ms.min(duration_ms),
            integrated_rms_dbfs,
            peak_dbfs: peak_dbfs.max(integrated_rms_dbfs),
            tempo,
            entrance,
            exit,
            analysis_version: self.config.analysis_version,
            config_hash: analysis_config_hash(&self.config)
                .map_err(|error| AnalyzerError::InvalidConfig(error.to_string()))?,
        };
        let _ = normalized_low;
        validate_track_profile(&profile)
            .map_err(|error| AnalyzerError::InvalidProfile(error.to_string()))?;
        Ok(profile)
    }
}

pub fn analyze_file(
    path: &str,
    profile_key: String,
    config: &AnalysisConfig,
    cancelled: &AtomicBool,
) -> Result<TrackProfile, AnalyzerError> {
    validate_analysis_config(config)
        .map_err(|error| AnalyzerError::InvalidConfig(error.to_string()))?;
    check_cancelled(cancelled)?;
    let source = File::open(path).map_err(|error| AnalyzerError::Io(error.to_string()))?;
    let media_source = MediaSourceStream::new(Box::new(source), Default::default());
    let mut hint = Hint::new();
    if let Some(extension) = Path::new(path).extension().and_then(|value| value.to_str()) {
        hint.with_extension(extension);
    }
    let mut format = symphonia::default::get_probe()
        .probe(
            &hint,
            media_source,
            FormatOptions::default(),
            MetadataOptions::default(),
        )
        .map_err(|error| AnalyzerError::Unsupported(error.to_string()))?;
    let track = format
        .default_track(TrackType::Audio)
        .ok_or_else(|| AnalyzerError::Unsupported("no audio track".to_string()))?;
    let audio_parameters = track
        .codec_params
        .as_ref()
        .and_then(|parameters| parameters.audio())
        .ok_or_else(|| AnalyzerError::Unsupported("missing audio codec parameters".to_string()))?;
    let mut decoder = symphonia::default::get_codecs()
        .make_audio_decoder(audio_parameters, &AudioDecoderOptions::default())
        .map_err(|error| AnalyzerError::Unsupported(error.to_string()))?;
    let track_id = track.id;
    let mut analysis = StreamingAnalysis::new(config);
    let mut decoded = Vec::<f32>::new();
    let mut mono = Vec::<f32>::new();
    let mut resampler: Option<LinearResampler> = None;
    let mut low_pass: Option<LowPassState> = None;
    let mut source_rate = 0u32;

    loop {
        check_cancelled(cancelled)?;
        let packet = match format.next_packet() {
            Ok(Some(packet)) => packet,
            Ok(None) => break,
            Err(SymphoniaError::ResetRequired) => {
                return Err(AnalyzerError::Decode(
                    "audio track changed during analysis".to_string(),
                ));
            }
            Err(error) => return Err(AnalyzerError::Decode(error.to_string())),
        };
        if packet.track_id != track_id {
            continue;
        }
        let audio = match decoder.decode(&packet) {
            Ok(audio) => audio,
            Err(SymphoniaError::DecodeError(_)) | Err(SymphoniaError::IoError(_)) => continue,
            Err(error) => return Err(AnalyzerError::Decode(error.to_string())),
        };
        check_cancelled(cancelled)?;
        let packet_rate = audio.spec().rate();
        if packet_rate == 0 {
            return Err(AnalyzerError::Decode("zero sample rate".to_string()));
        }
        if source_rate == 0 {
            source_rate = packet_rate;
            resampler = Some(LinearResampler::new(source_rate, config.sample_rate_hz));
            if source_rate > config.sample_rate_hz {
                low_pass = Some(LowPassState::new(
                    source_rate,
                    config.sample_rate_hz as f64 * 0.45,
                ));
            }
        } else if source_rate != packet_rate {
            return Err(AnalyzerError::Decode(
                "sample rate changed during analysis".to_string(),
            ));
        }
        let channels = audio.spec().channels().count();
        if channels == 0 {
            continue;
        }
        decoded.resize(audio.samples_interleaved(), f32::MID);
        audio.copy_to_slice_interleaved(&mut decoded);
        mono.clear();
        mono.reserve(decoded.len() / channels);
        for frame in decoded.chunks_exact(channels) {
            let mut sample = fold_frame(frame);
            if let Some(filter) = &mut low_pass {
                sample = filter.process(sample as f64) as f32;
            }
            mono.push(sample);
        }
        let output = resampler
            .as_mut()
            .expect("resampler initialized with source rate")
            .push(&mono);
        for chunk in output.chunks(config.analysis_chunk_samples) {
            check_cancelled(cancelled)?;
            analysis.push_chunk(chunk);
            check_cancelled(cancelled)?;
        }
    }
    check_cancelled(cancelled)?;
    analysis.finish(profile_key)
}

fn check_cancelled(cancelled: &AtomicBool) -> Result<(), AnalyzerError> {
    if cancelled.load(Ordering::Acquire) {
        Err(AnalyzerError::Cancelled)
    } else {
        Ok(())
    }
}

fn amplitude_dbfs(value: f64) -> f64 {
    if value > 0.0 {
        (20.0 * value.log10()).clamp(-160.0, 24.0)
    } else {
        -160.0
    }
}

fn audible_range_from_windows(
    windows: &[EnergyWindow],
    threshold_dbfs: f64,
    minimum_ms: f64,
    sample_rate: u32,
    sample_count: usize,
) -> (usize, usize) {
    let threshold = 10f64.powf(threshold_dbfs / 20.0);
    let minimum_samples = (minimum_ms * sample_rate as f64 / 1000.0).ceil().max(1.0) as usize;
    let mut current_start = 0usize;
    let mut current_samples = 0usize;
    let mut first = None;
    let mut last = None;
    for window in windows {
        if window.peak >= threshold {
            if current_samples == 0 {
                current_start = window.start_sample;
            }
            current_samples += window.end_sample.saturating_sub(window.start_sample);
            if current_samples >= minimum_samples {
                first.get_or_insert(current_start);
                last = Some(window.end_sample);
            } else if first.is_some() {
                last = Some(window.end_sample);
            }
        } else {
            current_samples = 0;
        }
    }
    match (first, last) {
        (Some(start), Some(end)) if end > start => (start, end.min(sample_count)),
        _ => (0, sample_count),
    }
}

fn region_profile(
    start_ms: f64,
    end_ms: f64,
    threshold_dbfs: f64,
    energy: &[EnergyWindow],
    spectral: &[SpectralFrame],
    normalized_onsets: &[f64],
    entrance: bool,
    sample_rate: u32,
) -> RegionProfile {
    let start_sample = (start_ms * sample_rate as f64 / 1000.0).floor() as usize;
    let end_sample = (end_ms * sample_rate as f64 / 1000.0).ceil() as usize;
    let mut sum_sq = 0.0;
    let mut sample_count = 0usize;
    for window in energy {
        let overlap_start = window.start_sample.max(start_sample);
        let overlap_end = window.end_sample.min(end_sample);
        if overlap_end <= overlap_start {
            continue;
        }
        let source_count = window.end_sample.saturating_sub(window.start_sample).max(1);
        let overlap_count = overlap_end - overlap_start;
        sum_sq += window.sum_sq * overlap_count as f64 / source_count as f64;
        sample_count += overlap_count;
    }
    let average_energy_dbfs = if sample_count > 0 {
        amplitude_dbfs((sum_sq / sample_count as f64).sqrt())
    } else {
        -160.0
    };
    let mut onset_count = 0usize;
    let mut active_onsets = 0usize;
    for (index, frame) in spectral.iter().enumerate() {
        if frame.time_ms >= start_ms && frame.time_ms <= end_ms {
            onset_count += 1;
            if normalized_onsets.get(index).copied().unwrap_or_default() >= 0.35 {
                active_onsets += 1;
            }
        }
    }
    let onset_density = if onset_count == 0 {
        0.0
    } else {
        (active_onsets as f64 / onset_count as f64).clamp(0.0, 1.0)
    };
    let edge_span = (end_ms - start_ms).min(500.0).max(1.0);
    let edge_start = if entrance {
        start_ms
    } else {
        (end_ms - edge_span).max(start_ms)
    };
    let edge_end = if entrance {
        (start_ms + edge_span).min(end_ms)
    } else {
        end_ms
    };
    let edge_energy = region_energy_dbfs(edge_start, edge_end, energy, sample_rate);
    let boundary_confidence = ((edge_energy - threshold_dbfs + 6.0) / 24.0).clamp(0.0, 1.0);
    RegionProfile {
        start_ms,
        end_ms: end_ms.max(start_ms),
        average_energy_dbfs,
        onset_density,
        boundary_confidence,
    }
}

fn region_energy_dbfs(
    start_ms: f64,
    end_ms: f64,
    energy: &[EnergyWindow],
    sample_rate: u32,
) -> f64 {
    let start = (start_ms * sample_rate as f64 / 1000.0).floor() as usize;
    let end = (end_ms * sample_rate as f64 / 1000.0).ceil() as usize;
    let mut sum_sq = 0.0;
    let mut count = 0usize;
    for window in energy {
        let overlap_start = window.start_sample.max(start);
        let overlap_end = window.end_sample.min(end);
        if overlap_end <= overlap_start {
            continue;
        }
        let full_count = window.end_sample.saturating_sub(window.start_sample).max(1);
        let overlap_count = overlap_end - overlap_start;
        sum_sq += window.sum_sq * overlap_count as f64 / full_count as f64;
        count += overlap_count;
    }
    if count == 0 {
        -160.0
    } else {
        amplitude_dbfs((sum_sq / count as f64).sqrt())
    }
}

fn tempo_profile(
    frames: &[SpectralFrame],
    duration_ms: u64,
    config: &AnalysisConfig,
    audible_start_ms: f64,
    audible_end_ms: f64,
) -> (Option<TempoProfile>, Vec<f64>, Vec<f64>) {
    let full = frames
        .iter()
        .map(|frame| frame.full_flux)
        .collect::<Vec<_>>();
    let low = frames
        .iter()
        .map(|frame| frame.low_flux)
        .collect::<Vec<_>>();
    let normalized_full = normalize_onset_envelope(&full, config);
    let normalized_low = normalize_onset_envelope(&low, config);
    if audible_end_ms - audible_start_ms < config.tempo_min_content_ms
        || normalized_full.len() < config.min_beats
    {
        return (None, normalized_full, normalized_low);
    }
    let frame_rate = config.sample_rate_hz as f64 / config.fft_hop as f64;
    let minimum_lag = (frame_rate * 60.0 / config.bpm_max).floor().max(2.0) as usize;
    let maximum_lag = (frame_rate * 60.0 / config.bpm_min).ceil() as usize;
    let mut scored = Vec::new();
    for lag in minimum_lag..=maximum_lag.min(normalized_full.len().saturating_sub(2)) {
        let bpm = frame_rate * 60.0 / lag as f64;
        let center = (-0.5 * ((bpm - config.bpm_center_prior) / 55.0).powi(2)).exp();
        let score = (autocorrelation(&normalized_full, lag)
            + config.corr_lag2_weight * autocorrelation(&normalized_full, lag * 2)
            + config.corr_half_lag_weight * autocorrelation(&normalized_full, (lag / 2).max(1)))
            * (0.82 + 0.18 * center);
        scored.push((lag, score));
    }
    let Some((best_index, &(best_lag, best_score))) = scored
        .iter()
        .enumerate()
        .max_by(|(_, left), (_, right)| left.1.total_cmp(&right.1))
    else {
        return (None, normalized_full, normalized_low);
    };
    if !best_score.is_finite() || best_score <= 0.0 {
        return (None, normalized_full, normalized_low);
    }
    let refined_lag = if best_index > 0 && best_index + 1 < scored.len() {
        let left = scored[best_index - 1].1;
        let center = best_score;
        let right = scored[best_index + 1].1;
        let denominator = left - 2.0 * center + right;
        if denominator.abs() > 1e-9 {
            best_lag as f64 + (0.5 * (left - right) / denominator).clamp(-0.5, 0.5)
        } else {
            best_lag as f64
        }
    } else {
        best_lag as f64
    };
    let period = refined_lag.max(1.0);
    let phase_count = period.round().max(1.0) as usize;
    let phase = (0..phase_count)
        .max_by(|left, right| {
            phase_score(&normalized_full, *left, period).total_cmp(&phase_score(
                &normalized_full,
                *right,
                period,
            ))
        })
        .unwrap_or(0);
    let snap = (period * config.beat_snap_window).round().max(1.0) as isize;
    let minimum_spacing = period * config.beat_min_spacing;
    let mut beat_indices = Vec::new();
    let mut predicted = phase as f64;
    while predicted < normalized_full.len() as f64 {
        let center = predicted.round() as isize;
        let start = (center - snap).max(0) as usize;
        let end = (center + snap).min(normalized_full.len().saturating_sub(1) as isize) as usize;
        let local = (start..=end)
            .max_by(|left, right| normalized_full[*left].total_cmp(&normalized_full[*right]))
            .unwrap_or(start);
        if beat_indices
            .last()
            .is_none_or(|previous| local as f64 - *previous as f64 >= minimum_spacing)
        {
            beat_indices.push(local);
        }
        predicted += period;
    }
    if beat_indices.len() < config.min_beats {
        return (None, normalized_full, normalized_low);
    }
    let mut beat_times_ms = beat_indices
        .iter()
        .map(|index| frames[*index].time_ms.clamp(0.0, duration_ms as f64))
        .collect::<Vec<_>>();
    beat_times_ms.dedup_by(|left, right| (*left - *right).abs() < 0.01);
    if beat_times_ms.len() < config.min_beats {
        return (None, normalized_full, normalized_low);
    }
    let intervals = beat_times_ms
        .windows(2)
        .map(|pair| pair[1] - pair[0])
        .filter(|value| *value > 0.0)
        .collect::<Vec<_>>();
    let median_interval = median(&intervals);
    if median_interval <= 0.0 {
        return (None, normalized_full, normalized_low);
    }
    let bpm = (60_000.0 / median_interval).clamp(config.bpm_min, config.bpm_max);
    let stability = tempo_stability(&intervals, config.stability_tolerance);
    let onset_salience = beat_indices
        .iter()
        .map(|index| normalized_full[*index])
        .sum::<f64>()
        / beat_indices.len() as f64;
    let second_score = scored
        .iter()
        .enumerate()
        .filter(|(index, _)| index.abs_diff(best_index) > 1)
        .map(|(_, value)| value.1)
        .fold(0.0, f64::max);
    let dominance =
        ((best_score - second_score) / best_score.abs().max(1e-9) * 2.0).clamp(0.0, 1.0);
    let beat_confidence = (config.beat_conf_stability_weight * stability
        + config.beat_conf_onset_weight * onset_salience.clamp(0.0, 1.0)
        + config.beat_conf_corr_weight * dominance)
        .clamp(0.0, 1.0);

    let phase_scores = (0..4)
        .map(|phase| {
            beat_indices
                .iter()
                .enumerate()
                .filter(|(index, _)| index % 4 == phase)
                .map(|(_, frame_index)| {
                    config.downbeat_full_flux_weight * normalized_full[*frame_index]
                        + config.downbeat_low_flux_weight * normalized_low[*frame_index]
                })
                .sum::<f64>()
        })
        .collect::<Vec<_>>();
    let best_phase = phase_scores
        .iter()
        .enumerate()
        .max_by(|(_, left), (_, right)| left.total_cmp(right))
        .map(|(index, _)| index)
        .unwrap_or(0);
    let mean_phase = phase_scores.iter().sum::<f64>() / phase_scores.len() as f64;
    let downbeat_confidence =
        (2.0 * (phase_scores[best_phase] - mean_phase) / beat_indices.len() as f64).clamp(0.0, 1.0);
    let downbeat_offset_ms = beat_times_ms
        .get(best_phase)
        .copied()
        .unwrap_or_else(|| beat_times_ms[0]);
    (
        Some(TempoProfile {
            bpm,
            beat_times_ms,
            downbeat_offset_ms,
            beat_confidence,
            downbeat_confidence,
            stability,
        }),
        normalized_full,
        normalized_low,
    )
}

fn normalize_onset_envelope(values: &[f64], config: &AnalysisConfig) -> Vec<f64> {
    if values.is_empty() {
        return Vec::new();
    }
    let frame_rate = config.sample_rate_hz as f64 / config.fft_hop as f64;
    let radius = (config.onset_mean_window_s * frame_rate / 2.0).round() as usize;
    let mut prefix = vec![0.0; values.len() + 1];
    for (index, value) in values.iter().enumerate() {
        prefix[index + 1] = prefix[index] + value.max(0.0);
    }
    let mut normalized = Vec::with_capacity(values.len());
    for (index, value) in values.iter().enumerate() {
        let start = index.saturating_sub(radius);
        let end = (index + radius + 1).min(values.len());
        let local_mean = (prefix[end] - prefix[start]) / (end - start).max(1) as f64;
        normalized.push((value - config.onset_mean_scale * local_mean).max(0.0));
    }
    let mut sorted = normalized.clone();
    sorted.sort_by(f64::total_cmp);
    let percentile_index =
        ((sorted.len().saturating_sub(1)) as f64 * config.onset_norm_percentile).round() as usize;
    let scale = sorted[percentile_index.min(sorted.len() - 1)].max(1e-12);
    for value in &mut normalized {
        *value = (*value / scale).clamp(0.0, 1.0);
    }
    normalized
}

fn autocorrelation(values: &[f64], lag: usize) -> f64 {
    if lag == 0 || lag >= values.len() {
        return 0.0;
    }
    let mut product = 0.0;
    let mut left_energy = 0.0;
    let mut right_energy = 0.0;
    for index in 0..values.len() - lag {
        let left = values[index];
        let right = values[index + lag];
        product += left * right;
        left_energy += left * left;
        right_energy += right * right;
    }
    let denominator = (left_energy * right_energy).sqrt();
    if denominator > 1e-12 {
        product / denominator
    } else {
        0.0
    }
}

fn phase_score(values: &[f64], phase: usize, period: f64) -> f64 {
    let mut score = 0.0;
    let mut position = phase as f64;
    while position < values.len() as f64 {
        let index = position.round() as usize;
        if index >= values.len() {
            break;
        }
        score += values[index];
        position += period;
    }
    score
}

fn tempo_stability(intervals: &[f64], tolerance: f64) -> f64 {
    if intervals.is_empty() {
        return 0.0;
    }
    let center = median(intervals);
    let deviations = intervals
        .iter()
        .map(|value| (value - center).abs())
        .collect::<Vec<_>>();
    let mad_score = (1.0 - median(&deviations) / (center * tolerance).max(1e-9)).clamp(0.0, 1.0);
    let segment_size = intervals.len().div_ceil(4).max(1);
    let segment_deviation = intervals
        .chunks(segment_size)
        .map(median)
        .map(|value| (value - center).abs() / center.max(1e-9))
        .fold(0.0, f64::max);
    let segment_score = (1.0 - segment_deviation / tolerance.max(1e-9)).clamp(0.0, 1.0);
    mad_score.min(segment_score)
}

fn median(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    if sorted.len() % 2 == 0 {
        (sorted[sorted.len() / 2 - 1] + sorted[sorted.len() / 2]) / 2.0
    } else {
        sorted[sorted.len() / 2]
    }
}

fn fft_in_place(real: &mut [f64], imag: &mut [f64]) {
    let length = real.len();
    debug_assert_eq!(length, imag.len());
    debug_assert!(length.is_power_of_two());
    let mut target = 0usize;
    for index in 1..length {
        let mut bit = length >> 1;
        while target & bit != 0 {
            target ^= bit;
            bit >>= 1;
        }
        target ^= bit;
        if index < target {
            real.swap(index, target);
            imag.swap(index, target);
        }
    }
    let mut size = 2usize;
    while size <= length {
        let angle = -2.0 * std::f64::consts::PI / size as f64;
        let step_real = angle.cos();
        let step_imag = angle.sin();
        for start in (0..length).step_by(size) {
            let mut twiddle_real = 1.0;
            let mut twiddle_imag = 0.0;
            for offset in 0..size / 2 {
                let even = start + offset;
                let odd = even + size / 2;
                let odd_real = real[odd] * twiddle_real - imag[odd] * twiddle_imag;
                let odd_imag = real[odd] * twiddle_imag + imag[odd] * twiddle_real;
                real[odd] = real[even] - odd_real;
                imag[odd] = imag[even] - odd_imag;
                real[even] += odd_real;
                imag[even] += odd_imag;
                let next_real = twiddle_real * step_real - twiddle_imag * step_imag;
                twiddle_imag = twiddle_real * step_imag + twiddle_imag * step_real;
                twiddle_real = next_real;
            }
        }
        size *= 2;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fft_places_tone_in_expected_bin() {
        let mut real = (0..1024)
            .map(|index| (2.0 * std::f64::consts::PI * 32.0 * index as f64 / 1024.0).sin())
            .collect::<Vec<_>>();
        let mut imag = vec![0.0; real.len()];
        fft_in_place(&mut real, &mut imag);
        let peak = (1..512)
            .max_by(|left, right| {
                (real[*left].hypot(imag[*left])).total_cmp(&real[*right].hypot(imag[*right]))
            })
            .unwrap();
        assert_eq!(peak, 32);
    }

    #[test]
    fn audible_range_requires_sustained_windows() {
        let windows = (0..40)
            .map(|index| EnergyWindow {
                start_sample: index * 100,
                end_sample: (index + 1) * 100,
                sum_sq: 1.0,
                peak: if (2..=3).contains(&index) || (10..=30).contains(&index) {
                    0.5
                } else {
                    0.0
                },
            })
            .collect::<Vec<_>>();
        let range = audible_range_from_windows(&windows, -20.0, 140.0, 10_000, 4000);
        assert_eq!(range, (1000, 3100));
    }

    #[test]
    fn phase_score_rejects_rounded_index_at_length() {
        let values = vec![1.0; 10];
        assert_eq!(phase_score(&values, 1, 1.49), 6.0);
    }
}
