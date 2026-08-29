// 智能排序：从 TrackProfile 提炼氛围特征，生成自适应目标曲线，用确定性模拟退火求全局编排。
// 全部为纯函数；相同输入永远产生相同输出（固定随机种子）。

use rand::prelude::*;

#[cfg(test)]
mod smart_sort_tests;

/// 氛围分权重：能量、节奏、声音密度。
const VIBE_ENERGY_WEIGHT: f64 = 0.45;
const VIBE_TEMPO_WEIGHT: f64 = 0.35;
const VIBE_DENSITY_WEIGHT: f64 = 0.2;

/// 整曲 RMS dBFS 到 0..1 的线性映射区间。
pub const ENERGY_DBFS_FLOOR: f64 = -42.0;
pub const ENERGY_DBFS_CEIL: f64 = -6.0;

/// BPM 对数归一区间。
pub const TEMPO_BPM_MIN: f64 = 60.0;
pub const TEMPO_BPM_MAX: f64 = 180.0;

/// 曲线取值范围与最大摆幅（相对中心）。
pub const CURVE_MIN: f64 = 4.0;
pub const CURVE_MAX: f64 = 96.0;
pub const CURVE_FULL_AMPLITUDE: f64 = 38.0;
/// 氛围分标准差达到该值时摆幅不再收缩；低于时按比例压平。
pub const SPREAD_SATURATION_STD: f64 = 16.0;
/// 同质歌单保留的最小摆幅比例，保证曲线仍保留微弱起伏。
pub const MIN_AMPLITUDE_RATIO: f64 = 0.15;

/// 编排成本权重：曲线贴合、BPM 衔接、能量衔接。
pub const WEIGHT_CURVE: f64 = 1.5;
pub const WEIGHT_BPM: f64 = 1.0;
pub const WEIGHT_ENERGY: f64 = 0.5;

/// 顺滑度两端预设：0 叙事优先（曲线贴合主导），1 顺滑优先（相邻衔接主导）。
const SMOOTH_CURVE_WEIGHT: f64 = 2.2;
const SLICK_CURVE_WEIGHT: f64 = 0.8;
const SMOOTH_TRANSITION_SCALE: f64 = 0.6;
const SLICK_TRANSITION_SCALE: f64 = 1.6;

/// 由顺滑度插值出的编排权重：曲线贴合权重随顺滑度降低，衔接惩罚同步增强。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SortWeights {
    pub curve: f64,
    pub transition_scale: f64,
}

pub fn sort_weights_for(smoothness: f64) -> SortWeights {
    let t = clamp_unit(smoothness);
    SortWeights {
        curve: SMOOTH_CURVE_WEIGHT
            + (SLICK_CURVE_WEIGHT - SMOOTH_CURVE_WEIGHT) * t,
        transition_scale: SMOOTH_TRANSITION_SCALE
            + (SLICK_TRANSITION_SCALE - SMOOTH_TRANSITION_SCALE) * t,
    }
}

/// 收尾风格对应的曲线终点氛围占比。
pub const OUTRO_LEVEL_WARM: f64 = 0.36;
pub const OUTRO_LEVEL_FADE: f64 = 0.1;
pub const OUTRO_LEVEL_BLAZE: f64 = 0.82;

/// 收尾风格（0 温暖 / 1 渐弱 / 2 燃尽）到曲线终点占比的映射。
pub fn outro_level_for_style(style: i32) -> f64 {
    match style {
        1 => OUTRO_LEVEL_FADE,
        2 => OUTRO_LEVEL_BLAZE,
        _ => OUTRO_LEVEL_WARM,
    }
}

/// 能量衔接惩罚的 dB 跨度与满档分值。
const ENERGY_NEIGHBOR_SPAN_DB: f64 = 18.0;
const ENERGY_NEIGHBOR_SCALE: f64 = 40.0;
/// BPM 缺失时的中性衔接代价。
const BPM_UNKNOWN_PENALTY: f64 = 8.0;
/// BPM 倍频折叠候选：直接接、半速接、倍速接。
const FOLD_CANDIDATES: [f64; 3] = [1.0, 2.0, 0.5];

const SA_SEED: u64 = 0x5F375A86;
const SA_T_START: f64 = 14.0;
const SA_T_END: f64 = 0.06;
const SA_MIN_ITERATIONS: usize = 2000;
const SA_MAX_ITERATIONS: usize = 300_000;

/// 参与排序的单曲特征。vibe 用于贴合目标曲线，其余用于相邻衔接成本。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TrackVibe {
    pub vibe: f64,
    pub bpm: f64,
    pub entrance_energy_dbfs: f64,
    pub exit_energy_dbfs: f64,
}

fn clamp_unit(value: f64) -> f64 {
    value.clamp(0.0, 1.0)
}

/// 氛围分 0..100：整曲响度 + 对数 BPM + 首尾 onset 密度均值。BPM 缺失按中值处理。
pub fn compute_vibe(
    integrated_rms_dbfs: f64,
    bpm: f64,
    entrance_onset_density: f64,
    exit_onset_density: f64,
) -> f64 {
    let energy_norm = clamp_unit(
        (integrated_rms_dbfs - ENERGY_DBFS_FLOOR) / (ENERGY_DBFS_CEIL - ENERGY_DBFS_FLOOR),
    );
    let tempo_norm = if bpm > 0.0 {
        clamp_unit((bpm.ln() - TEMPO_BPM_MIN.ln()) / (TEMPO_BPM_MAX.ln() - TEMPO_BPM_MIN.ln()))
    } else {
        0.5
    };
    let density_norm = clamp_unit((entrance_onset_density + exit_onset_density) * 0.5);
    100.0
        * (VIBE_ENERGY_WEIGHT * energy_norm
            + VIBE_TEMPO_WEIGHT * tempo_norm
            + VIBE_DENSITY_WEIGHT * density_norm)
}

/// 从 TrackProfile 提取排序特征；tempo 缺失时 bpm 记 0。
pub fn vibe_from_profile(
    integrated_rms_dbfs: f64,
    bpm: Option<f64>,
    entrance_onset_density: f64,
    entrance_energy_dbfs: f64,
    exit_onset_density: f64,
    exit_energy_dbfs: f64,
) -> TrackVibe {
    TrackVibe {
        vibe: compute_vibe(
            integrated_rms_dbfs,
            bpm.unwrap_or(0.0),
            entrance_onset_density,
            exit_onset_density,
        ),
        bpm: bpm.unwrap_or(0.0),
        entrance_energy_dbfs,
        exit_energy_dbfs,
    }
}

/// 生成自适应理想曲线。
/// `climax_position` 为峰值落点（归一化位置），`contrast` 为用户摆幅系数 0..=1，
/// 摆幅再乘以歌单氛围分布的标准差比例——全同质歌单自动趋平，此时排序退化为纯衔接优化。
/// `outro_level` 为收尾目标占比（0..=1）：温暖 0.36 / 渐弱 0.10 / 燃尽 0.82。
pub fn generate_curve(
    num_positions: usize,
    climax_position: f64,
    contrast: f64,
    vibe_scores: &[f64],
    outro_level: f64,
) -> Vec<f64> {
    if num_positions == 0 {
        return Vec::new();
    }
    let mean_vibe = if vibe_scores.is_empty() {
        50.0
    } else {
        vibe_scores.iter().sum::<f64>() / vibe_scores.len() as f64
    };
    let center = mean_vibe.clamp(CURVE_MIN, CURVE_MAX);
    if num_positions == 1 {
        return vec![center];
    }
    let spread_std = population_std(vibe_scores);
    let spread_ratio = (spread_std / SPREAD_SATURATION_STD).clamp(MIN_AMPLITUDE_RATIO, 1.0);
    let mut amplitude = CURVE_FULL_AMPLITUDE * clamp_unit(contrast) * spread_ratio;
    amplitude = amplitude.min(center - CURVE_MIN).min(CURVE_MAX - center);

    // 关键帧模板：开场友好 → 抬升 → 回落 → 主升 → climax 峰值 → 按收尾风格落地。
    let climax = climax_position.clamp(0.55, 0.95);
    let outro_level = clamp_unit(outro_level);
    let mut xs: Vec<f64> = vec![0.0, 0.12, 0.26, 0.48];
    let mut ys: Vec<f64> = vec![0.2, 0.52, 0.34, 0.66];
    xs.push(climax);
    ys.push(1.0);
    let outro_start = climax + 0.07;
    if outro_start < 0.97 {
        xs.push(outro_start);
        ys.push(0.6_f64.max(outro_level));
    }
    xs.push(1.0);
    ys.push(outro_level);

    let denom = (num_positions - 1) as f64;
    (0..num_positions)
        .map(|index| {
            let x = index as f64 / denom;
            let template = interp_linear(x, &xs, &ys);
            center + amplitude * 2.0 * (template - 0.5)
        })
        .collect()
}

/// 抽取口味：对采样排序键施加的播放次数偏置。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TasteBias {
    Neutral,
    /// 偏向低播放次数（换换口味）。
    Fresh,
    /// 偏向高播放次数（常听的）。
    Familiar,
}

/// 按播放次数生成采样偏置：返回与 vibes 等长的排序调整量，加到氛围分上作为采样键。
/// 偏置幅度为氛围量纲的 5%，只影响"相近氛围里先抽谁"，不破坏分层覆盖。
pub fn taste_key_adjustment(play_counts: &[i64], taste: TasteBias) -> Vec<f64> {
    let mut adjustment = vec![0.0; play_counts.len()];
    if taste == TasteBias::Neutral || play_counts.is_empty() {
        return adjustment;
    }
    let max_count = play_counts.iter().copied().max().unwrap_or(0);
    if max_count <= 0 {
        return adjustment;
    }
    for (index, &count) in play_counts.iter().enumerate() {
        let normalized = count as f64 / max_count as f64;
        adjustment[index] = match taste {
            TasteBias::Neutral => 0.0,
            TasteBias::Fresh => -5.0 * (1.0 - normalized),
            TasteBias::Familiar => -5.0 * normalized,
        };
    }
    adjustment
}

/// 从全池按采样键分层等距采样 limit 首，保留动态范围；limit 为 0 或不小于池大小时返回全量。
/// 返回值是原始输入下标，按采样键升序排列。keys 通常为氛围分（可叠加口味偏置）。
pub fn stratified_sample_by_vibe(keys: &[f64], limit: usize) -> Vec<usize> {
    let total = keys.len();
    if limit == 0 || limit >= total {
        return (0..total).collect();
    }
    let mut by_vibe: Vec<usize> = (0..total).collect();
    by_vibe.sort_by(|&left, &right| {
        keys[left]
            .partial_cmp(&keys[right])
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    if limit == 1 {
        return vec![by_vibe[total / 2]];
    }
    let denominator = limit - 1;
    (0..limit)
        .map(|pick| by_vibe[(pick * (total - 1)) / denominator])
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
pub struct SortPlan {
    /// 排列结果：order[i] 是第 i 个位置的输入下标。
    pub order: Vec<usize>,
    /// 按编排顺序排列的实际氛围分。
    pub actual_curve: Vec<f64>,
    /// 模拟退火收敛后的总成本（供调用方记录诊断）。
    pub cost: f64,
}

/// 确定性模拟退火编排。贪心解作为初始解并全程追踪历史最优，结果永不劣于贪心。
pub fn plan_order(vibes: &[TrackVibe], curve: &[f64], weights: SortWeights) -> SortPlan {
    let n = vibes.len();
    debug_assert_eq!(curve.len(), n);
    if n == 0 {
        return SortPlan {
            order: Vec::new(),
            actual_curve: Vec::new(),
            cost: 0.0,
        };
    }
    if n == 1 {
        return SortPlan {
            order: vec![0],
            actual_curve: vec![vibes[0].vibe],
            cost: curve_cost(vibes[0].vibe, curve[0], weights),
        };
    }

    let greedy = greedy_order(vibes, curve, weights);
    if n == 2 {
        return finish_plan(&greedy, vibes, curve, weights);
    }
    let iterations =
        (n.saturating_mul(n).saturating_mul(60)).clamp(SA_MIN_ITERATIONS, SA_MAX_ITERATIONS);
    let annealed = anneal(&greedy, vibes, curve, iterations, weights);
    let best = if annealed.cost <= greedy_cost(&greedy, vibes, curve, weights) {
        annealed
    } else {
        finish_plan(&greedy, vibes, curve, weights)
    };
    best
}

fn population_std(values: &[f64]) -> f64 {
    if values.len() < 2 {
        return 0.0;
    }
    let mean = values.iter().sum::<f64>() / values.len() as f64;
    let variance = values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / values.len() as f64;
    variance.sqrt()
}

fn interp_linear(x: f64, xs: &[f64], ys: &[f64]) -> f64 {
    if x <= xs[0] {
        return ys[0];
    }
    for window in xs.windows(2).enumerate() {
        let (segment, pair) = window;
        if x <= pair[1] {
            let t = (x - pair[0]) / (pair[1] - pair[0]);
            return ys[segment] + t * (ys[segment + 1] - ys[segment]);
        }
    }
    *ys.last().expect("non-empty keyframes")
}

fn curve_cost(vibe: f64, target: f64, weights: SortWeights) -> f64 {
    weights.curve * (vibe - target).abs()
}

/// 相邻衔接代价：BPM 倍频折叠比差 + 出入口能量差，整体受顺滑度缩放。
fn transition_penalty(prev: &TrackVibe, cur: &TrackVibe, weights: SortWeights) -> f64 {
    let bpm_penalty = if prev.bpm > 0.0 && cur.bpm > 0.0 {
        let ratio = prev.bpm.max(cur.bpm) / prev.bpm.min(cur.bpm).max(1.0);
        FOLD_CANDIDATES
            .iter()
            .map(|candidate| (ratio / candidate - 1.0).abs())
            .fold(f64::INFINITY, f64::min)
            * 100.0
    } else {
        BPM_UNKNOWN_PENALTY
    };
    let energy_diff = (cur.entrance_energy_dbfs - prev.exit_energy_dbfs)
        .abs()
        .clamp(0.0, ENERGY_NEIGHBOR_SPAN_DB);
    (WEIGHT_BPM * bpm_penalty
        + WEIGHT_ENERGY * (energy_diff / ENERGY_NEIGHBOR_SPAN_DB) * ENERGY_NEIGHBOR_SCALE)
        * weights.transition_scale
}

fn total_cost(order: &[usize], vibes: &[TrackVibe], curve: &[f64], weights: SortWeights) -> f64 {
    let n = order.len();
    let mut cost = 0.0;
    for position in 0..n {
        cost += curve_cost(vibes[order[position]].vibe, curve[position], weights);
        if position > 0 {
            cost += transition_penalty(
                &vibes[order[position - 1]],
                &vibes[order[position]],
                weights,
            );
        }
    }
    cost
}

fn greedy_cost(order: &[usize], vibes: &[TrackVibe], curve: &[f64], weights: SortWeights) -> f64 {
    total_cost(order, vibes, curve, weights)
}

/// 逐位贪心：每个位置选曲线贴合 + 与前一首衔接最优的剩余曲目。
fn greedy_order(vibes: &[TrackVibe], curve: &[f64], weights: SortWeights) -> Vec<usize> {
    let n = vibes.len();
    let mut remaining: Vec<usize> = (0..n).collect();
    remaining.sort_by(|&left, &right| {
        vibes[left]
            .vibe
            .partial_cmp(&vibes[right].vibe)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let first_index = remaining
        .iter()
        .copied()
        .min_by(|&left, &right| {
            curve_cost(vibes[left].vibe, curve[0], weights)
                .partial_cmp(&curve_cost(vibes[right].vibe, curve[0], weights))
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        .expect("non-empty input");
    remaining.retain(|&candidate| candidate != first_index);
    let mut order = vec![first_index];
    for position in 1..n {
        let previous = &vibes[order[position - 1]];
        let best_index = *remaining
            .iter()
            .min_by(|&&left, &&right| {
                let left_cost = curve_cost(vibes[left].vibe, curve[position], weights)
                    + transition_penalty(previous, &vibes[left], weights);
                let right_cost = curve_cost(vibes[right].vibe, curve[position], weights)
                    + transition_penalty(previous, &vibes[right], weights);
                left_cost
                    .partial_cmp(&right_cost)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .expect("remaining is non-empty until last step");
        remaining.retain(|&candidate| candidate != best_index);
        order.push(best_index);
    }
    order
}

fn finish_plan(
    order: &[usize],
    vibes: &[TrackVibe],
    curve: &[f64],
    weights: SortWeights,
) -> SortPlan {
    SortPlan {
        actual_curve: order.iter().map(|&track| vibes[track].vibe).collect(),
        order: order.to_vec(),
        cost: total_cost(order, vibes, curve, weights),
    }
}

/// 固定种子模拟退火，swap 邻域 + 受影响位置局部增量求值。
fn anneal(
    initial: &[usize],
    vibes: &[TrackVibe],
    curve: &[f64],
    iterations: usize,
    weights: SortWeights,
) -> SortPlan {
    let n = initial.len();
    let mut rng = StdRng::seed_from_u64(SA_SEED);
    let mut current = initial.to_vec();
    let mut current_cost = total_cost(&current, vibes, curve, weights);
    let mut best = current.clone();
    let mut best_cost = current_cost;
    let temperature_ratio = (SA_T_END / SA_T_START).powf(1.0 / iterations as f64);
    let mut temperature = SA_T_START;
    for _ in 0..iterations {
        let swap_left = rng.gen_range(0..n);
        let mut swap_right = rng.gen_range(0..n);
        while swap_right == swap_left {
            swap_right = rng.gen_range(0..n);
        }
        let delta = swap_delta(&current, swap_left, swap_right, vibes, curve, weights);
        if delta <= 0.0 || rng.gen::<f64>() < (-delta / temperature).exp() {
            current.swap(swap_left, swap_right);
            current_cost += delta;
            if current_cost < best_cost {
                best_cost = current_cost;
                best.copy_from_slice(&current);
            }
        }
        temperature *= temperature_ratio;
    }
    let best_cost = total_cost(&best, vibes, curve, weights);
    SortPlan {
        actual_curve: best.iter().map(|&track| vibes[track].vibe).collect(),
        order: best,
        cost: best_cost,
    }
}

/// 交换两个位置的局部成本增量；只重算受影响窗口，复杂度 O(1)。
fn swap_delta(
    order: &[usize],
    left: usize,
    right: usize,
    vibes: &[TrackVibe],
    curve: &[f64],
    weights: SortWeights,
) -> f64 {
    let n = order.len();
    let mut affected = Vec::with_capacity(6);
    for base in [left, right] {
        if base > 0 {
            affected.push(base - 1);
        }
        affected.push(base);
        if base + 1 < n {
            affected.push(base + 1);
        }
    }
    affected.sort_unstable();
    affected.dedup();
    let before: f64 = affected
        .iter()
        .map(|&position| local_cost(order, position, vibes, curve, weights))
        .sum();
    let after: f64 = affected
        .iter()
        .map(|&position| local_cost_after_swap(order, position, left, right, vibes, curve, weights))
        .sum();
    after - before
}

fn swapped_track(order: &[usize], position: usize, left: usize, right: usize) -> usize {
    if position == left {
        order[right]
    } else if position == right {
        order[left]
    } else {
        order[position]
    }
}

fn local_cost_after_swap(
    order: &[usize],
    position: usize,
    left: usize,
    right: usize,
    vibes: &[TrackVibe],
    curve: &[f64],
    weights: SortWeights,
) -> f64 {
    let track = swapped_track(order, position, left, right);
    let mut cost = curve_cost(vibes[track].vibe, curve[position], weights);
    if position > 0 {
        let previous = swapped_track(order, position - 1, left, right);
        cost += transition_penalty(&vibes[previous], &vibes[track], weights);
    }
    cost
}

fn local_cost(
    order: &[usize],
    position: usize,
    vibes: &[TrackVibe],
    curve: &[f64],
    weights: SortWeights,
) -> f64 {
    let track = order[position];
    let mut cost = curve_cost(vibes[track].vibe, curve[position], weights);
    if position > 0 {
        cost += transition_penalty(&vibes[order[position - 1]], &vibes[track], weights);
    }
    cost
}
