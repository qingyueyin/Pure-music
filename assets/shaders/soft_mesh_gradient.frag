#include <flutter/runtime_effect.glsl>

#define S(a, b, t) smoothstep(a, b, t)

uniform vec2 uSize;
uniform float uTime;
// 鼓点短暂收小扭曲幅度；流速由 Dart 侧按慢电平调整，不改亮度、不整屏缩放。
uniform float uBeat;
// uColor1..4 为 OkLab，混色后转回 sRGB。
uniform vec3 uColor1;
uniform vec3 uColor2;
uniform vec3 uColor3;
uniform vec3 uColor4;

out vec4 fragColor;

mat2 rotate2d(float angle) {
  float sine = sin(angle);
  float cosine = cos(angle);
  return mat2(cosine, -sine, sine, cosine);
}

vec2 hash2(vec2 point) {
  vec3 value = fract(vec3(point.xyx) * vec3(0.1031, 0.1030, 0.0973));
  value += dot(value, value.yzx + 33.33);
  return fract((value.xx + value.yz) * value.zy);
}

float gradientNoise(vec2 point) {
  vec2 cell = floor(point);
  vec2 local = fract(point);
  vec2 curve = local * local * (3.0 - 2.0 * local);
  float bottom = mix(
    dot(-1.0 + 2.0 * hash2(cell), local),
    dot(-1.0 + 2.0 * hash2(cell + vec2(1.0, 0.0)), local - vec2(1.0, 0.0)),
    curve.x
  );
  float top = mix(
    dot(-1.0 + 2.0 * hash2(cell + vec2(0.0, 1.0)), local - vec2(0.0, 1.0)),
    dot(-1.0 + 2.0 * hash2(cell + vec2(1.0, 1.0)), local - vec2(1.0, 1.0)),
    curve.x
  );
  return 0.5 + 0.5 * mix(bottom, top, curve.y);
}

float linearToSrgb(float value) {
  if (value <= 0.0031308) return 12.92 * value;
  return 1.055 * pow(value, 1.0 / 2.4) - 0.055;
}

vec3 oklabToSrgb(vec3 lab) {
  float l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
  float m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
  float s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
  float l = l_ * l_ * l_;
  float m = m_ * m_ * m_;
  float s = s_ * s_ * s_;
  vec3 linear = vec3(
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
  );
  return vec3(
    linearToSrgb(linear.r),
    linearToSrgb(linear.g),
    linearToSrgb(linear.b)
  );
}

float ditherNoise(vec2 position) {
  return fract(52.9829189 * fract(dot(position, vec2(0.06711056, 0.00583715))));
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  float ratio = uSize.x / uSize.y;
  vec2 gradientPoint = uv - 0.5;

  gradientPoint.y /= ratio;
  float angleNoise = gradientNoise(
    vec2(
      uTime * 0.10 + 0.035,
      gradientPoint.x * gradientPoint.y + 0.071
    )
  );
  float noiseAngle = radians((angleNoise - 0.5) * 720.0 + 180.0);
  gradientPoint *= rotate2d(noiseAngle);
  gradientPoint.y *= ratio;

  float frequency = 5.0;
  float amplitude = 25.0 / (1.0 + uBeat * 0.35);
  float speed = uTime * 0.75;
  gradientPoint.x += sin(gradientPoint.y * frequency + speed) / amplitude;
  gradientPoint.y +=
      sin(gradientPoint.x * frequency * 1.5 + speed) / (amplitude * 0.5);

  float ridgeValue = clamp(1.0 - abs(2.0 * angleNoise - 1.0), 0.0, 1.0);
  float ridge = smoothstep(0.20, 0.80, ridgeValue);
  float ridgeLine = ridge * ridge * ridge;
  float colorBend = (angleNoise - 0.5) * 0.16;
  vec2 gradientAxis = vec2(cos(radians(-2.0)), sin(radians(-2.0)));
  float horizontalBlend = clamp(
    S(-0.3, 0.2, dot(gradientPoint, gradientAxis)) +
        colorBend +
        (ridge - 0.5) * 0.05,
    0.0,
    1.0
  );
  float verticalBlend = clamp(
    1.0 - S(-0.3, 0.5, gradientPoint.y) + colorBend * 0.65,
    0.0,
    1.0
  );
  // 增加主色权重，不改变其他颜色本身。
  float weight1 = (1.0 - horizontalBlend) * (1.0 - verticalBlend) * 1.6;
  float weight2 = horizontalBlend * (1.0 - verticalBlend);
  float weight3 = (1.0 - horizontalBlend) * verticalBlend;
  float weight4 = horizontalBlend * verticalBlend;
  float weightSum = weight1 + weight2 + weight3 + weight4;
  vec3 color = (
    uColor1 * weight1 +
    uColor2 * weight2 +
    uColor3 * weight3 +
    uColor4 * weight4
  ) / max(weightSum, 0.0001);
  color.x -= ridgeLine * 0.035;
  color.y += (angleNoise - 0.5) * 0.012;
  color.z -= (angleNoise - 0.5) * 0.008;
  color = oklabToSrgb(color);
  color += (ditherNoise(FlutterFragCoord().xy) - 0.5) / 255.0;
  fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
