use image::GenericImageView;
use kmeans_colors::{get_kmeans, Kmeans, Sort};
use palette::{IntoColor, Lab, Srgb};

use super::logger::log_to_dart;

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
    // 解码图片 → 立即缩放以减小内存占用
    let img = image::load_from_memory(&image_bytes)?;
    // 显式 drop image_bytes（已 move 进此函数，离开作用域即释放）

    let (width, height) = img.dimensions();
    let resize_dim = if width.max(height) > 150 {
        let scale = 150.0 / width.max(height) as f32;
        (
            (width as f32 * scale) as u32,
            (height as f32 * scale) as u32,
        )
    } else {
        (width, height)
    };

    let resized = img.resize(
        resize_dim.0,
        resize_dim.1,
        image::imageops::FilterType::Triangle,
    );
    // 释放原始大图
    drop(img);

    let rgba = resized.to_rgba8();
    // 释放缩放后的图
    drop(resized);

    let edge_margin = (resize_dim.0.min(resize_dim.1) / 8).max(1);
    let mut pixels: Vec<[u8; 3]> = Vec::with_capacity((resize_dim.0 * resize_dim.1) as usize);
    for (x, y, p) in rgba.enumerate_pixels() {
        if p[3] <= 128 {
            continue;
        }
        let rgb = [p[0], p[1], p[2]];
        pixels.push(rgb);
        // 边缘像素只做微弱的加权，避免 JPEG 噪点/色散被过度放大
        let near_edge = x < edge_margin
            || y < edge_margin
            || x + edge_margin >= resize_dim.0
            || y + edge_margin >= resize_dim.1;
        if near_edge {
            pixels.push(rgb);
        }
    }
    // 释放 RGBA 缓冲
    drop(rgba);

    if pixels.is_empty() {
        return Ok(vec![]);
    }

    // k-means 用原始像素，不在聚类前做任何色彩扭曲
    let lab_pixels: Vec<Lab> = pixels
        .iter()
        .map(|[r, g, b]| {
            let srgb = Srgb::new(*r as f32 / 255.0, *g as f32 / 255.0, *b as f32 / 255.0);
            let linear = srgb.into_linear();
            linear.into_color()
        })
        .collect();
    drop(pixels);

    let max_iter = 12;
    let converge = 5.0;
    let runs = 2;
    let seed = 0;

    let mut result = Kmeans::new();
    for i in 0..runs {
        let run_result = get_kmeans(
            num_colors,
            max_iter,
            converge,
            false,
            &lab_pixels,
            seed + i as u64,
        );
        if run_result.score < result.score {
            result = run_result;
        }
    }
    drop(lab_pixels);

    let sorted = Lab::sort_indexed_colors(&result.centroids, &result.indices);

    // 只在最终输出色上做柔化，适配背景使用
    let colors: Vec<u32> = sorted
        .iter()
        .take(num_colors)
        .map(|cd| {
            let rgb: Srgb = cd.centroid.into_color();
            let rgb_u8: Srgb<u8> = rgb.into_format();
            soften_color_for_background(rgb_u8.red, rgb_u8.green, rgb_u8.blue)
        })
        .collect();

    Ok(colors)
}

/// 对 k-means 输出的单个颜色做柔化，使其更适合做背景色。
/// 与旧的 per-pixel pipeline 不同：只作用在最终 4 个中心色上，
/// k-means 本身运行在原始像素上，不会因色彩扭曲产生虚假的色团。
fn soften_color_for_background(r: u8, g: u8, b: u8) -> u32 {
    let rf = r as f32 / 255.0;
    let gf = g as f32 / 255.0;
    let bf = b as f32 / 255.0;

    let (h, s, l) = rgb_to_hsl(rf, gf, bf);
    // 极轻微提饱和，只避免灰蒙蒙
    let saturation = (s * 1.08).min(0.78);
    // 防止过亮或过暗的背景色块
    let lightness = l.clamp(0.10, 0.70);

    let (mut rr, mut gg, mut bb) = hsl_to_rgb(h, saturation, lightness);
    // 极轻微对比度
    rr = contrast(rr, 1.03);
    gg = contrast(gg, 1.03);
    bb = contrast(bb, 1.03);

    let out_r = (rr * 255.0).round().clamp(0.0, 255.0) as u32;
    let out_g = (gg * 255.0).round().clamp(0.0, 255.0) as u32;
    let out_b = (bb * 255.0).round().clamp(0.0, 255.0) as u32;
    (0xFF << 24) | (out_r << 16) | (out_g << 8) | out_b
}

fn contrast(c: f32, factor: f32) -> f32 {
    ((c - 0.5) * factor + 0.5).clamp(0.0, 1.0)
}

fn rgb_to_hsl(r: f32, g: f32, b: f32) -> (f32, f32, f32) {
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let l = (max + min) / 2.0;

    if max == min {
        return (0.0, 0.0, l);
    }

    let d = max - min;
    let s = if l > 0.5 {
        d / (2.0 - max - min)
    } else {
        d / (max + min)
    };

    let h = if max == r {
        (g - b) / d + (if g < b { 6.0 } else { 0.0 })
    } else if max == g {
        (b - r) / d + 2.0
    } else {
        (r - g) / d + 4.0
    };

    (h / 6.0, s, l)
}

fn hsl_to_rgb(h: f32, s: f32, l: f32) -> (f32, f32, f32) {
    let hue2rgb = |p: f32, q: f32, mut t: f32| {
        if t < 0.0 {
            t += 1.0;
        }
        if t > 1.0 {
            t -= 1.0;
        }
        if t < 1.0 / 6.0 {
            return p + (q - p) * 6.0 * t;
        }
        if t < 1.0 / 2.0 {
            return q;
        }
        if t < 2.0 / 3.0 {
            return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
        }
        p
    };

    let q = if l < 0.5 {
        l * (1.0 + s)
    } else {
        l + s - l * s
    };
    let p = 2.0 * l - q;

    (
        hue2rgb(p, q, h + 1.0 / 3.0),
        hue2rgb(p, q, h),
        hue2rgb(p, q, h - 1.0 / 3.0),
    )
}
