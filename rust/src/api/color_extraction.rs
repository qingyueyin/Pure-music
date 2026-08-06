use image::{DynamicImage, GenericImageView};
use kmeans_colors::{get_kmeans, CentroidData, Sort};
use palette::{IntoColor, Lab, Srgb};

use super::logger::log_to_dart;

const SAMPLE_EXTENT: u32 = 150;
const MIN_CLUSTER_PERCENTAGE: f32 = 0.005;
const MIN_DIVERSITY_PERCENTAGE: f32 = 0.02;
const MIN_VISUAL_PERCENTAGE: f32 = 0.012;
const MIN_RELATED_PERCENTAGE: f32 = 0.025;
const MIN_RELATED_CLUSTER_PERCENTAGE: f32 = 0.0075;
const RELATED_COLOR_DISTANCE: f32 = 38.0;

pub fn extract_colors_from_image(image_bytes: Vec<u8>, num_colors: i32) -> Vec<u32> {
    let num_colors = num_colors.clamp(2, 8) as usize;
    match _extract_colors_from_image(image_bytes, num_colors) {
        Ok(colors) => colors,
        Err(err) => {
            log_to_dart(format!("fail to extract colors: {}", err));
            vec![]
        }
    }
}

fn _extract_colors_from_image(
    image_bytes: Vec<u8>,
    num_colors: usize,
) -> Result<Vec<u32>, Box<dyn std::error::Error>> {
    let img = image::load_from_memory(&image_bytes)?;
    drop(image_bytes);
    extract_colors_from_decoded_image(&img, num_colors)
}

pub(super) fn extract_mesh_colors_from_decoded_image(
    image: &DynamicImage,
    num_colors: i32,
) -> Result<Vec<u32>, Box<dyn std::error::Error>> {
    let num_colors = num_colors.clamp(2, 8) as usize;
    extract_colors_from_decoded_image(image, num_colors)
}

fn extract_colors_from_decoded_image(
    image: &DynamicImage,
    num_colors: usize,
) -> Result<Vec<u32>, Box<dyn std::error::Error>> {
    let (width, height) = image.dimensions();
    let resize_dim = if width.max(height) > SAMPLE_EXTENT {
        let scale = SAMPLE_EXTENT as f32 / width.max(height) as f32;
        (
            (width as f32 * scale) as u32,
            (height as f32 * scale) as u32,
        )
    } else {
        (width, height)
    };

    let resized = image.resize(
        resize_dim.0,
        resize_dim.1,
        image::imageops::FilterType::Triangle,
    );
    let rgba = resized.to_rgba8();
    drop(resized);

    let edge_margin = (resize_dim.0.min(resize_dim.1) / 8).max(1);
    let mut pixels = Vec::with_capacity((resize_dim.0 * resize_dim.1) as usize);
    let mut visual_weights = Vec::with_capacity((resize_dim.0 * resize_dim.1) as usize);
    for (x, y, p) in rgba.enumerate_pixels() {
        if p[3] <= 128 {
            continue;
        }
        let rgb = [p[0], p[1], p[2]];
        pixels.push(rgb);
        visual_weights.push(visual_sample_weight(x, y, resize_dim.0, resize_dim.1));
        if x < edge_margin
            || y < edge_margin
            || x + edge_margin >= resize_dim.0
            || y + edge_margin >= resize_dim.1
        {
            pixels.push(rgb);
            visual_weights.push(0.0);
        }
    }
    drop(rgba);

    if pixels.is_empty() {
        return Ok(vec![]);
    }

    let lab_pixels = pixels
        .iter()
        .map(|[r, g, b]| {
            Srgb::new(*r as f32 / 255.0, *g as f32 / 255.0, *b as f32 / 255.0)
                .into_linear()
                .into_color()
        })
        .collect::<Vec<Lab>>();
    drop(pixels);

    let candidate_count = (num_colors * 2).clamp(num_colors, 8);
    let result = get_kmeans(candidate_count, 10, 5.0, false, &lab_pixels, 0);
    drop(lab_pixels);

    let total_visual_weight = visual_weights.iter().sum::<f32>();
    let mut visual_percentages = vec![0.0; result.centroids.len()];
    for (index, weight) in result.indices.iter().zip(visual_weights) {
        visual_percentages[*index as usize] += weight;
    }
    if total_visual_weight > 0.0 {
        for percentage in &mut visual_percentages {
            *percentage /= total_visual_weight;
        }
    }

    let mut candidates = Lab::sort_indexed_colors(&result.centroids, &result.indices);
    candidates.retain(|entry| entry.percentage >= MIN_CLUSTER_PERCENTAGE);
    candidates.sort_unstable_by(|left, right| right.percentage.total_cmp(&left.percentage));
    let candidate_visual_percentages = candidates
        .iter()
        .map(|entry| visual_percentages[entry.index as usize])
        .collect::<Vec<_>>();
    Ok(
        select_palette_candidates(&candidates, &candidate_visual_percentages, num_colors)
            .iter()
            .map(|entry| {
                let rgb: Srgb = entry.centroid.into_color();
                let rgb_u8: Srgb<u8> = rgb.into_format();
                soften_color_for_background(rgb_u8.red, rgb_u8.green, rgb_u8.blue)
            })
            .collect(),
    )
}

fn visual_sample_weight(x: u32, y: u32, width: u32, height: u32) -> f32 {
    let normalized_x = ((x as f32 + 0.5) / width.max(1) as f32 - 0.5).abs() * 2.0;
    let normalized_y = ((y as f32 + 0.5) / height.max(1) as f32 - 0.5).abs() * 2.0;
    0.6 + 0.8 * (1.0 - normalized_x.max(normalized_y)).clamp(0.0, 1.0)
}

fn select_palette_candidates(
    candidates: &[CentroidData<Lab>],
    visual_percentages: &[f32],
    target_count: usize,
) -> Vec<CentroidData<Lab>> {
    if candidates.len() <= target_count {
        return pair_palette_candidates(candidates.to_vec());
    }

    let mut selected_indices = Vec::with_capacity(target_count);
    for index in 0..target_count.min(2).min(candidates.len()) {
        selected_indices.push(index);
    }

    while selected_indices.len() < target_count {
        let next = candidates
            .iter()
            .enumerate()
            .filter(|(index, entry)| {
                !selected_indices.contains(index)
                    && is_meaningful_candidate(candidates, visual_percentages, *index, entry)
            })
            .map(|(index, entry)| {
                let nearest_distance = selected_indices
                    .iter()
                    .map(|selected| {
                        lab_distance_squared(&entry.centroid, &candidates[*selected].centroid)
                    })
                    .fold(f32::INFINITY, f32::min)
                    .sqrt();
                let visual_percentage = visual_percentages
                    .get(index)
                    .copied()
                    .unwrap_or(entry.percentage);
                let effective_percentage = entry.percentage.max(visual_percentage);
                let chroma = entry.centroid.a.hypot(entry.centroid.b);
                let chroma_weight = 1.0 + (chroma / 80.0).min(0.45);
                let score = nearest_distance * effective_percentage.sqrt() * chroma_weight;
                (index, score)
            })
            .max_by(|left, right| left.1.total_cmp(&right.1))
            .map(|(index, _)| index);
        let Some(next) = next else {
            break;
        };
        selected_indices.push(next);
    }

    for (index, candidate) in candidates.iter().enumerate() {
        if selected_indices.len() >= target_count {
            break;
        }
        if !selected_indices.contains(&index)
            && candidate.percentage >= MIN_CLUSTER_PERCENTAGE * 2.0
        {
            selected_indices.push(index);
        }
    }

    pair_palette_candidates(
        selected_indices
            .into_iter()
            .map(|index| candidates[index].clone())
            .collect(),
    )
}

fn is_meaningful_candidate(
    candidates: &[CentroidData<Lab>],
    visual_percentages: &[f32],
    index: usize,
    candidate: &CentroidData<Lab>,
) -> bool {
    if candidate.percentage >= MIN_DIVERSITY_PERCENTAGE
        || visual_percentages.get(index).copied().unwrap_or_default() >= MIN_VISUAL_PERCENTAGE
    {
        return true;
    }
    if candidate.percentage < MIN_RELATED_CLUSTER_PERCENTAGE {
        return false;
    }
    candidates
        .iter()
        .filter(|entry| {
            lab_distance_squared(&candidate.centroid, &entry.centroid).sqrt()
                <= RELATED_COLOR_DISTANCE
        })
        .map(|entry| entry.percentage)
        .sum::<f32>()
        >= MIN_RELATED_PERCENTAGE
}

fn pair_palette_candidates(candidates: Vec<CentroidData<Lab>>) -> Vec<CentroidData<Lab>> {
    if candidates.len() != 4 {
        return candidates;
    }

    let pairings = [[0, 1, 2, 3], [0, 2, 1, 3], [0, 3, 1, 2]];
    let pairing = pairings
        .into_iter()
        .min_by(|left, right| {
            let score = |pairing: &[usize; 4]| {
                lab_distance_squared(
                    &candidates[pairing[0]].centroid,
                    &candidates[pairing[1]].centroid,
                ) + lab_distance_squared(
                    &candidates[pairing[2]].centroid,
                    &candidates[pairing[3]].centroid,
                )
            };
            score(left).total_cmp(&score(right))
        })
        .unwrap();
    let (third, fourth) = if candidates[pairing[2]].percentage >= candidates[pairing[3]].percentage
    {
        (pairing[2], pairing[3])
    } else {
        (pairing[3], pairing[2])
    };
    vec![
        candidates[pairing[0]].clone(),
        candidates[pairing[1]].clone(),
        candidates[third].clone(),
        candidates[fourth].clone(),
    ]
}

fn lab_distance_squared(left: &Lab, right: &Lab) -> f32 {
    (left.l - right.l).powi(2) + (left.a - right.a).powi(2) + (left.b - right.b).powi(2)
}

fn soften_color_for_background(r: u8, g: u8, b: u8) -> u32 {
    let (hue, saturation, lightness) =
        rgb_to_hsl(r as f32 / 255.0, g as f32 / 255.0, b as f32 / 255.0);
    let channel_spread = r.max(g).max(b) - r.min(g).min(b);
    let saturation = if channel_spread <= 8 {
        0.0
    } else {
        (saturation * 1.08)
            .min(0.78)
            .min(channel_spread as f32 / 255.0 * 3.0)
    };
    let lightness = lightness.clamp(0.10, 0.70);
    let (mut red, mut green, mut blue) = hsl_to_rgb(hue, saturation, lightness);
    red = contrast(red, 1.03);
    green = contrast(green, 1.03);
    blue = contrast(blue, 1.03);
    pack_argb(
        (red * 255.0).round().clamp(0.0, 255.0) as u8,
        (green * 255.0).round().clamp(0.0, 255.0) as u8,
        (blue * 255.0).round().clamp(0.0, 255.0) as u8,
    )
}

fn contrast(channel: f32, factor: f32) -> f32 {
    ((channel - 0.5) * factor + 0.5).clamp(0.0, 1.0)
}

fn pack_argb(r: u8, g: u8, b: u8) -> u32 {
    (0xFF << 24) | ((r as u32) << 16) | ((g as u32) << 8) | b as u32
}

fn rgb_to_hsl(r: f32, g: f32, b: f32) -> (f32, f32, f32) {
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let lightness = (max + min) / 2.0;
    if max == min {
        return (0.0, 0.0, lightness);
    }
    let difference = max - min;
    let saturation = if lightness > 0.5 {
        difference / (2.0 - max - min)
    } else {
        difference / (max + min)
    };
    let hue = if max == r {
        (g - b) / difference + if g < b { 6.0 } else { 0.0 }
    } else if max == g {
        (b - r) / difference + 2.0
    } else {
        (r - g) / difference + 4.0
    };
    (hue / 6.0, saturation, lightness)
}

fn hsl_to_rgb(hue: f32, saturation: f32, lightness: f32) -> (f32, f32, f32) {
    if saturation == 0.0 {
        return (lightness, lightness, lightness);
    }
    let q = if lightness < 0.5 {
        lightness * (1.0 + saturation)
    } else {
        lightness + saturation - lightness * saturation
    };
    let p = 2.0 * lightness - q;
    (
        hue_to_rgb(p, q, hue + 1.0 / 3.0),
        hue_to_rgb(p, q, hue),
        hue_to_rgb(p, q, hue - 1.0 / 3.0),
    )
}

fn hue_to_rgb(p: f32, q: f32, mut value: f32) -> f32 {
    if value < 0.0 {
        value += 1.0;
    }
    if value > 1.0 {
        value -= 1.0;
    }
    if value < 1.0 / 6.0 {
        return p + (q - p) * 6.0 * value;
    }
    if value < 0.5 {
        return q;
    }
    if value < 2.0 / 3.0 {
        return p + (q - p) * (2.0 / 3.0 - value) * 6.0;
    }
    p
}

#[cfg(test)]
mod tests {
    use image::{DynamicImage, ImageFormat, Rgb, RgbImage};
    use kmeans_colors::CentroidData;
    use palette::Lab;
    use std::io::Cursor;

    fn channels(color: u32) -> (i32, i32, i32) {
        (
            ((color >> 16) & 0xff) as i32,
            ((color >> 8) & 0xff) as i32,
            (color & 0xff) as i32,
        )
    }

    fn assert_neutral_palette(colors: Vec<u32>) {
        assert_eq!(colors.len(), 4);
        for color in colors {
            let red = ((color >> 16) & 0xff) as i32;
            let green = ((color >> 8) & 0xff) as i32;
            let blue = (color & 0xff) as i32;
            let spread = red.max(green).max(blue) - red.min(green).min(blue);
            assert!(
                spread <= 24,
                "expected neutral color, got #{color:08X} with channel spread {spread}"
            );
        }
    }

    fn candidate(index: u8, percentage: f32, l: f32, a: f32, b: f32) -> CentroidData<Lab> {
        CentroidData {
            centroid: Lab::new(l, a, b),
            percentage,
            index,
        }
    }

    #[test]
    fn palette_selection_balances_area_and_difference() {
        let candidates = vec![
            candidate(0, 0.62, 92.0, 0.0, 1.0),
            candidate(1, 0.23, 78.0, 0.0, 0.0),
            candidate(2, 0.015, 55.0, 82.0, -78.0),
            candidate(3, 0.075, 68.0, -12.0, -20.0),
            candidate(4, 0.06, 25.0, 3.0, 2.0),
        ];

        let visual_percentages = [0.62, 0.23, 0.006, 0.075, 0.06];
        let selected = super::select_palette_candidates(&candidates, &visual_percentages, 4);
        let indices = selected.iter().map(|entry| entry.index).collect::<Vec<_>>();
        assert!(indices.contains(&0));
        assert!(indices.contains(&1));
        assert!(indices.contains(&3));
        assert!(indices.contains(&4));
        assert!(!indices.contains(&2));
    }

    #[test]
    fn palette_pairs_related_colors_for_shader_layers() {
        let candidates = vec![
            candidate(0, 0.45, 50.0, 0.0, 0.0),
            candidate(1, 0.25, 55.0, 60.0, 0.0),
            candidate(2, 0.18, 52.0, 55.0, 1.0),
            candidate(3, 0.12, 48.0, 5.0, 0.0),
        ];

        let paired = super::pair_palette_candidates(candidates);
        assert_eq!(
            paired.iter().map(|entry| entry.index).collect::<Vec<_>>(),
            vec![0, 3, 1, 2]
        );
    }

    #[test]
    fn related_small_accents_share_enough_area_to_enter_the_palette() {
        let candidates = vec![
            candidate(0, 0.82, 4.0, 0.0, 0.0),
            candidate(1, 0.08, 68.0, 0.0, -14.0),
            candidate(2, 0.04, 22.0, 1.0, 0.0),
            candidate(3, 0.011, 84.0, 1.0, 55.0),
            candidate(4, 0.009, 66.0, 14.0, 39.0),
            candidate(5, 0.008, 43.0, 15.0, 27.0),
        ];
        let visual_percentages = [0.82, 0.08, 0.04, 0.007, 0.006, 0.006];

        let selected = super::select_palette_candidates(&candidates, &visual_percentages, 4);
        let indices = selected.iter().map(|entry| entry.index).collect::<Vec<_>>();
        assert!(indices.contains(&0));
        assert!(indices.contains(&1));
        assert!(indices.iter().any(|index| (3..=5).contains(index)));
    }

    #[test]
    fn center_weight_does_not_promote_a_corner_speck() {
        assert!(super::visual_sample_weight(50, 50, 100, 100) > 1.35);
        assert!(super::visual_sample_weight(0, 0, 100, 100) < 0.62);
    }

    #[test]
    fn black_cover_keeps_a_related_family_of_small_gold_accents() {
        let mut image = RgbImage::from_pixel(120, 100, Rgb([9, 12, 13]));
        for (x, y, pixel) in image.enumerate_pixels_mut() {
            *pixel = if (35..86).contains(&x) && (12..91).contains(&y) {
                if x >= 80 {
                    match y % 3 {
                        0 => Rgb([239, 213, 110]),
                        1 => Rgb([204, 150, 90]),
                        _ => Rgb([131, 89, 57]),
                    }
                } else if x < 61 {
                    Rgb([143, 158, 185])
                } else {
                    Rgb([24, 22, 24])
                }
            } else {
                *pixel
            };
        }

        let colors =
            super::extract_mesh_colors_from_decoded_image(&DynamicImage::ImageRgb8(image), 4)
                .unwrap();
        assert!(colors.iter().any(|color| {
            let (red, green, blue) = channels(*color);
            red > blue + 70 && green > blue + 35
        }));
    }

    #[test]
    fn white_cover_keeps_pale_cyan_and_pink_subject_colors() {
        let mut image = RgbImage::from_pixel(120, 100, Rgb([246, 245, 242]));
        for (x, y, pixel) in image.enumerate_pixels_mut() {
            *pixel = if (18..57).contains(&x) && (16..88).contains(&y) {
                Rgb([190, 226, 230])
            } else if (63..103).contains(&x) && (22..82).contains(&y) {
                Rgb([232, 182, 207])
            } else {
                *pixel
            };
        }

        let colors =
            super::extract_mesh_colors_from_decoded_image(&DynamicImage::ImageRgb8(image), 4)
                .unwrap();
        assert!(colors.iter().any(|color| {
            let (red, green, blue) = channels(*color);
            green > red + 15 && blue > red + 20
        }));
        assert!(colors.iter().any(|color| {
            let (red, green, blue) = channels(*color);
            red > green + 25 && blue > green + 10
        }));
    }

    #[test]
    fn gray_cover_keeps_a_small_warm_subject() {
        let mut image = RgbImage::new(120, 100);
        for (x, y, pixel) in image.enumerate_pixels_mut() {
            let gray = 150 + ((x + y) % 24) as u8;
            *pixel = if (34..88).contains(&x) && (42..94).contains(&y) {
                match (x + y) % 3 {
                    0 => Rgb([138, 45, 35]),
                    1 => Rgb([181, 92, 52]),
                    _ => Rgb([86, 36, 31]),
                }
            } else {
                Rgb([gray, gray - 3, gray - 5])
            };
        }

        let colors =
            super::extract_mesh_colors_from_decoded_image(&DynamicImage::ImageRgb8(image), 4)
                .unwrap();
        assert!(colors.iter().any(|color| {
            let (red, green, blue) = channels(*color);
            red > green + 40 && red > blue + 50
        }));
    }

    #[test]
    fn blue_cover_keeps_bright_cloud_depth() {
        let mut image = RgbImage::new(120, 100);
        for (x, y, pixel) in image.enumerate_pixels_mut() {
            *pixel = if y > 80 && ((x / 12 + y / 8) % 3 != 0) {
                Rgb([239, 247, 250])
            } else {
                let blue = 188 + ((x + y) % 48) as u8;
                Rgb([12, blue.saturating_sub(92), blue])
            };
        }

        let colors =
            super::extract_mesh_colors_from_decoded_image(&DynamicImage::ImageRgb8(image), 4)
                .unwrap();
        let luminance = |color: u32| {
            let (red, green, blue) = channels(color);
            red + green + blue
        };
        let darkest = colors.iter().map(|color| luminance(*color)).min().unwrap();
        let brightest = colors.iter().map(|color| luminance(*color)).max().unwrap();
        assert!(brightest - darkest > 180, "palette: {colors:?}");
    }

    #[test]
    fn pale_cover_tints_are_not_flattened_to_gray() {
        let mut image = RgbImage::from_pixel(120, 100, Rgb([246, 246, 243]));
        for (x, y, pixel) in image.enumerate_pixels_mut() {
            if x >= 72 && y >= 12 {
                *pixel = Rgb([216, 231, 242]);
            }
        }

        let colors =
            super::extract_mesh_colors_from_decoded_image(&DynamicImage::ImageRgb8(image), 4)
                .unwrap();
        assert!(colors.iter().any(|color| {
            let (red, green, blue) = channels(*color);
            blue >= red + 15 && blue >= green + 7
        }));
    }

    #[test]
    fn small_cover_accent_does_not_displace_dominant_tones() {
        let mut image = RgbImage::new(100, 100);
        let grays = [40, 96, 160, 224];
        for (x, y, pixel) in image.enumerate_pixels_mut() {
            let gray = grays[(x / 25) as usize];
            *pixel = if x >= 90 && y >= 90 {
                Rgb([229, 241, 119])
            } else {
                Rgb([gray, gray, gray])
            };
        }
        let mut bytes = Cursor::new(Vec::new());
        DynamicImage::ImageRgb8(image)
            .write_to(&mut bytes, ImageFormat::Png)
            .unwrap();

        assert_neutral_palette(super::extract_colors_from_image(bytes.into_inner(), 4));
    }

    #[test]
    fn tiny_color_noise_does_not_enter_dominant_monochrome_palette() {
        let mut image = RgbImage::new(100, 100);
        let grays = [40, 96, 160, 224];
        for (x, y, pixel) in image.enumerate_pixels_mut() {
            let gray = grays[(x / 25) as usize];
            *pixel = if x >= 98 && y >= 98 {
                Rgb([229, 241, 119])
            } else {
                Rgb([gray, gray, gray])
            };
        }
        let mut bytes = Cursor::new(Vec::new());
        DynamicImage::ImageRgb8(image)
            .write_to(&mut bytes, ImageFormat::Png)
            .unwrap();

        let colors = super::extract_colors_from_image(bytes.into_inner(), 4);
        assert_neutral_palette(colors);
    }

    #[test]
    fn representative_cover_regions_survive_dominant_background_shades() {
        let mut image = RgbImage::new(120, 100);
        for (x, y, pixel) in image.enumerate_pixels_mut() {
            let green_shade = 34 + ((x + y) % 46) as u8;
            *pixel = if x >= 84 {
                Rgb([205, 137, 105])
            } else if (45..75).contains(&x) && (18..38).contains(&y) {
                Rgb([226, 225, 211])
            } else if (45..75).contains(&x) && (44..60).contains(&y) {
                Rgb([226, 48, 142])
            } else {
                Rgb([green_shade / 2, green_shade, green_shade * 2 / 3])
            };
        }
        let mut bytes = Cursor::new(Vec::new());
        DynamicImage::ImageRgb8(image)
            .write_to(&mut bytes, ImageFormat::Png)
            .unwrap();

        let colors = super::extract_colors_from_image(bytes.into_inner(), 4);
        let channels = colors
            .iter()
            .map(|color| {
                (
                    ((color >> 16) & 0xff) as i32,
                    ((color >> 8) & 0xff) as i32,
                    (color & 0xff) as i32,
                )
            })
            .collect::<Vec<_>>();

        assert!(
            channels
                .iter()
                .any(|(r, g, b)| *g >= *r + 18 && *g > *b + 8),
            "palette: {channels:?}"
        );
        assert!(
            channels
                .iter()
                .any(|(r, g, b)| *r > *b + 45 && *g > *b + 15),
            "palette: {channels:?}"
        );
    }

    #[test]
    fn small_meaningful_regions_survive_a_dominant_cool_background() {
        let mut image = RgbImage::new(100, 100);
        for (x, y, pixel) in image.enumerate_pixels_mut() {
            let index = y * 100 + x;
            *pixel = if index < 220 {
                Rgb([34, 30, 27])
            } else if index < 440 {
                Rgb([246, 180, 166])
            } else if index < 630 {
                Rgb([210, 141, 107])
            } else if index < 770 {
                Rgb([233, 218, 202])
            } else {
                match x / 34 {
                    0 => Rgb([134, 157, 169]),
                    1 => Rgb([145, 173, 183]),
                    _ => Rgb([112, 140, 154]),
                }
            };
        }
        let mut bytes = Cursor::new(Vec::new());
        DynamicImage::ImageRgb8(image)
            .write_to(&mut bytes, ImageFormat::Png)
            .unwrap();

        let colors = super::extract_colors_from_image(bytes.into_inner(), 4);
        let channels = colors
            .iter()
            .map(|color| {
                (
                    ((color >> 16) & 0xff) as i32,
                    ((color >> 8) & 0xff) as i32,
                    (color & 0xff) as i32,
                )
            })
            .collect::<Vec<_>>();

        assert!(channels.iter().any(|(r, g, b)| *b > *r + 12 && *b > *g));
        assert!(channels
            .iter()
            .any(|(r, g, b)| *r < 60 && *g < 60 && *b < 60));
        assert!(channels
            .iter()
            .any(|(r, g, b)| *r > *b + 35 && *g > *b + 12));
    }

    #[test]
    fn mesh_palette_keeps_independent_cover_colors() {
        let mut image = RgbImage::new(120, 100);
        let background_shades = [
            Rgb([112, 159, 184]),
            Rgb([128, 177, 201]),
            Rgb([145, 190, 211]),
        ];
        for (x, y, pixel) in image.enumerate_pixels_mut() {
            *pixel = if (38..82).contains(&x) && (18..88).contains(&y) {
                if y < 68 {
                    Rgb([221, 139, 116])
                } else {
                    Rgb([38, 31, 30])
                }
            } else {
                background_shades[((x / 18 + y / 20) % 3) as usize]
            };
        }

        let colors =
            super::extract_mesh_colors_from_decoded_image(&DynamicImage::ImageRgb8(image), 4)
                .unwrap();
        assert_eq!(colors.len(), 4);
        let mut colors = colors.iter().map(|color| channels(*color));
        assert!(colors
            .clone()
            .any(|(red, green, blue)| blue > red + 35 && blue > green + 12));
        assert!(colors
            .clone()
            .any(|(red, green, blue)| red > blue + 55 && red > green + 45));
        assert!(colors.any(|(red, green, blue)| red < 70 && green < 70 && blue < 70));
    }

    #[test]
    fn mesh_palette_keeps_near_white_covers_neutral() {
        let mut image = RgbImage::from_pixel(120, 100, Rgb([248, 248, 246]));
        for x in 18..102 {
            let amplitude = ((x % 13) + 2) as i32;
            for offset in -amplitude..=amplitude {
                let y = (50 + offset).clamp(0, 99) as u32;
                image.put_pixel(x, y, Rgb([205, 207, 206]));
            }
        }

        let colors =
            super::extract_mesh_colors_from_decoded_image(&DynamicImage::ImageRgb8(image), 4)
                .unwrap();
        assert!((2..=4).contains(&colors.len()));
        for color in colors {
            let (red, green, blue) = channels(color);
            let spread = red.max(green).max(blue) - red.min(green).min(blue);
            assert!(spread <= 8, "#{color:08X}");
        }
    }
}
