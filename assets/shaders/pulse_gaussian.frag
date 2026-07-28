#version 460 core

precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform vec2 u_direction;
uniform float u_inv2s2;
uniform sampler2D u_texture_input;

out vec4 fragColor;

void main() {
  vec2 size = max(u_size, vec2(1.0));
  vec2 uv = FlutterFragCoord().xy / size;
  vec4 center = texture(u_texture_input, clamp(uv, vec2(0.0), vec2(1.0)));
  vec3 accumulatedColor = center.rgb;
  float accumulatedAlpha = center.a;

  for (int i = 1; i <= 61; ++i) {
    float offset = float(i);
    float weight = exp(-offset * offset * u_inv2s2);
    vec2 stepUv = u_direction * offset / size;
    vec4 positive = texture(
      u_texture_input,
      clamp(uv + stepUv, vec2(0.0), vec2(1.0))
    );
    vec4 negative = texture(
      u_texture_input,
      clamp(uv - stepUv, vec2(0.0), vec2(1.0))
    );
    accumulatedColor += (positive.rgb + negative.rgb) * weight;
    accumulatedAlpha += (positive.a + negative.a) * weight;
  }

  vec3 color = accumulatedAlpha > 0.0001
      ? accumulatedColor / accumulatedAlpha
      : vec3(0.0);
  fragColor = vec4(color, 1.0);
}
