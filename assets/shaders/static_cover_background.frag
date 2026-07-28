#version 460 core

precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec2 u_resolution;
uniform float u_lerp;
uniform float u_blackScrimAlpha;
uniform float u_whiteScrimAlpha;
uniform sampler2D u_texture_0;
uniform sampler2D u_texture_1;

out vec4 fragColor;

vec2 coverUv(vec2 screenUv) {
  float aspect = u_resolution.x / max(u_resolution.y, 1.0);
  vec2 uv = screenUv;
  if (aspect >= 1.0) {
    uv.y = 0.5 + (screenUv.y - 0.5) / aspect;
  } else {
    uv.x = 0.5 + (screenUv.x - 0.5) * aspect;
  }
  return clamp(uv, vec2(0.001), vec2(0.999));
}

vec3 artwork(vec2 uv) {
  vec3 oldCover = texture(u_texture_0, uv).rgb;
  vec3 newCover = texture(u_texture_1, uv).rgb;
  return mix(oldCover, newCover, clamp(u_lerp, 0.0, 1.0));
}

void main() {
  vec2 resolution = max(u_resolution, vec2(1.0));
  vec2 screenUv = FlutterFragCoord().xy / resolution;
  vec2 uv = coverUv(screenUv);
  vec3 color = artwork(uv);
  color = mix(color, vec3(0.0), clamp(u_blackScrimAlpha, 0.0, 1.0));
  color = mix(color, vec3(1.0), clamp(u_whiteScrimAlpha, 0.0, 1.0));
  fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
