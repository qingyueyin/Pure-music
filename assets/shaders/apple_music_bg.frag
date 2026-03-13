#version 460
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform float uIntensity;

uniform vec3 uDominant;
uniform vec3 uSecondary;
uniform vec3 uTertiary;

out vec4 fragColor;

// 简化版的噪声函数
float hash(vec2 p) {
    p = fract(p * vec2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

// 分形布朗运动
float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    mat2 m = mat2(1.6, 1.2, -1.2, 1.6);
    for (int i = 0; i < 5; i++) {
        v += a * noise(p);
        p = m * p;
        a *= 0.5;
    }
    return v;
}

// 平滑插值
float smoothStep(float edge0, float edge1, float x) {
    float t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 uv = fragCoord / max(uSize, vec2(1.0));
    
    // 计算纵横比
    float aspect = uSize.x / max(uSize.y, 1.0);
    vec2 p = (uv - 0.5) * vec2(aspect, 1.0);
    
    // 时间相关的流动效果
    float t = uTime * 0.15;
    
    // 使用 FBM 创建流动的渐变效果
    vec2 flow1 = vec2(fbm(p * 2.0 + t), fbm(p * 2.0 - t));
    vec2 flow2 = vec2(fbm(p * 3.0 + t * 0.8), fbm(p * 3.0 - t * 0.8));
    
    // 混合多种噪声模式
    float n1 = fbm(p * 2.5 + flow1 * 0.5);
    float n2 = fbm(p * 1.8 + flow2 * 0.4);
    float n3 = fbm(p * 4.0 - flow1 * 0.3);
    
    // 创建平滑的颜色过渡
    float mix1 = smoothStep(0.3, 0.7, n1);
    float mix2 = smoothStep(0.4, 0.8, n2);
    float mix3 = smoothStep(0.2, 0.6, n3);
    
    // 混合三种主色
    vec3 col = mix(uDominant, uSecondary, mix1);
    col = mix(col, uTertiary, mix2 * 0.7);
    col = mix(col, uDominant, mix3 * 0.5);
    
    // 添加额外的颜色层次
    float colorLayer = smoothStep(0.2, 0.9, fbm(p * 1.5 + t * 0.5));
    col = mix(col, uSecondary, colorLayer * 0.4);
    
    // 应用强度
    col *= (0.7 + 0.3 * uIntensity);
    
    // 边缘柔化（vignette 效果）
    float vignette = smoothStep(1.2, 0.3, length(p));
    col *= vignette;
    
    // 最终调色
    fragColor = vec4(col, 1.0);
}
