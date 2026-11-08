#version 460 core

precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform vec2 u_direction;
uniform float u_inv2s2;
uniform float u_chromaBoost;
uniform sampler2D u_texture_input;

out vec4 fragColor;

vec3 toLinear(vec3 srgb) {
  return pow(max(srgb, vec3(0.0)), vec3(2.2));
}

vec3 toSrgb(vec3 linearRgb) {
  return pow(max(linearRgb, vec3(0.0)), vec3(1.0 / 2.2));
}

vec3 sampleLinear(vec2 uv, out float alpha) {
  vec4 srgb = texture(u_texture_input, clamp(uv, 0.0, 1.0));
  alpha = srgb.a;
  if (alpha <= 0.0) return vec3(0.0);
  return toLinear(srgb.rgb / alpha) * alpha;
}

void main() {
  vec2 size = max(u_size, vec2(1.0));
  vec2 uv = FlutterFragCoord().xy / size;
  vec2 texel = u_direction / size;

  float alpha;
  vec3 color = sampleLinear(uv, alpha);
  float weightSum = 1.0;
  float alphaSum = alpha;

  // 相邻整数 tap 合成一次双线性采样；16 组覆盖 1–32 px，约 3σ。
  for (int i = 0; i < 16; ++i) {
    float left = float(i) * 2.0 + 1.0;
    float right = left + 1.0;
    float wLeft = exp(-left * left * u_inv2s2);
    float wRight = exp(-right * right * u_inv2s2);
    float weight = wLeft + wRight;
    float offset = (left * wLeft + right * wRight) / max(weight, 0.000001);
    vec2 delta = texel * offset;
    color += sampleLinear(uv + delta, alpha) * weight;
    alphaSum += alpha * weight;
    color += sampleLinear(uv - delta, alpha) * weight;
    alphaSum += alpha * weight;
    weightSum += weight * 2.0;
  }

  float outAlpha = alphaSum / max(weightSum, 0.000001);
  vec3 linearRgb = color / max(alphaSum, 0.000001);
  float luma = dot(linearRgb, vec3(0.2126, 0.7152, 0.0722));
  linearRgb = mix(vec3(luma), linearRgb, max(u_chromaBoost, 1.0));
  fragColor = vec4(toSrgb(linearRgb) * outAlpha, outAlpha);
}
