use serde::{Deserialize, Serialize};

use crate::smart_sort::{
    generate_curve, outro_level_for_style, plan_order, sort_weights_for, stratified_sample_by_vibe,
    taste_key_adjustment, vibe_from_profile, TasteBias, TrackVibe,
};

/// 排序输入的单曲紧凑特征；由 Dart 侧从 TrackProfile 提取并持久化缓存。
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SortFeatureInput {
    integrated_rms_dbfs: f64,
    bpm: f64,
    entrance_onset_density: f64,
    entrance_energy_dbfs: f64,
    exit_onset_density: f64,
    exit_energy_dbfs: f64,
}

impl SortFeatureInput {
    fn to_vibe(&self) -> TrackVibe {
        vibe_from_profile(
            self.integrated_rms_dbfs,
            (self.bpm > 0.0).then_some(self.bpm),
            self.entrance_onset_density,
            self.entrance_energy_dbfs,
            self.exit_onset_density,
            self.exit_energy_dbfs,
        )
    }
}

/// 输入信封：特征数组与对齐的播放次数数组（供抽取口味偏置）。
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SortInputEnvelope {
    features: Vec<SortFeatureInput>,
    #[serde(default)]
    play_counts: Vec<i64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SmartSortOutputJson {
    order: Vec<usize>,
    ideal_curve: Vec<f64>,
    actual_curve: Vec<f64>,
}

/// 输入为 SortInputEnvelope JSON；take_count 大于 0 时先按采样键分层抽样该数量再编排，
/// 输出的 order 始终指向原始输入下标。
pub fn plan_smart_sort_json(
    payload_json: String,
    climax_position: f64,
    contrast: f64,
    take_count: usize,
    smoothness: f64,
    outro_style: i32,
    taste: i32,
) -> Result<String, String> {
    let envelope: SortInputEnvelope =
        serde_json::from_str(&payload_json).map_err(|error| error.to_string())?;
    let vibes: Vec<TrackVibe> = envelope
        .features
        .iter()
        .map(SortFeatureInput::to_vibe)
        .collect();
    let vibe_scores: Vec<f64> = vibes.iter().map(|vibe| vibe.vibe).collect();

    // 抽取口味：把播放次数偏置叠加到氛围分上作为采样键。
    let taste_bias = match taste {
        1 => TasteBias::Fresh,
        2 => TasteBias::Familiar,
        _ => TasteBias::Neutral,
    };
    let adjustment = if envelope.play_counts.len() == vibes.len() {
        taste_key_adjustment(&envelope.play_counts, taste_bias)
    } else {
        vec![0.0; vibes.len()]
    };
    let sample_keys: Vec<f64> = vibe_scores
        .iter()
        .zip(adjustment.iter())
        .map(|(vibe, adjustment)| vibe + adjustment)
        .collect();

    let sampled = stratified_sample_by_vibe(&sample_keys, take_count);
    let subset: Vec<TrackVibe> = sampled.iter().map(|&index| vibes[index]).collect();
    let subset_scores: Vec<f64> = subset.iter().map(|vibe| vibe.vibe).collect();
    let ideal_curve = generate_curve(
        subset.len(),
        climax_position,
        contrast,
        &subset_scores,
        outro_level_for_style(outro_style),
    );
    let plan = plan_order(&subset, &ideal_curve, sort_weights_for(smoothness));
    let output = SmartSortOutputJson {
        order: plan
            .order
            .iter()
            .map(|&position| sampled[position])
            .collect(),
        ideal_curve,
        actual_curve: plan.actual_curve,
    };
    serde_json::to_string(&output).map_err(|error| error.to_string())
}
