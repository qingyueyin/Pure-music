#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform float uBrightness;
uniform float uIntensity;

uniform vec3 uPrimary;
uniform vec3 uSecondary;
uniform vec3 uTertiary;

uniform float uS0;
uniform float uS1;
uniform float uS2;
uniform float uS3;
uniform float uS4;
uniform float uS5;
uniform float uS6;
uniform float uS7;

out vec4 fragColor;

float _hash(vec2 p) {
  p = fract(p * vec2(123.34, 345.45));
  p += dot(p, p + 34.345);
  return fract(p.x * p.y);
}

float _noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  float a = _hash(i);
  float b = _hash(i + vec2(1.0, 0.0));
  float c = _hash(i + vec2(0.0, 1.0));
  float d = _hash(i + vec2(1.0, 1.0));
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

float _fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  mat2 m = mat2(1.6, 1.2, -1.2, 1.6);
  for (int i = 0; i < 5; i++) {
    v += a * _noise(p);
    p = m * p;
    a *= 0.5;
  }
  return v;
}

void main() {
  vec2 fragCoord = FlutterFragCoord().xy;
  vec2 uv = fragCoord / max(uSize, vec2(1.0));
  float aspect = uSize.x / max(uSize.y, 1.0);
  vec2 p = (uv - 0.5) * vec2(aspect, 1.0);

  float sLow = 0.55 * uS0 + 0.35 * uS1 + 0.10 * uS2;
  float sMid = 0.20 * uS2 + 0.40 * uS3 + 0.40 * uS4;
  float sHi = 0.10 * uS4 + 0.30 * uS5 + 0.60 * uS6;
  float s = clamp(0.55 * sLow + 0.30 * sMid + 0.15 * sHi, 0.0, 1.0);

  float t = uTime * (0.12 + 0.30 * s);
  vec2 flow = vec2(_fbm(p * 1.7 + vec2(t, -t)), _fbm(p * 1.7 + vec2(-t, t)));
  vec2 q = p * 2.2 + 0.8 * (flow - 0.5);

  float n1 = _fbm(q + vec2(0.9 * t, -0.6 * t));
  float n2 = _fbm(q * 1.6 - vec2(0.7 * t, 0.8 * t));
  float m = smoothstep(0.25, 0.85, n1);
  float k = smoothstep(0.15, 0.95, n2);

  vec3 col = mix(uPrimary, uSecondary, m);
  col = mix(col, uTertiary, k * (0.55 + 0.45 * s));

  float vignette = smoothstep(1.1, 0.2, length(p));
  float lift = mix(0.14, 0.22, uBrightness);
  col = col * vignette + lift;

  float gain = (0.50 + 0.65 * uIntensity) * (0.72 + 0.55 * s);
  col *= gain;

  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
