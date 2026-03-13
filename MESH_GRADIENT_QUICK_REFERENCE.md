# Mesh Gradient Quick Reference Guide

## 1. Core Data Structures

### ControlPoint
```dart
class ControlPoint {
  Vec3 color;           // RGB [0-1]
  Vec2 location;        // XY [-1,1]
  Vec2 uTangent;        // Derived from uRot, uScale
  Vec2 vTangent;        // Derived from vRot, vScale
  double uRot;          // Radians
  double vRot;          // Radians
  double uScale;        // Magnitude
  double vScale;        // Magnitude
}
```

### ControlPointConf (Preset)
```dart
{
  cx, cy,               // Grid position
  x, y,                 // Actual location [-1,1]
  ur, vr,               // Rotation [degrees]
  up, vp                // Scale factors
}
```

## 2. Critical Hermite Matrices

### H Matrix (Hermite Basis)
```
H = [  2  -2   1   1 ]
    [ -3   3  -2  -1 ]
    [  0   0   1   0 ]
    [  1   0   0   0 ]
```

### H Basis Functions
```
h0(t) = 2t³ - 3t² + 1           (position at 0)
h1(t) = -2t³ + 3t²              (position at 1)
h2(t) = t³ - 2t² + t            (tangent at 0)
h3(t) = t³ - t²                 (tangent at 1)
```

## 3. Core Algorithm: Mesh Surface Computation

```dart
// For each patch (4x4 grid of points)
for (let x = 0; x < cpWidth - 1; x++) {
  for (let y = 0; y < cpHeight - 1; y++) {
    p00 = controlPoints[x, y]
    p01 = controlPoints[x, y+1]
    p10 = controlPoints[x+1, y]
    p11 = controlPoints[x+1, y+1]
    
    // Create coefficient matrices
    M_x = meshCoefficients(p00, p01, p10, p11, "x")
    M_y = meshCoefficients(p00, p01, p10, p11, "y")
    M_r = colorCoefficients(p00, p01, p10, p11, "r")
    M_g = colorCoefficients(p00, p01, p10, p11, "g")
    M_b = colorCoefficients(p00, p01, p10, p11, "b")
    
    // Precompute: Acc = H^T * M * H
    Acc_x = precompute(M_x)
    Acc_y = precompute(M_y)
    Acc_r = precompute(M_r)
    Acc_g = precompute(M_g)
    Acc_b = precompute(M_b)
    
    // Iterate over subdivision points
    for (let u = 0; u < subdivisions; u++) {
      // Compute U vector: [u³ u² u 1] * Acc
      U_x = [u³, u², u, 1] * Acc_x
      U_y = [u³, u², u, 1] * Acc_y
      U_r = [u³, u², u, 1] * Acc_r
      U_g = [u³, u², u, 1] * Acc_g
      U_b = [u³, u², u, 1] * Acc_b
      
      for (let v = 0; v < subdivisions; v++) {
        // Compute surface point: U · V^T
        V = [v³, v², v, 1]
        px = dot(U_x, V)
        py = dot(U_y, V)
        pr = dot(U_r, V)
        pg = dot(U_g, V)
        pb = dot(U_b, V)
        
        // Set vertex data
        setVertex(u, v, px, py, pr, pg, pb, uv_x, uv_y)
      }
    }
  }
}
```

## 4. Coefficient Matrix Assembly

### meshCoefficients()
```dart
Matrix4 meshCoefficients(p00, p01, p10, p11, axis) {
  // Extract components for given axis (x or y)
  return Matrix4([
    p00.location[axis],  p01.location[axis],  p00.vTangent[axis],  p01.vTangent[axis],
    p10.location[axis],  p11.location[axis],  p10.vTangent[axis],  p11.vTangent[axis],
    p00.uTangent[axis],  p01.uTangent[axis],  0,                  0,
    p10.uTangent[axis],  p11.uTangent[axis],  0,                  0,
  ])
}
```

### colorCoefficients()
```dart
Matrix4 colorCoefficients(p00, p01, p10, p11, channel) {
  // Extract color channel at corners only
  return Matrix4([
    p00.color[channel],  p01.color[channel],  0, 0,
    p10.color[channel],  p11.color[channel],  0, 0,
    0,                  0,                  0, 0,
    0,                  0,                  0, 0,
  ])
}
```

## 5. Vertex Buffer Layout

### Per-Vertex Data (7 floats)
```
[0-1]:   Position (x, y)
[2-4]:   Color (r, g, b)
[5-6]:   Texture UV (u, v)
```

### Example for 3×3 control points, 50 subdivisions
- Total vertices: 2×2 × 50² = 10,000
- Memory: 10,000 × 7 × 4 bytes = 280 KB

## 6. Animation Pipeline

### Time Update
```dart
frameTime += frameDelta * flowSpeed
shader.setUniform("u_time", frameTime / 10000)
```

### Volume Smoothing
```dart
lerpFactor = min(1.0, delta / 100.0)
smoothedVolume += (volume - smoothedVolume) * lerpFactor
shader.setUniform("u_volume", smoothedVolume)
```

### Alpha Blending for Transitions
```dart
// Fade in new mesh
newMesh.alpha = 0
newMesh.alpha += (0.002 / frameDelta)  // ~2 sec to 1.0

// Fade out old mesh
oldMesh.alpha -= (0.002 / frameDelta)

// Easing
finalAlpha = easeInOutSine(clamp(0, 1, alpha))
```

## 7. Shader Effects

### Fragment Shader Key Computations
```glsl
// UV Rotation (time + volume based)
vec2 centeredUV = v_uv - vec2(0.2);
vec2 rotatedUV = rot(centeredUV, (u_time + u_volume) * 2.0);
vec2 finalUV = rotatedUV * max(0.001, 1.0 - u_volume*2.0) + vec2(0.5);

// Dithering (prevent banding)
float dither = (1.0/255.0) * gradientNoise(gl_FragCoord.xy) - 0.5/255.0;

// Vignette (edge darkening)
float dist = distance(v_uv, vec2(0.5));
float vignette = smoothstep(0.8, 0.3, dist);
float mask = 0.6 + vignette * 0.4;
```

## 8. Image Processing Pipeline

```
Album Art (any size)
  ↓ (Resize to 32×32)
Original
  ↓ (Contrast: factor 0.4)
  ↓ (Saturate: factor 3.0)
  ↓ (Contrast: factor 1.7)
  ↓ (Brightness: factor 0.75)
  ↓ (Gaussian blur: radius 2, quality 4)
Processed
  ↓ (Upload to WebGL texture)
```

## 9. Performance Optimizations

### Pre-allocation (Avoid GC in render loop)
```dart
private Mat4[] tempMatrices = new Mat4[5];  // X, Y, R, G, B
private Vec4[] tempVectors = new Vec4[5];
```

### Power Caching
```dart
float[] normPowers = new float[subdivisions * 4];
for (int i = 0; i < subdivisions; i++) {
  float norm = i / (subdivisions - 1);
  normPowers[i*4+0] = pow(norm, 3);  // u³
  normPowers[i*4+1] = pow(norm, 2);  // u²
  normPowers[i*4+2] = norm;           // u
  normPowers[i*4+3] = 1.0;            // constant
}
```

### Batch Vertex Updates
```dart
void setVertexData(int vx, int vy, 
    double x, double y, 
    double r, double g, double b,
    double u, double v) {
  int idx = (vx + vy * width) * 7;
  data[idx] = x;
  data[idx+1] = y;
  data[idx+2] = r;
  data[idx+3] = g;
  data[idx+4] = b;
  data[idx+5] = u;
  data[idx+6] = v;
}
```

## 10. Key Constants

| Name | Value | Purpose |
|------|-------|---------|
| Album texture | 32×32 | Memory efficiency |
| Default subdivisions | 50 | Detail level |
| Default FPS | 60 | Frame rate |
| Contrast factors | 0.4, 1.7 | Color pop |
| Saturation | 3.0 | Vibrancy |
| Brightness | 0.75 | Tone |
| Blur radius | 2 | Smoothness |
| Volume scale | 2.0 | Rotation dampening |
| Time scale | 1/10000 | Shader stability |
| Dither scale | 1/255 | Anti-banding |

## 11. Rendering Loop Structure

```
RequestAnimationFrame
  ├─ Check FPS interval → Skip if too soon
  ├─ Update frameTime
  ├─ Update mesh state alphas
  ├─ Check canvas resize
  └─ For each MeshState:
      ├─ Render to FBO
      │  ├─ Bind FBO framebuffer
      │  ├─ Set uniforms (time, volume, alpha)
      │  ├─ Bind mesh & texture
      │  └─ Draw triangles
      └─ Composite FBO to screen
         ├─ Bind screen framebuffer
         ├─ Enable alpha blending
         ├─ Bind FBO texture
         └─ Draw full-screen quad
```

## 12. Critical Formulas

```
// Hermite basis
h₀(t) = 2t³ - 3t² + 1
h₁(t) = -2t³ + 3t²
h₂(t) = t³ - 2t² + t
h₃(t) = t³ - t²

// Patch surface
S(u,v) = H(u) * M * H(v)ᵀ

// Tangent vectors
uTangent = [cos(uRot) * uScale, sin(uRot) * uScale]
vTangent = [-sin(vRot) * vScale, cos(vRot) * vScale]

// Contrast
out = (in - 128) * factor + 128

// Saturation
gray = r*0.3 + g*0.59 + b*0.11
out = gray*(1-sat) + in*sat

// Smoothing (low-pass filter)
value += (target - value) * min(1, dt/tau)

// Easing
easeInOutSine(x) = -(cos(π*x) - 1) / 2
```

## 13. Common Configurations

### Desktop - High Quality
- Subdivisions: 50
- FPS: 60
- Render scale: 0.75
- Flow speed: 2-4

### Mobile - Balanced
- Subdivisions: 20
- FPS: 30
- Render scale: 0.5
- Flow speed: 1-2

### Low-End - Performance
- Subdivisions: 10
- FPS: 24
- Render scale: 0.25
- Flow speed: 0.5

## 14. Debugging Tips

### Check Wireframe
```dart
renderer.setWireFrame(true)  // Visualize mesh structure
```

### Monitor Performance
```dart
renderer.enablePerformanceMonitor(true)
double fps = renderer.getCurrentFPS()
```

### Manual Control
```dart
renderer.setManualControl(true)
ControlPoint cp = rende
