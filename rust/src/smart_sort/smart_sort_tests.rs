// 智能排序纯函数的确定性、排列有效性与自适应行为验证。

use super::*;

fn vibe(vibe_score: f64, bpm: f64) -> TrackVibe {
    TrackVibe {
        vibe: vibe_score,
        bpm,
        entrance_energy_dbfs: -20.0,
        exit_energy_dbfs: -20.0,
    }
}

#[test]
fn vibe_scores_monotonic_with_loudness() {
    let quiet = compute_vibe(-30.0, 120.0, 0.5, 0.5);
    let loud = compute_vibe(-10.0, 120.0, 0.5, 0.5);
    assert!(loud > quiet);
    // BPM 缺失按中值处理，能量触底时不为零。
    assert!(compute_vibe(ENERGY_DBFS_FLOOR, 0.0, 0.0, 0.0) > 0.0);
    assert!((compute_vibe(ENERGY_DBFS_CEIL, TEMPO_BPM_MAX, 1.0, 1.0) - 100.0).abs() < 1e-9);
}

#[test]
fn curve_is_flat_for_homogeneous_playlist() {
    let vibes = vec![62.0; 40];
    let curve = generate_curve(40, 0.82, 1.0, &vibes, OUTRO_LEVEL_WARM);
    // 同质歌单仅保留最小摆幅的微弱起伏。
    let tolerance = CURVE_FULL_AMPLITUDE * MIN_AMPLITUDE_RATIO + 1e-9;
    for value in curve {
        assert!(
            (value - 62.0).abs() <= tolerance,
            "expected near-flat curve around mean, got {value}"
        );
    }
}

#[test]
fn curve_center_follows_extreme_playlist_vibes() {
    for score in [10.0, 90.0] {
        let curve = generate_curve(40, 0.82, 1.0, &[score; 40], OUTRO_LEVEL_WARM);
        let tolerance = CURVE_FULL_AMPLITUDE * MIN_AMPLITUDE_RATIO + 1e-9;
        for value in curve {
            assert!(
                (value - score).abs() <= tolerance,
                "expected curve around {score}, got {value}"
            );
        }
    }
}

#[test]
fn climax_position_moves_peak_forward() {
    let vibes: Vec<f64> = (0..50).map(|index| 30.0 + index as f64 * 0.4).collect();
    let early_curve = generate_curve(50, 0.6, 1.0, &vibes, OUTRO_LEVEL_WARM);
    let late_curve = generate_curve(50, 0.9, 1.0, &vibes, OUTRO_LEVEL_WARM);
    let early_peak = early_curve
        .iter()
        .enumerate()
        .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
        .unwrap()
        .0;
    let late_peak = late_curve
        .iter()
        .enumerate()
        .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
        .unwrap()
        .0;
    assert!(late_peak > early_peak);
    let early_ratio = early_peak as f64 / 49.0;
    let late_ratio = late_peak as f64 / 49.0;
    assert!(early_ratio < 0.75 && late_ratio > 0.8);
}

#[test]
fn outro_style_changes_tail_level() {
    let vibes = vec![60.0; 60];
    let fade = generate_curve(60, 0.82, 1.0, &vibes, OUTRO_LEVEL_FADE);
    let blaze = generate_curve(60, 0.82, 1.0, &vibes, OUTRO_LEVEL_BLAZE);
    // 燃尽收尾的终点应高于渐弱收尾。
    assert!(blaze[blaze.len() - 1] > blaze[blaze.len() / 2] - 40.0);
    assert!(
        blaze.last().unwrap() > fade.last().unwrap(),
        "blaze outro should end higher than fade outro"
    );
}

#[test]
fn plan_order_returns_valid_permutation_deterministically() {
    let vibes: Vec<TrackVibe> = (0..60)
        .map(|index| vibe((index * 37 % 97) as f64, 80.0 + (index % 7) as f64 * 12.0))
        .collect();
    let scores = vibes.iter().map(|v| v.vibe).collect::<Vec<_>>();
    let weights = sort_weights_for(0.5);
    let curve = generate_curve(60, 0.82, 1.0, &scores, OUTRO_LEVEL_WARM);
    let first = plan_order(&vibes, &curve, weights);
    let second = plan_order(&vibes, &curve, weights);

    assert_eq!(first.order, second.order);
    let mut seen = vec![false; 60];
    for &track in &first.order {
        assert!(!seen[track], "track {track} appears twice");
        seen[track] = true;
    }
    assert!(seen.iter().all(|&present| present));
}

#[test]
fn annealing_never_worse_than_greedy() {
    // 构造曲线与衔接目标冲突的场景，放大优化空间。
    let mut vibes: Vec<TrackVibe> = Vec::new();
    for _block in 0..15 {
        for offset in 0..4 {
            vibes.push(vibe(
                if offset == 0 {
                    90.0
                } else {
                    20.0 + offset as f64 * 8.0
                },
                match offset {
                    0 => 170.0,
                    1 => 88.0,
                    2 => 92.0,
                    _ => 64.0,
                },
            ));
        }
    }
    let scores = vibes.iter().map(|v| v.vibe).collect::<Vec<_>>();
    let curve = generate_curve(vibes.len(), 0.85, 1.0, &scores, OUTRO_LEVEL_WARM);
    let weights = sort_weights_for(0.5);
    let greedy = greedy_order(&vibes, &curve, weights);
    let plan = plan_order(&vibes, &curve, weights);
    assert!(plan.cost <= greedy_cost(&greedy, &vibes, &curve, weights) + 1e-9);
}

#[test]
fn smoothness_shifts_weight_balance() {
    let narrative = sort_weights_for(0.0);
    let slick = sort_weights_for(1.0);
    assert!(narrative.curve > slick.curve);
    assert!(narrative.transition_scale < slick.transition_scale);
    // 中点应落在两端之间。
    let middle = sort_weights_for(0.5);
    assert!(middle.curve > slick.curve && middle.curve < narrative.curve);
}

#[test]
fn swap_delta_matches_total_cost_difference() {
    let vibes = vec![
        vibe(18.0, 82.0),
        vibe(74.0, 120.0),
        vibe(42.0, 96.0),
        vibe(89.0, 170.0),
        vibe(31.0, 64.0),
    ];
    let curve = vec![20.0, 45.0, 70.0, 82.0, 36.0];
    let weights = sort_weights_for(0.5);
    let order = vec![2, 4, 0, 3, 1];
    for left in 0..order.len() {
        for right in (left + 1)..order.len() {
            let mut swapped = order.clone();
            swapped.swap(left, right);
            let expected = total_cost(&swapped, &vibes, &curve, weights)
                - total_cost(&order, &vibes, &curve, weights);
            let actual = swap_delta(&order, left, right, &vibes, &curve, weights);
            assert!(
                (actual - expected).abs() < 1e-9,
                "swap {left},{right}: {actual} != {expected}"
            );
        }
    }
}

#[test]
fn transition_penalty_prefers_folded_half_time() {
    let source = vibe(50.0, 120.0);
    let half_time = vibe(50.0, 60.0);
    let off_tempo = vibe(50.0, 90.0);
    let weights = sort_weights_for(0.5);
    assert!(
        transition_penalty(&source, &half_time, weights)
            < transition_penalty(&source, &off_tempo, weights)
    );
}

#[test]
fn empty_and_single_inputs_are_identity() {
    let empty_plan = plan_order(&[], &[], sort_weights_for(0.5));
    assert!(empty_plan.order.is_empty());
    let single = plan_order(&[vibe(55.0, 120.0)], &[55.0], sort_weights_for(0.5));
    assert_eq!(single.order, vec![0]);
}

#[test]
fn stratified_sampling_preserves_range_and_limits() {
    let keys: Vec<f64> = (0..100).map(|index| index as f64).collect();
    // 全量请求返回原序全量。
    assert_eq!(stratified_sample_by_vibe(&keys, 0).len(), 100);
    assert_eq!(
        stratified_sample_by_vibe(&keys, 100),
        (0..100).collect::<Vec<_>>()
    );
    let picks = stratified_sample_by_vibe(&keys, 10);
    assert_eq!(picks.len(), 10);
    // 升序键的分层采样应覆盖最低与最高，且严格递增。
    assert_eq!(picks.first(), Some(&0));
    assert_eq!(picks.last(), Some(&99));
    for pair in picks.windows(2) {
        assert!(pair[0] < pair[1]);
        assert!(keys[pair[0]] < keys[pair[1]]);
    }
    // 单首抽取取中位。
    assert_eq!(stratified_sample_by_vibe(&keys, 1), vec![50]);
}

#[test]
fn taste_bias_shifts_sampling_toward_preference() {
    // 氛围完全相同的池子，采样键由播放次数偏置决定。
    let vibes = vec![60.0; 30];
    let play_counts: Vec<i64> = (0..30).map(|index| index as i64).collect();

    let fresh_adjustment = taste_key_adjustment(&play_counts, TasteBias::Fresh);
    let fresh_keys: Vec<f64> = vibes
        .iter()
        .zip(fresh_adjustment.iter())
        .map(|(vibe, adjustment)| vibe + adjustment)
        .collect();
    let familiar_adjustment = taste_key_adjustment(&play_counts, TasteBias::Familiar);
    let familiar_keys: Vec<f64> = vibes
        .iter()
        .zip(familiar_adjustment.iter())
        .map(|(vibe, adjustment)| vibe + adjustment)
        .collect();

    let fresh_picks = stratified_sample_by_vibe(&fresh_keys, 3);
    let familiar_picks = stratified_sample_by_vibe(&familiar_keys, 3);

    // 换口味偏向低播放次数，常听偏向高播放次数。
    assert!(fresh_picks.contains(&(play_counts.len() - 1)));
    assert!(familiar_picks.contains(&0));
    assert_ne!(fresh_picks, familiar_picks);
}
