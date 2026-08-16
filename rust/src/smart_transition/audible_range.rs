use std::collections::VecDeque;

#[derive(Debug, Clone, PartialEq)]
pub enum AnalysisMathError {
    NonFinite(String),
    OutOfRange(String),
}

impl std::fmt::Display for AnalysisMathError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AnalysisMathError::NonFinite(field) => write!(f, "{field} must be finite"),
            AnalysisMathError::OutOfRange(message) => write!(f, "{message}"),
        }
    }
}

pub fn audible_threshold_dbfs(integrated_rms_dbfs: f64) -> Result<f64, AnalysisMathError> {
    if !integrated_rms_dbfs.is_finite() {
        return Err(AnalysisMathError::NonFinite(
            "integrated_rms_dbfs".to_string(),
        ));
    }
    Ok((-60.0f64).max(integrated_rms_dbfs - 36.0))
}

pub struct AudibleRangeDetector {
    threshold_amp: f64,
    peak_window_samples: usize,
    min_audible_samples: usize,
    peak_deque: VecDeque<(usize, f64)>,
    stream_samples: usize,
    real_samples: usize,
    current_run_start: Option<usize>,
    current_run_len: usize,
    first_start: Option<usize>,
    last_end: Option<usize>,
}

impl AudibleRangeDetector {
    pub fn new(
        sample_rate: u32,
        integrated_rms_dbfs: f64,
        audible_min_ms: f64,
    ) -> Result<Self, AnalysisMathError> {
        if sample_rate == 0 {
            return Err(AnalysisMathError::OutOfRange(
                "sample_rate must be greater than zero".to_string(),
            ));
        }
        if !audible_min_ms.is_finite() {
            return Err(AnalysisMathError::NonFinite("audible_min_ms".to_string()));
        }
        if audible_min_ms <= 0.0 {
            return Err(AnalysisMathError::OutOfRange(
                "audible_min_ms must be greater than zero".to_string(),
            ));
        }
        let threshold_db = audible_threshold_dbfs(integrated_rms_dbfs)?;
        let min_audible_samples = ((sample_rate as f64) * audible_min_ms / 1000.0).round() as usize;
        if min_audible_samples == 0 {
            return Err(AnalysisMathError::OutOfRange(
                "audible_min_ms rounds to zero samples".to_string(),
            ));
        }
        Ok(Self {
            threshold_amp: 10f64.powf(threshold_db / 20.0),
            peak_window_samples: ((sample_rate as f64 * 0.010).round() as usize).max(1),
            min_audible_samples,
            peak_deque: VecDeque::new(),
            stream_samples: 0,
            real_samples: 0,
            current_run_start: None,
            current_run_len: 0,
            first_start: None,
            last_end: None,
        })
    }

    pub fn push(&mut self, samples: &[f32]) -> Result<(), AnalysisMathError> {
        if samples.iter().any(|sample| !sample.is_finite()) {
            return Err(AnalysisMathError::NonFinite("samples".to_string()));
        }
        for &sample in samples {
            self.real_samples += 1;
            self.push_amplitude((sample as f64).abs());
        }
        Ok(())
    }

    pub fn buffered_samples(&self) -> usize {
        self.peak_deque.len()
    }

    pub fn finish(mut self) -> Option<(usize, usize)> {
        if self.real_samples == 0 {
            return None;
        }
        for _ in 1..self.peak_window_samples {
            self.push_amplitude(0.0);
        }
        self.finish_run(self.real_samples);
        self.first_start.zip(self.last_end)
    }

    fn push_amplitude(&mut self, amplitude: f64) {
        let index = self.stream_samples;
        self.stream_samples += 1;
        while self
            .peak_deque
            .back()
            .is_some_and(|(_, value)| *value <= amplitude)
        {
            self.peak_deque.pop_back();
        }
        self.peak_deque.push_back((index, amplitude));
        if index + 1 < self.peak_window_samples {
            return;
        }
        let window_start = index + 1 - self.peak_window_samples;
        while self
            .peak_deque
            .front()
            .is_some_and(|(sample_index, _)| *sample_index < window_start)
        {
            self.peak_deque.pop_front();
        }
        let audible = self
            .peak_deque
            .front()
            .is_some_and(|(_, value)| *value >= self.threshold_amp);
        self.record_window(window_start, audible);
    }

    fn record_window(&mut self, index: usize, audible: bool) {
        if audible {
            self.current_run_start.get_or_insert(index);
            self.current_run_len += 1;
        } else {
            self.finish_run(index);
        }
    }

    fn finish_run(&mut self, end: usize) {
        if self.current_run_len >= self.min_audible_samples {
            if self.first_start.is_none() {
                self.first_start = self.current_run_start;
            }
            self.last_end = Some(end);
        }
        self.current_run_start = None;
        self.current_run_len = 0;
    }
}

pub fn find_audible_range(
    samples: &[f32],
    sample_rate: u32,
    integrated_rms_dbfs: f64,
    audible_min_ms: f64,
) -> Result<Option<(usize, usize)>, AnalysisMathError> {
    let mut detector = AudibleRangeDetector::new(sample_rate, integrated_rms_dbfs, audible_min_ms)?;
    detector.push(samples)?;
    Ok(detector.finish())
}

pub fn normalize_onset(
    onset: &[f64],
    frames_per_second: f64,
    mean_window_s: f64,
    scale: f64,
    percentile: f64,
) -> Result<Vec<f64>, AnalysisMathError> {
    for (field, value) in [
        ("frames_per_second", frames_per_second),
        ("mean_window_s", mean_window_s),
        ("scale", scale),
        ("percentile", percentile),
    ] {
        if !value.is_finite() {
            return Err(AnalysisMathError::NonFinite(field.to_string()));
        }
    }
    if frames_per_second <= 0.0 || mean_window_s <= 0.0 {
        return Err(AnalysisMathError::OutOfRange(
            "frame rate and mean window must be greater than zero".to_string(),
        ));
    }
    if scale < 0.0 {
        return Err(AnalysisMathError::OutOfRange(
            "scale must not be negative".to_string(),
        ));
    }
    if !(0.0 < percentile && percentile <= 1.0) {
        return Err(AnalysisMathError::OutOfRange(
            "percentile must be in (0, 1]".to_string(),
        ));
    }
    if onset.iter().any(|value| !value.is_finite()) {
        return Err(AnalysisMathError::NonFinite("onset".to_string()));
    }
    if onset.iter().any(|value| *value < 0.0) {
        return Err(AnalysisMathError::OutOfRange(
            "onset values must not be negative".to_string(),
        ));
    }
    if onset.is_empty() {
        return Ok(Vec::new());
    }
    let radius = ((frames_per_second * mean_window_s) / 2.0).round() as usize;
    let mut prefix = vec![0.0f64; onset.len() + 1];
    for (index, &value) in onset.iter().enumerate() {
        prefix[index + 1] = prefix[index] + value;
    }
    let subtracted: Vec<f64> = onset
        .iter()
        .enumerate()
        .map(|(index, &value)| {
            let low = index.saturating_sub(radius);
            let high = (index + radius + 1).min(onset.len());
            let local_mean = (prefix[high] - prefix[low]) / (high - low) as f64;
            (value - scale * local_mean).max(0.0)
        })
        .collect();
    let mut sorted = subtracted.clone();
    sorted.sort_by(f64::total_cmp);
    let percentile_index = ((percentile * sorted.len() as f64).ceil() as usize)
        .saturating_sub(1)
        .min(sorted.len() - 1);
    let divisor = sorted[percentile_index];
    if divisor <= 0.0 {
        return Ok(vec![0.0; onset.len()]);
    }
    Ok(subtracted
        .into_iter()
        .map(|value| value / divisor)
        .collect())
}
