#version 460
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform float uIntensity;
uniform float uLowFreqVolume;
uniform float uCoverDarkness;
uniform float uAlbumBlend;
uniform float uHasAlbum;

uniform vec3 uColor1;
uniform vec3 uColor2;
uniform vec3 uColor3;
uniform vec3 uColor4;

uniform vec2 uFlow0;
uniform vec2 uFlow1;
uniform vec2 uFlow2;
uniform vec2 uFlow3;
uniform vec2 uFlow4;
uniform vec2 uFlow5;
uniform vec2 uFlow6;
uniform vec2 uFlow7;
uniform vec2 uFlow8;
uniform vec2 uFlow9;
uniform vec2 uFlow10;
uniform vec2 uFlow11;
uniform vec2 uFlow12;
uniform vec2 uFlow13;
uniform vec2 uFlow14;
uniform vec2 uFlow15;

uniform sampler2D uAlbumPrev;
uniform sampler2D uAlbumCurr;

out vec4 fragColor;

vec2 mod289v2(vec2 v) { return v - floor(v * (1.0 / 289.0)) * 289.0; }
vec3 mod289v3(vec3 v) { return v - floor(v * (1.0 / 289.0)) * 289.0; }
vec3 permute3(vec3 x) { return mod289v3(((x * 34.0) + 1.0) * x); }

float snoise2(vec2 v) {
    const vec4 C = vec4(0.211324865405187, 0.366025403784439,
                       -0.577350269189626, 0.024390243902439);
    vec2 i  = floor(v + dot(v, C.yy));
    vec2 x0 = v - i + dot(i, C.xx);
    vec2 i1  = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec4 x12 = x0.xyxy + C.xxzz;
    x12.xy  -= i1;
    i = mod289v2(i);
    vec3 p = permute3(permute3(i.y + vec3(0.0, i1.y, 1.0))
                              + i.x + vec3(0.0, i1.x, 1.0));
    vec3 m = max(0.5 - vec3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
    m = m * m * m * m;
    vec3 x = 2.0 * fract(p * C.www) - 1.0;
    vec3 h = abs(x) - 0.5;
    vec3 ox = floor(x + 0.5);
    vec3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0*a0 + h*h);
    vec3 g;
    g.x  = a0.x  * x0.x   + h.x  * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

float snoise1(float v) { return snoise2(vec2(v, v * 0.371)); }

float fbm4(vec2 p) {
    float v = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; i++) {
        v += amp * snoise2(p);
        p *= 2.03;
        amp *= 0.50;
    }
    return v;
}

vec2 flowAt(int idx) {
    if (idx == 0) return uFlow0;
    if (idx == 1) return uFlow1;
    if (idx == 2) return uFlow2;
    if (idx == 3) return uFlow3;
    if (idx == 4) return uFlow4;
    if (idx == 5) return uFlow5;
    if (idx == 6) return uFlow6;
    if (idx == 7) return uFlow7;
    if (idx == 8) return uFlow8;
    if (idx == 9) return uFlow9;
    if (idx == 10) return uFlow10;
    if (idx == 11) return uFlow11;
    if (idx == 12) return uFlow12;
    if (idx == 13) return uFlow13;
    if (idx == 14) return uFlow14;
    return uFlow15;
}

vec2 sampleFlow(vec2 uv) {
    vec2 g  = clamp(uv, 0.0, 1.0) * 3.0;
    vec2 gi = floor(g);
    vec2 gf = fract(g);
    vec2 w  = gf * gf * (3.0 - 2.0 * gf);

    int x0 = int(gi.x);
    int y0 = int(gi.y);
    int x1 = int(clamp(float(x0 + 1), 0.0, 3.0));
    int y1 = int(clamp(float(y0 + 1), 0.0, 3.0));

    vec2 f00 = flowAt(x0 + y0 * 4);
    vec2 f10 = flowAt(x1 + y0 * 4);
    vec2 f01 = flowAt(x0 + y1 * 4);
    vec2 f11 = flowAt(x1 + y1 * 4);

    return mix(mix(f00, f10, w.x), mix(f01, f11, w.x), w.y);
}

vec2 mirroredUv(vec2 uv) {
    vec2 tiled = mod(uv, 2.0);
    return mix(tiled, 2.0 - tiled, step(1.0, tiled));
}

vec2 rotate2d(vec2 p, float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return vec2(c * p.x - s * p.y, s * p.x + c * p.y);
}

vec2 albumWarpUv(vec2 uv, float t, float energy) {
    vec2 localFlow = sampleFlow(fract(uv + vec2(t * 0.018, -t * 0.013)));
    float angle = (fbm4(uv * 2.2 + vec2(1.7, -2.3) + t * 0.09) + energy * 0.3) * 1.5;
    vec2 centered = uv - 0.5;
    vec2 rotated = rotate2d(centered, angle);
    vec2 swirl = localFlow * (0.17 + energy * 0.14) + vec2(
        snoise2(uv * 1.6 + vec2(t * 0.08, -t * 0.05)),
        snoise2(uv.yx * 1.5 + vec2(-t * 0.07, t * 0.04))
    ) * (0.05 + energy * 0.05);
    return mirroredUv(rotated * (1.05 - energy * 0.07) + 0.5 + swirl);
}

float curveLayerA(vec2 dUV, float t) {
    float wave = sin(dUV.x * 3.14159 * 1.2 + snoise1(dUV.y * 0.8 + t * 0.07) * 0.7) * 0.06;
    return smoothstep(0.44 + wave, 0.52 + wave, 1.0 - dUV.y);
}

float curveLayerB(vec2 dUV, float t) {
    float wave = cos(dUV.x * 3.14159 * 0.9 + snoise1(dUV.y * 1.1 - t * 0.05) * 0.6) * 0.05;
    return smoothstep(0.28 + wave, 0.36 + wave, dUV.y);
}

float streakLayer(vec2 dUV, float t) {
    float s = sin(dUV.x * 6.28318 * 1.8 + snoise2(vec2(dUV.y * 1.4, t * 0.08)) * 1.1) * 0.5 + 0.5;
    return smoothstep(0.40, 0.60, s);
}

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 uv = fragCoord / uSize;
    float intensity = clamp(uIntensity, 0.0, 2.0);
    float energy = log2(1.0 + clamp(uLowFreqVolume, 0.0, 1.0) * 7.0) / 3.0;
    float hasAlbum = clamp(uHasAlbum, 0.0, 1.0);

    float speed = (0.010 + energy * 0.0045) * (0.85 + intensity * 0.3);
    vec2 globalDrift = vec2(uTime * speed, uTime * -speed * 0.38);
    vec2 driftedUV = uv + globalDrift;
    vec2 tangent = sampleFlow(fract(driftedUV)) * (0.05 + energy * 0.05);
    vec2 flowedUV = driftedUV + tangent;

    float n1 = fbm4(flowedUV * 2.1 + vec2(0.0, uTime * 0.06));
    float n2 = fbm4(flowedUV * 1.6 + vec2(4.8, 1.7) - uTime * 0.04);
    float n3 = fbm4(flowedUV * 2.8 + vec2(1.2, 8.4) + uTime * 0.03);

    vec3 c1 = uColor1;
    vec3 c2 = uColor2;
    vec3 c3 = uColor3;
    vec3 c4 = uColor4;
    vec3 paletteField = mix(c1, c2, clamp(n1 * 0.5 + 0.5, 0.0, 1.0));
    paletteField = mix(paletteField, c3, clamp(n2 * 0.5 + 0.5, 0.0, 1.0) * 0.52);
    paletteField = mix(paletteField, c4, clamp(n3 * 0.5 + 0.5, 0.0, 1.0) * 0.30);

    vec2 coverUvA = albumWarpUv(flowedUV, uTime, energy);
    vec2 coverUvB = albumWarpUv(flowedUV + vec2(0.07, -0.03), uTime + 2.7, energy);
    vec3 albumPrev = texture(uAlbumPrev, coverUvA).rgb;
    vec3 albumCurr = texture(uAlbumCurr, coverUvB).rgb;
    vec3 albumColor = mix(albumPrev, albumCurr, clamp(uAlbumBlend, 0.0, 1.0));
    float centerMask = smoothstep(0.9, 0.3, distance(coverUvA, vec2(0.5)));
    albumColor *= (0.62 + centerMask * 0.38);

    vec3 blob = mix(paletteField, albumColor, hasAlbum * 0.58);

    float cA = curveLayerA(fract(flowedUV), uTime);
    float cB = curveLayerB(fract(flowedUV), uTime);
    float cS = streakLayer(fract(flowedUV), uTime);
    float curveMask = cA * 0.50 + cB * 0.32 + cS * 0.08;
    vec3 curveTint = mix(c4, c2, curveMask);
    blob = mix(blob, curveTint, curveMask * 0.26);

    blob *= (0.88 + energy * 0.16 * intensity);

    float luma = dot(blob, vec3(0.299, 0.587, 0.114));
    blob = mix(vec3(luma), blob, 0.82);

    float darkMul = 1.0 - uCoverDarkness * 0.72;
    float darkPow = 1.0 + uCoverDarkness * 0.60;
    blob = pow(clamp(blob * darkMul, 0.0, 1.0), vec3(darkPow));

    vec2 centered = uv - 0.5;
    float dist = length(centered);
    float vignette = smoothstep(1.4, 0.35, dist);
    float vigFloor = mix(0.0, 0.012, 1.0 - uCoverDarkness);
    blob = mix(vec3(vigFloor), blob, vignette);

    fragColor = vec4(blob, 1.0);
}
