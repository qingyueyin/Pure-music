# AMLL Mesh Gradient - Quick Reference & Code Snippets

**Purpose**: Copy-paste ready code and algorithm pseudocode for rapid development

---

## PART 1: ALGORITHM PSEUDOCODE

### Bicubic Hermite Patch Evaluation

```pseudocode
FUNCTION evaluatePatch(
    controlPoints: 2x2 ControlPointMatrix,
    subdivisions: int,
    output: VertexArray[subdivisions * subdivisions * 7]
):
    // Pre-compute H matrix (once at startup)
    H = [[2, -2, 1, 1],
         [-3, 3, -2, -1],
         [0, 0, 1, 0],
         [1, 0, 0, 0]]
    
    H_T = transpose(H)
    
    // Pre-compute power polynomials
    normPowers = []
    FOR i = 0 TO subdivisions:
        norm = i / (subdivisions - 1)
        normPowers[i] = [norm³, norm², norm, 1]
    
    // Compute geometry matrices
    M_x = buildMeshCoefficients(controlPoints, axis=X)
    M_y = buildMeshCoefficients(controlPoints, axis=Y)
    M_r = buildColorCoefficients(controlPoints, axis=R)
    M_g = buildColorCoefficients(controlPoints, axis=G)
    M_b = buildColorCoefficients(controlPoints, axis=B)
    
    // Pre-compute accumulation matrices
    Acc_x = H_T · M_x · H
    Acc_y = H_T · M_y · H
    Acc_r = H_T · M_r · H
    Acc_g = H_T · M_g · H
    Acc_b = H_T · M_b · H
    
    // Generate vertices
    vertexIdx = 0
    FOR u = 0 TO subdivisions:
        // Compute basis · Acc for this u value
        U = normPowers[u]
        U_x = U · Acc_x
        U_y = U · Acc_y
        U_r = U · Acc_r
        U_g = U · Acc_g
        U_b = U · Acc_b
        
        FOR v = 0 TO subdivisions:
            V = normPowers[v]
            
            // Final vertex position and color
            px = dot(V, U_x)
            py = dot(V, U_y)
            pr = dot(V, U_r)
            pg = dot(V, U_g)
            pb = dot(V, U_b)
            
            // Texture coordinates
            uvX = (u / (subdivisions - 1))
            uvY = (v / (subdivisions - 1))
            
            // Store vertex data: [x, y, r, g, b, u, v]
            output[vertexIdx++] = [px, py, pr, pg, pb, uvX, uvY]
    
    RETURN output
END

FUNCTION buildMeshCoefficients(
    p00, p01, p10, p11: ControlPoint,
    axis: ENUM(X, Y)
):
    // Extract location and tangent components for given axis
    l00 = getComponent(p00.location, axis)
    l01 = getComponent(p01.location, axis)
    l10 = getComponent(p10.location, axis)
    l11 = getComponent(p11.location, axis)
    
    u00 = getComponent(p00.uTangent, axis)
    u01 = getComponent(p01.uTangent, axis)
    u10 = getComponent(p10.uTangent, axis)
    u11 = getComponent(p11.uTangent, axis)
    
    v00 = getComponent(p00.vTangent, axis)
    v01 = getComponent(p01.vTangent, axis)
    v10 = getComponent(p10.vTangent, axis)
    v11 = getComponent(p11.vTangent, axis)
    
    // Assemble 4x4 matrix
    RETURN [[l00, l01, v00, v01],
            [l10, l11, v10, v11],
            [u00, u01,  0,   0],
            [u10, u11,  0,   0]]
END

FUNCTION buildColorCoefficients(
    p00, p01, p10, p11: ControlPoint,
    axis: ENUM(R, G, B)
):
    // Color only uses positions, no tangents
    c00 = getComponent(p00.color, axis)
    c01 = getComponent(p01.color, axis)
    c10 = getComponent(p10.color, axis)
    c11 = getComponent(p11.color, axis)
    
    RETURN [[c00, c01,  0,  0],
            [c10, c11,  0,  0],
            [ 0,   0,   0,  0],
            [ 0,   0,   0,  0]]
END
```

### Animation Loop

```pseudocode
FUNCTION animationTick(deltaTime: milliseconds):
    // Accumulate frame time
    frameTime += deltaTime * flowSpeed
    
    // Smooth audio volume (low-pass filter)
    lerpFactor = min(1.0, deltaTime / 100.0)
    smoothedVolume += (rawVolume - smoothedVolume) * lerpFactor
    
    // Handle state transitions
    deltaFactor = deltaTime / 500.0
    
    IF isTransitioningOut:
        FOR EACH meshState:
            meshState.alpha = max(-0.1, meshState.alpha - deltaFactor)
    ELSE IF isTransitioningIn:
        currentMeshState.alpha = min(1.1, currentMeshState.alpha + deltaFactor)
        
        IF currentMeshState.alpha >= 1.1:
            // Transition complete, delete old meshes
            FOR EACH oldMesh IN meshStates[0:end-1]:
                dispose(oldMesh)
                dispose(oldMesh.texture)
            meshStates = [currentMeshState]
    
    // Render pass
    FOR EACH meshState:
        // Pass 1: Render to framebuffer
        bindFramebuffer(fbo)
        setUniform("u_time", frameTime / 10000)
        setUniform("u_volume", smoothedVolume)
        drawMesh(meshState)
        
        // Pass 2: Composite to screen
        bindFramebuffer(null)
        alpha = easeInOutSine(clamp(meshState.alpha, 0, 1))
        setUniform("u_alpha", alpha)
        drawFullscreenQuad()
END

FUNCTION easeInOutSine(x: number) -> number:
    RETURN (1 - cos(π * x)) / 2
END
```

### Image Processing Pipeline

```pseudocode
FUNCTION processAlbumArt(
    sourceImage: Image,
    targetSize: (32, 32)
) -> ImageData:
    // Step 1: Resize to 32x32
    canvas = createCanvas(32, 32)
    ctx = canvas.getContext("2d")
    ctx.drawImage(sourceImage, 0, 0, 32, 32)
    imageData = ctx.getImageData(0, 0, 32, 32)
    
    // Step 2: Color transformation
    FOR EACH pixel (r, g, b) IN imageData:
        // Contrast pass 1: Darken
        r = (r - 128) * 0.4 + 128
        g = (g - 128) * 0.4 + 128
        b = (b - 128) * 0.4 + 128
        
        // Saturation: Intensify colors
        gray = r * 0.3 + g * 0.59 + b * 0.11
        r = gray * (-2.0) + r * 3.0    // = gray + 3*(r-gray)
        g = gray * (-2.0) + g * 3.0
        b = gray * (-2.0) + b * 3.0
        
        // Contrast pass 2: Brighten
        r = (r - 128) * 1.7 + 128
        g = (g - 128) * 1.7 + 128
        b = (b - 128) * 1.7 + 128
        
        // Brightness: Dim
        r = r * 0.75
        g = g * 0.75
        b = b * 0.75
        
        pixel = [r, g, b]
    
    // Step 3: Gaussian blur
    blurImage(imageData, radius=2, iterations=4)
    
    RETURN imageData
END
```

---

## PART 2: DART CODE SNIPPETS

### 2.1 Vector Math Operations

```dart
// Matrix · Vector multiplication
Vector4 matrixVectorMult(Matrix4 m, Vector4 v) {
  return m.transform(v);
  // or explicitly:
  // return m.transpose() * v;  // Depends on matrix layout
}

// Matrix · Matrix multiplication
Matrix4 matrixMatrixMult(Matrix4 a, Matrix4 b) {
  return a * b;
}

// Transpose
Matrix4 transpose(Matrix4 m) {
  final result = Matrix4.copy(m);
  result.transpose();
  return result;
}

// Identity matrix
Matrix4 identity() => Matrix4.identity();

// Clone matrix
Matrix4 clone(Matrix4 m) => Matrix4.copy(m);

// Set from values (row-major)
Matrix4 setValues(List<double> values) {
  return Matrix4.fromList(values);
}

// Vector dot product
double dot(Vector4 a, Vector4 b) {
  return a.dot(b);
}

// Vector magnitude
double magnitude(Vector4 v) {
  return v.length;
}
```

### 2.2 Image Processing

```dart
// Resize image
Future<ui.Image> resizeImage(ui.Image source, int targetWidth, int targetHeight) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  
  canvas.drawImageRect(
    source,
    Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
    Paint(),
  );
  
  final picture = recorder.endRecording();
  return await picture.toImage(targetWidth, targetHeight);
}

// Apply color transformation to ByteData
void transformImageColors(ByteData pixels) {
  for (int i = 0; i < pixels.lengthInBytes; i += 4) {
    double r = pixels.getUint8(i).toDouble();
    double g = pixels.getUint8(i + 1).toDouble();
    double b = pixels.getUint8(i + 2).toDouble();
    
    // Contrast 0.4
    r = (r - 128) * 0.4 + 128;
    g = (g - 128) * 0.4 + 128;
    b = (b - 128) * 0.4 + 128;
    
    // Saturation 3.0
    final gray = r * 0.3 + g * 0.59 + b * 0.11;
    r = gray * -2.0 + r * 3.0;
    g = gray * -2.0 + g * 3.0;
    b = gray * -2.0 + b * 3.0;
    
    // Contrast 1.7
    r = (r - 128) * 1.7 + 128;
    g = (g - 128) * 1.7 + 128;
    b = (b - 128) * 1.7 + 128;
    
    // Brightness 0.75
    r = r * 0.75;
    g = g * 0.75;
    b = b * 0.75;
    
    // Clamp to [0, 255]
    pixels.setUint8(i, (r as int).clamp(0, 255));
    pixels.setUint8(i + 1, (g as int).clamp(0, 255));
    pixels.setUint8(i + 2, (b as int).clamp(0, 255));
  }
}

// Gaussian blur simulation (simplified)
void gaussianBlur(List<int> pixels, int width, int height, int radius) {
  // Full implementation would require:
  // 1. Separate H and V passes
  // 2. Gaussian kernel pre-computation
  // 3. Border handling
  // Consider using image_pixels package for production
}
```

### 2.3 Preset Control Points

```dart
// From AMLL cp-presets.ts - Dart equivalent

class ControlPointConf {
  final int cx, cy;
  final double x, y;
  final double ur, vr;
  final double up, vp;
  
  const ControlPointConf({
    required this.cx, required this.cy,
    required this.x, required this.y,
    required this.ur, required this.vr,
    required this.up, required this.vp,
  });
}

class ControlPointPreset {
  final int width, height;
  final List<ControlPointConf> conf;
  
  const ControlPointPreset({
    required this.width,
    required this.height,
    required this.conf,
  });
}

// Helper constructor
ControlPointConf cp(int cx, int cy, double x, double y,
    [double ur = 0, double vr = 0, double up = 1, double vp = 1]) {
  return ControlPointConf(
    cx: cx, cy: cy, x: x, y: y, ur: ur, vr: vr, up: up, vp: vp,
  );
}

// Example: 5x5 Preset
const preset5x5 = ControlPointPreset(
  width: 5,
  height: 5,
  conf: [
    cp(0, 0, -1, -1),
    cp(1, 0, -0.5, -1),
    cp(2, 0, 0, -1),
    // ... 22 more points
  ],
);

// Generate all presets
const List<ControlPointPreset> CONTROL_POINT_PRESETS = [
  preset5x5,
  // ... more presets
];
```

### 2.4 State Management

```dart
// Mesh state data class
class MeshState {
  final BHPMesh mesh;
  final ui.Image textureImage;
  double alpha;
  
  MeshState({
    required this.mesh,
    required this.textureImage,
    this.alpha = 0.0,
  });
  
  void dispose() {
    mesh.dispose();
    // textureImage disposed by Flutter
  }
}

// State transition manager
class StateTransitionManager extends ChangeNotifier {
  final List<MeshState> meshStates = [];
  bool isTransitioningOut = false;
  
  void addMeshState(MeshState state) {
    meshStates.add(state);
    isTransitioningOut = false;
    notifyListeners();
  }
  
  void transitionOut(double deltaTime) {
    isTransitioningOut = true;
    final deltaFactor = deltaTime / 500.0;
    
    for (final state in meshStates) {
      state.alpha = (state.alpha - deltaFactor).clamp(-0.1, 1.0);
    }
    
    // Remove fully faded states
    meshStates.removeWhere((s) => s.alpha <= -0.1);
    
    notifyListeners();
  }
  
  void transitionIn(double deltaTime) {
    if (meshStates.isEmpty) return;
    
    isTransitioningOut = false;
    final deltaFactor = deltaTime / 500.0;
    final currentState = meshStates.last;
    
    currentState.alpha = (currentState.alpha + deltaFactor).clamp(0.0, 1.1);
    
    // Transition complete
    if (currentState.alpha >= 1.1) {
      // Clean up old states
      for (int i = 0; i < meshStates.length - 1; i++) {
        meshStates[i].dispose();
      }
      meshStates.removeRange(0, meshStates.length - 1);
    }
    
    notifyListeners();
  }
  
  @override
  void dispose() {
    for (final state in meshStates) {
      state.dispose();
    }
    super.dispose();
  }
}
```

### 2.5 Shader Integration

```dart
// Fragment shader for mesh gradient effects
// assets/shaders/mesh_gradient.frag

const String meshGradientFragShader = '''
precision highp float;

// Vertex attributes
varying vec3 v_color;
varying vec2 v_uv;

// Uniforms
uniform sampler2D u_texture;
uniform float u_time;
uniform float u_volume;
uniform float u_alpha;
uniform float u_aspect;

// Pre-computed constants
const float INV_255 = 1.0 / 255.0;
const float HALF_INV_255 = 0.5 / 255.0;
const float GRADIENT_NOISE_A = 52.9829189;
const vec2 GRADIENT_NOISE_B = vec2(0.06711056, 0.00583715);

// Gradient noise function
float gradientNoise(in vec2 uv) {
  return fract(GRADIENT_NOISE_A * fract(dot(uv, GRADIENT_NOISE_B)));
}

// Rotation function
vec2 rot(vec2 v, float angle) {
  float s = sin(angle);
  float c = cos(angle);
  return vec2(c * v.x - s * v.y, s * v.x + c * v.y);
}

void main() {
  float volumeEffect = u_volume * 2.0;
  float timeVolume = u_time + u_volume;
  
  float dither = INV_255 * gradientNoise(gl_FragCoord.xy) - HALF_INV_255;
  vec2 centeredUV = v_uv - vec2(0.2);
  vec2 rotatedUV = rot(centeredUV, timeVolume * 2.0);
  vec2 finalUV = rotatedUV * max(0.001, 1.0 - volumeEffect) + vec2(0.5);
  
  vec4 result = texture2D(u_texture, finalUV);
  
  float alphaVolumeFactor = u_alpha * max(0.5, 1.0 - u_volume * 0.5);
  result.rgb *= v_color * alphaVolumeFactor;
  result.a *= alphaVolumeFactor;
  
  result.rgb += vec3(dither);
  
  float dist = distance(v_uv, vec2(0.5));
  float vignette = smoothstep(0.8, 0.3, dist);
  float mask = 0.6 + vignette * 0.4;
  result.rgb *= mask;
  
  gl_FragColor = result;
}
''';

// Dart wrapper for shader
class MeshGradientShader {
  late ui.FragmentProgram _program;
  bool _isLoaded = false;
  
  Future<void> load() async {
    _program = await ui.FragmentProgram.fromAsset('assets/shaders/mesh_gradient.frag');
    _isLoaded = true;
  }
  
  Shader createShader(
    Size size,
    double time,
    double volume,
    double alpha,
    double aspect,
  ) {
    final shader = _program.fragmentShader();
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, time);
    shader.setFloat(3, volume);
    shader.setFloat(4, alpha);
    shader.setFloat(5, aspect);
    return shader;
  }
}
```

### 2.6 Performance Monitoring

```dart
class PerformanceMonitor extends ChangeNotifier {
  int frameCount = 0;
  int currentFPS = 0;
  int lastFPSUpdate = 0;
  int lastFrameTime = 0;
  
  double averageFrameTime = 0.0;
  final List<double> frameTimeHistory = [];
  static const int maxHistorySize = 60;
  
  void tick(int currentTime) {
    frameCount++;
    
    // Update FPS every 1 second
    if (currentTime - lastFPSUpdate > 1000) {
      currentFPS = frameCount;
      frameCount = 0;
      lastFPSUpdate = currentTime;
      notifyListeners();
    }
    
    // Track frame time
    if (lastFrameTime > 0) {
      final delta = currentTime - lastFrameTime;
      frameTimeHistory.add(delta.toDouble());
      
      if (frameTimeHistory.length > maxHistorySize) {
        frameTimeHistory.removeAt(0);
      }
      
      averageFrameTime = frameTimeHistory.reduce((a, b) => a + b) / frameTimeHistory.length;
    }
    
    lastFrameTime = currentTime;
  }
  
  int getEstimatedMemoryUsage() {
    // Rough estimate
    // Vertex data: width * height * 7 floats * 4 bytes = width*height*28 bytes
    // For 50 subdivisions with 3x3 control points:
    // 150 * 150 * 28 = ~630KB per mesh state
    return 630 * 1024;  // Approx 630KB
  }
}
```

---

## PART 3: INTEGRATION CHECKLIST

### Connect to Audio Pipeline

```dart
// In PlaybackService extension
Future<void> attachMeshGradient(MeshGradientRenderer meshGradient) async {
  // Volume updates
  _volumeStream = volumeStream.listen((volume) {
    meshGradient.setVolume(volume / 10.0);
  });
  
  // Playback state
  _stateStream = playerStateStream.listen((state) {
    if (state == PlayerState.playing) {
      meshGradient.resume();
    } else {
      meshGradient.pause();
    }
  });
  
  // Spectrum/frequency data (if available)
  _spectrumStream = spectrumStream?.listen((data) {
    meshGradient.updateFrequencyData(data);
  });
}
```

### Integrate with Now Playing Page

```dart
// In NowPlayingPage state
class _NowPlayingPageState extends State<NowPlayingPage> 
    with TickerProviderStateMixin {
  
  late MeshGradientRenderer _meshGradient;
  late AnimationController _animationController;
  
  @override
  void initState() {
    super.initState();
    
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    )..repeat();
    
    _meshGradient = MeshGradientRenderer();
    PlayService.instance.playbackService.attachMeshGradient(_meshGradient);
  }
  
  @override
  void dispose() {
    _meshGradient.dispose();
    _animationController.dispose();
    super.dispose();
  }
}
```

---

## PART 4: DEBUGGING TIPS

### Verify Matrix Calculations

```dart
// Test Hermite matrix
void testHermiteMatrix() {
  // H should satisfy: H · [0, 0, 0, 1]^T = [1, 0, 0, 0]^T
  // (i.e., at t=0, basis = [0, 0, 0, 1])
  
  final H = HermiteMath.H;
  final basis0 = Vector4(0, 0, 0, 1);
  final result = H.transform(basis0);
  
  print('At t=0: $result'); // Should be ~[1, 0, 0, 0]
  
  // At t=1, basis = [1, 1, 1, 1]
  final basis1 = Vector4(1, 1, 1, 1);
  final result1 = H.transform(basis1);
  
  print('At t=1: $result1'); // Should be ~[0, 0, 1, 1]
}
```

### Mesh Generation Debugging

```dart
// Visualize control point grid
void visualizeControlPoints() {
  for (int x = 0; x < controlPoints.width; x++) {
    for (int y = 0; y < controlPoints.height; y++) {
      final cp = controlPoints.get(x, y);
      print('CP[$x,$y]: loc=${cp.location}, color=${cp.color}');
    }
  }
}

// Verify vertex generation
void debugVertexGeneration() {
  final mesh = BHPMesh(controlPoints, subdivisions: 10);
  mesh.updateMesh();
  
  print('Generated ${mesh.vertexData.length ~/ 7} vertices');
  
  // Sample first few vertices
  for (int i = 0; i < 3; i++) {
    final idx = i * 7;
    print('V[$i]: x=${mesh.vertexData[idx]}, y=${mesh.vertexData[idx+1]}');
  }
}
```

### Performance Profiling

```dart
// Measure mesh update time
void profileMeshUpdate() {
  final sw = Stopwatch()..start();
  
  for (int i = 0; i < 100; i++) {
    mesh.updateMesh();
  }
  
  sw.stop();
  print('Average mesh update: ${sw.elapsedMilliseconds / 100}ms');
}

// Memory profiling
Future<void> profileMemory() async {
  final info = await service.getMemoryInfo();
  print('Memory usage: ${info.usedHeapSize / 1024 / 1024}MB');
}
```

---

## CONSTANTS REFERENCE

```dart
/// Mathematical constants
const double PI = 3.141592653589793;
const double TAU = 2 * PI;

/// Image processing constants
const int ALBUM_ART_SIZE = 32;  // Texture resolution
const double CONTRAST_1 = 0.4;
const double SATURATION = 3.0;
const double CONTRAST_2 = 1.7;
const double BRIGHTNESS = 0.75;
const int BLUR_RADIUS = 2;
const int BLUR_ITERATIONS = 4;

/// Animation constants
const double FADE_DURATION_MS = 500.0;
const double VOLUME_SMOOTH_MS = 100.0;
const int TARGET_FPS = 60;
const double TIME_SCALE = 1.0 / 10000.0;

/// Mesh constants
const int DEFAULT_SUBDIVISIONS = 50;
const int DEFAULT_CP_WIDTH = 3;
const int DEFAULT_CP_HEIGHT = 3;

/// Shader constants
const double VIGNETTE_NEAR = 0.8;
const double VIGNETTE_FAR = 0.3;
const double VIGNETTE_MIN = 0.6;
const double VIGNETTE_MAX = 0.4;
const double VOLUME_ROTATION_SCALE = 2.0;
const double VOLUME_DAMPENING = 0.5;

/// Frequency response (for future audio reactivity)
const double FREQ_BASS_THRESHOLD = 0.3;
const double FREQ_MID_THRESHOLD = 0.5;
const double FREQ_TREBLE_THRESHOLD = 0.7;
```

