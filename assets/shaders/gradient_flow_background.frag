#include <flutter/runtime_effect.glsl>

#define S(a,b,t) smoothstep(a,b,t)

uniform vec2 uSize;
uniform float uTime;
uniform float uEnergy;

uniform vec3 uColor1;
uniform vec3 uColor2;
uniform vec3 uColor3;
uniform vec3 uColor4;

out vec4 fragColor;

mat2 Rot(float a)
{
    float s = sin(a);
    float c = cos(a);
    return mat2(c, -s, s, c);
}

// Inigo Quilez hash
vec2 hash( vec2 p )
{
    p = vec2( dot(p,vec2(2127.1,81.17)), dot(p,vec2(1269.5,283.37)) );
    return fract(sin(p)*43758.5453);
}

float noise( in vec2 p )
{
    vec2 i = floor( p );
    vec2 f = fract( p );
    vec2 u = f*f*(3.0-2.0*f);
    float n = mix( mix( dot( -1.0+2.0*hash( i + vec2(0.0,0.0) ), f - vec2(0.0,0.0) ),
                        dot( -1.0+2.0*hash( i + vec2(1.0,0.0) ), f - vec2(1.0,0.0) ), u.x),
                   mix( dot( -1.0+2.0*hash( i + vec2(0.0,1.0) ), f - vec2(0.0,1.0) ),
                        dot( -1.0+2.0*hash( i + vec2(1.0,1.0) ), f - vec2(1.0,1.0) ), u.x), u.y);
    return 0.5 + 0.5*n;
}

void main()
{
    vec2 uv = FlutterFragCoord().xy / uSize;
    float ratio = uSize.x / uSize.y;

    vec2 tuv = uv;
    tuv -= .5;

    // Noise-driven rotation (same as mesh_gradient: 720 degrees)
    float degree = noise(vec2(uTime * .1, tuv.x * tuv.y));
    tuv.y *= 1. / ratio;
    tuv *= Rot(radians((degree - .5) * 720. + 180.));
    tuv.y *= ratio;

    // Wave warp with energy-driven amplitude
    float frequency = 3.0;
    float amplitude = 25.0 + uEnergy * 15.0;
    float speed = uTime * 1.2;
    tuv.x += sin(tuv.y * frequency + speed) / amplitude;
    tuv.y += sin(tuv.x * frequency * 1.5 + speed) / (amplitude * .5);

    // Layer blending
    vec3 layer1 = mix(uColor1, uColor2, S(-.3, .2, (tuv * Rot(radians(-5.))).x));
    vec3 layer2 = mix(uColor3, uColor4, S(-.3, .2, (tuv * Rot(radians(-5.))).x));
    vec3 col = mix(layer1, layer2, S(.5, -.3, tuv.y));

    // DESATURATION: 65% saturation
    float lum = dot(col, vec3(0.299, 0.587, 0.114));
    col = mix(vec3(lum), col, 0.65);

    // SPATIAL LUMINANCE: 50% dark center, 85% at edges
    float dist = length(uv - 0.5) * 1.414;
    col *= 0.50 + dist * 0.35;

    // Subtle vignette
    col *= 1.0 - 0.06 * length(uv - 0.5);

    fragColor = vec4(col, 1.0);
}
