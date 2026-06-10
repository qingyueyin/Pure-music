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
    let resize_dim = if width.max(height) > 200 {
        let scale = 200.0 / width.max(height) as f32;
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

    let mut pixels: Vec<[u8; 3]> = rgba
        .pixels()
        .filter(|p| p[3] > 128)
        .map(|p| [p[0], p[1], p[2]])
        .collect();
    // 释放 RGBA 缓冲
    drop(rgba);

    if pixels.is_empty() {
        return Ok(vec![]);
    }

    apply_apple_music_pipeline(&mut pixels);

    // 转换为 Lab 色彩空间用于 k-means
    let lab_pixels: Vec<Lab> = pixels
        .iter()
        .map(|[r, g, b]| {
            let srgb = Srgb::new(*r as f32 / 255.0, *g as f32 / 255.0, *b as f32 / 255.0);
            let linear = srgb.into_linear();
            linear.into_color()
        })
        .collect();
    // 释放 RGB 像素（Lab 已构建完成）
    drop(pixels);

    // 缩减 k-means 迭代：封面取色不需要 20 轮的高精度
    let max_iter = 10;
    let converge = 8.0; // 放宽收敛条件
    let runs = 2;       // 减少重复运行次数
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
    // 释放 Lab 像素，k-means 已收敛
    drop(lab_pixels);

    let sorted = Lab::sort_indexed_colors(&result.centroids, &result.indices);

    let colors: Vec<u32> = sorted
        .iter()
        .take(num_colors)
        .map(|cd| {
            let rgb: Srgb = cd.centroid.into_color();
            let rgb_u8: Srgb<u8> = rgb.into_format();
            let r = rgb_u8.red as u32;
            let g = rgb_u8.green as u32;
            let b = rgb_u8.blue as u32;
            (0xFF << 24) | (r << 16) | (g << 8) | b
        })
        .collect();

    Ok(colors)
}

fn apply_apple_music_pipeline(pixels: &mut [[u8; 3]]) {
    for pixel in pixels.iter_mut() {
        let mut r = pixel[0] as f32 / 255.0;
        let mut g = pixel[1] as f32 / 255.0;
        let mut b = pixel[2] as f32 / 255.0;

        // Contrast 0.4 (reduce contrast)
        r = contrast(r, 0.4);
        g = contrast(g, 0.4);
        b = contrast(b, 0.4);

        // Saturate 3.0 (boost saturation)
        let (h, s, l) = rgb_to_hsl(r, g, b);
        let new_s = (s * 3.0).min(1.0);
        (r, g, b) = hsl_to_rgb(h, new_s, l);

        // Contrast 1.7 (increase contrast)
        r = contrast(r, 1.7);
        g = contrast(g, 1.7);
        b = contrast(b, 1.7);

        // Brightness 0.75 (dim)
        r = (r * 0.75).min(1.0);
        g = (g * 0.75).min(1.0);
        b = (b * 0.75).min(1.0);

        // Convert back to u8
        pixel[0] = (r * 255.0).round().clamp(0.0, 255.0) as u8;
        pixel[1] = (g * 255.0).round().clamp(0.0, 255.0) as u8;
        pixel[2] = (b * 255.0).round().clamp(0.0, 255.0) as u8;
    }
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
    let s = if l > 0.5 { d / (2.0 - max - min) } else { d / (max + min) };

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
        if t < 0.0 { t += 1.0; }
        if t > 1.0 { t -= 1.0; }
        if t < 1.0 / 6.0 { return p + (q - p) * 6.0 * t; }
        if t < 1.0 / 2.0 { return q; }
        if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6.0; }
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
