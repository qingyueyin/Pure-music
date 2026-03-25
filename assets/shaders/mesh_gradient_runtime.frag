#version 460
#include <flutter/runtime_effect.glsl>

// Uniform packing matches Dart setFloat calls in mesh_gradient_background.dart:
// 0-1: uSize.x, uSize.y
// 2:   uTime
// 3:   uIntensity
// 4:   uLowFreqVolume
// 5-7: uDominantColor.rgb
// 8:   uAspect
uniform vec2 uSize;
uniform float uTime;
uniform float uIntensity;
uniform float uLowFreqVolume;
uniform vec3 uDominantColor;
uniform float uAspect;

out vec4 fragColor;

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

vec3 colorRamp(vec3 base, vec3 target, float t) {
  return mix(base, target, clamp(t, 0.0, 1.0));
}

void main() {
  vec2 fragCoord = FlutterFragCoord().xy;
  vec2 uv = fragCoord / uSize;

  float energy = clamp(uLowFreqVolume, 0.0, 1.0);
  energy = pow(energy, 0.85);

  // Centered coordinates, aspect-corrected for consistent radial falloff.
  vec2 p = uv - 0.5;
  p.x *= max(0.001, uAspect);

  float t = uTime * (0.035 + energy * 0.03);

  // Base colors derived from dominant color.
  vec3 c1 = colorRamp(uDominantColor, vec3(1.0, 0.22, 0.55), 0.33);
  vec3 c2 = colorRamp(uDominantColor, vec3(0.18, 0.62, 1.0), 0.34);
  vec3 c3 = colorRamp(uDominantColor, vec3(0.95, 0.92, 0.25), 0.26);
  vec3 c4 = colorRamp(uDominantColor, vec3(0.12, 0.92, 0.62), 0.30);

  // Moving control points; low frequency energy increases motion and deformation.
  vec2 p1 = vec2(sin(t * 0.9), cos(t * 1.1)) * (0.35 + energy * 0.10);
  vec2 p2 = vec2(cos(t * 1.2 + 2.1), sin(t * 0.8 + 1.7)) * (0.42 + energy * 0.12);
  vec2 p3 = vec2(sin(t * 0.7 + 4.2), cos(t * 1.3 + 3.4)) * (0.38 + energy * 0.10);
  vec2 p4 = vec2(cos(t * 1.0 + 5.2), sin(t * 1.1 + 0.7)) * (0.46 + energy * 0.14);

  // Audio-driven warping.
  float warp = (noise(p * 2.2 + t * 0.7) - 0.5) * (0.28 + energy * 0.35);
  vec2 pw = p + vec2(warp, -warp) * (0.7 + uIntensity * 0.5);

  float k = 7.5 + uIntensity * 6.0;

  float w1 = exp(-k * dot(pw - p1, pw - p1));
  float w2 = exp(-k * dot(pw - p2, pw - p2));
  float w3 = exp(-k * dot(pw - p3, pw - p3));
  float w4 = exp(-k * dot(pw - p4, pw - p4));

  float wSum = w1 + w2 + w3 + w4;
  vec3 col = (c1 * w1 + c2 * w2 + c3 * w3 + c4 * w4) / max(0.0001, wSum);

  // Gentle breathing brightness tied to energy.
  float pulse = 0.82 + 0.18 * sin(t * 1.7 + energy * 2.5);
  float brightness = pulse + energy * 0.22 * uIntensity;
  col *= brightness;

  // Vignette.
  float dist = length(p);
  float vignette = smoothstep(1.2, 0.35, dist);
  col = mix(vec3(0.02), col, vignette);

  // Slight desaturation for a softer look.
  float luma = dot(col, vec3(0.299, 0.587, 0.114));
  col = mix(vec3(luma), col, 0.90);

  fragColor = vec4(col, 1.0);
}
