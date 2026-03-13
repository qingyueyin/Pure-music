# Pure Music + AMLL Mesh Gradient - Implementation Roadmap

**Status**: Ready for immediate development  
**Scope**: 4-6 week implementation plan with exact checkpoints

---

## PHASE BREAKDOWN

### PHASE 1: FOUNDATION (Week 1) - 40 hours

**Goal**: Establish core math and data structures  
**Artifacts**: Working unit tests, foundational classes

#### 1.1 Project Setup (4 hours)
- [ ] Add `vector_math: ^2.1.4` to `pubspec.yaml`
- [ ] Create directory structure:
  ```
  lib/mesh_gradient/
  ├── core/
  │   ├── hermite_math.dart
  │   ├── control_point.dart
  │   ├── bhp_mesh.dart
  │   └── mesh_state.dart
  ├── models/
  │   ├── mesh_config.dart
  │   └── preset_generator.dart
  ├── utils/
  │   ├── image_processor.dart
  │   └── cp_presets.dart
  ├── widgets/
  │   └── mesh_gradient_widget.dart
  ├── exports.dart
  └── README.md
  ```
- [ ] Create test directory:
  ```
  test/mesh_gradient/
  ├── hermite_math_test.dart
  ├── control_point_test.dart
  └── bhp_mesh_test.dart
  ```

#### 1.2 Hermite Math Implementation (12 hours)
**File**: `lib/mesh_gradient/core/hermite_math.dart`

```dart
class HermiteMath {
  // Static final Hermite basis matrix
  static final Matrix4 H = Matrix4.fromValues(...);
  static final Matrix4 H_T = ...;
  
  // Core functions:
  static Matrix4 precomputeMatrix(Matrix4 M) { ... }
  static Vector4 evaluateBasis(double t) { ... }
  static double easeInOutSine(double x) { ... }
  
  // Matrix utilities:
  static Vector4 matrixTransform(Matrix4 m, Vector4 v) { ... }
  static Matrix4 matrixMultiply(Matrix4 a, Matrix4 b) { ... }
}
```

- [ ] Implement Matrix4 operations
- [ ] Verify Hermite matrix against AMLL source (index.ts:416)
- [ ] Test basis function at t=0, 0.5, 1.0
- [ ] Implement precomputeMatrix (H^T · M · H)
- [ ] Test matrix pre-computation

#### 1.3 Control Point Implementation (8 hours)
**File**: `lib/mesh_gradient/core/control_point.dart`

```dart
class ControlPoint {
  final Vector3 color;
  final Vector2 location;
  final Vector2 uTangent;
  final Vector2 vTangent;
  
  // Getters/setters for tangent computation
  set uRot(double value);
  set vRot(double value);
  set uScale(double value);
  set vScale(double value);
}
```

- [ ] Implement all properties with tangent updates
- [ ] Verify tangent formula: `uTangent = (cos(uRot) * uScale, sin(uRot) * uScale)`
- [ ] Verify v-tangent formula: `vTangent = (-sin(vRot) * vScale, cos(vRot) * vScale)`
- [ ] Test rotation/scale combinations

#### 1.4 Unit Tests (8 hours)
**Files**: `test/mesh_gradient/*_test.dart`

```dart
void main() {
  group('HermiteMath', () {
    test('Hermite matrix values correct', () { ... });
    test('evaluateBasis returns correct powers', () { ... });
    test('easeInOutSine is symmetric', () { ... });
    test('precomputeMatrix produces correct result', () { ... });
  });
  
  group('ControlPoint', () {
    test('uTangent updates with rotation', () { ... });
    test('vTangent updates with scale', () { ... });
    test('tangent magnitude matches scale', () { ... });
  });
}
```

- [ ] Achieve 90%+ code coverage
- [ ] All tests pass
- [ ] No TODO comments in core code

#### 1.5 Code Review & Optimization (8 hours)
- [ ] Peer review (if available)
- [ ] Performance profiling of HermiteMath
- [ ] Optimize hot paths (avoid allocations)
- [ ] Document API thoroughly

**Success Criteria**:
- ✅ All unit tests pass
- ✅ HermiteMath verified against AMLL source
- ✅ No external dependencies except vector_math
- ✅ ~200 lines of code, clean and well-tested

---

### PHASE 2: MESH GENERATION (Week 1-2) - 60 hours

**Goal**: Implement full BHP mesh evaluation algorithm  
**Artifacts**: Working mesh generation, validation against reference

#### 2.1 Core Mesh Class (16 hours)
**File**: `lib/mesh_gradient/core/bhp_mesh.dart`

```dart
class BHPMesh {
  late Float64List vertexData;      // [x,y,r,g,b,u,v] per vertex
  late List<int> indexData;
  
  final Map2D<ControlPoint> controlPoints = Map2D(3, 3);
  
  int subdivisions = 50;
  int vertexWidth = 0;
  int vertexHeight = 0;
  
  // Pre-allocated temps for performance
  late final Matrix4 tempX, tempY, tempR, tempG, tempB;
  late final Matrix4 tempXAcc, tempYAcc, tempRAcc, tempGAcc, tempBAcc;
  late final Vector4 tempUx, tempUy, tempUr, tempUg, tempUb;
  
  void updateMesh() { ... }
  void resizeControlPoints(int w, int h) { ... }
  ControlPoint getControlPoint(int x, int y) { ... }
}

class Map2D<T> {
  List<T> _data;
  int _width = 0;
  int _height = 0;
  
  void set(int x, int y, T value) { ... }
  T get(int x, int y) { ... }
}
```

- [ ] Implement Map2D container
- [ ] Implement vertex data storage (7 floats per vertex)
- [ ] Implement resizeControlPoints with default initialization
- [ ] Pre-allocate temporary matrices

#### 2.2 Coefficient Matrix Functions (16 hours)
**File**: `lib/mesh_gradient/core/bhp_mesh.dart` (continued)

```dart
void _meshCoefficients(
  ControlPoint p00, p01, p10, p11,
  int axis,  // 0=x, 1=y
  Matrix4 output
) {
  // Extract components based on axis
  // Fill output matrix per AMLL spec
}

void _colorCoefficients(
  ControlPoint p00, p01, p10, p11,
  int channel,  // 0=r, 1=g, 2=b
  Matrix4 output
) {
  // Fill color matrix (simpler, no tangents)
}
```

- [ ] Implement _meshCoefficients matching AMLL source (lines 419-449)
- [ ] Implement _colorCoefficients matching AMLL source (lines 451-472)
- [ ] Test with hardcoded control points
- [ ] Verify matrix values visually

#### 2.3 Vertex Generation Algorithm (28 hours)
**File**: `lib/mesh_gradient/core/bhp_mesh.dart` (continued)

```dart
void updateMesh() {
  // 1. Resize if needed
  if (...) {
    super.resize(...);
  }
  
  // 2. Pre-compute basis powers
  final normPowers = Float64List(subdivisions * 4);
  for (int i = 0; i < subdivisions; i++) {
    final norm = i / (subdivisions - 1);
    normPowers[i*4]   = norm * norm * norm;
    normPowers[i*4+1] = norm * norm;
    normPowers[i*4+2] = norm;
    normPowers[i*4+3] = 1.0;
  }
  
  // 3. For each patch
  for (int x = 0; x < controlPoints.width - 1; x++) {
    for (int y = 0; y < controlPoints.height - 1; y++) {
      // Get 4 corner control points
      // Compute coefficient matrices
      // Pre-compute accumulation matrices
      
      // Generate vertices
      for (int u = 0; u < subdivisions; u++) {
        for (int v = 0; v < subdivisions; v++) {
          // Evaluate surface at (u,v)
          // Set vertex data
        }
      }
    }
  }
}
```

- [ ] Implement complete updateMesh() algorithm
- [ ] Pre-compute u and v powers (critical optimization)
- [ ] Implement basis transformation: `U = U_basis · Acc`
- [ ] Implement final dot product: `result = V_basis · U_transformed`
- [ ] Test with 3x3 control points, 10 subdivisions

#### 2.4 Integration & Testing (16 hours)
- [ ] Write integration tests for full mesh generation
- [ ] Test with all 5 AMLL presets
- [ ] Profile mesh generation performance (target: <5ms)
- [ ] Optimize hot paths (avoid allocations)
- [ ] Generate sample vertex data and compare to reference

#### 2.5 Validation Against AMLL (12 hours)
- [ ] Compare generated vertex data with AMLL source
- [ ] Test subdivision level variations (10, 25, 50)
- [ ] Test control point grid sizes (3x3, 4x4, 5x5, 6x6)
- [ ] Performance profiling at different scales
- [ ] Document performance characteristics

**Success Criteria**:
- ✅ Mesh generation produces valid vertex data
- ✅ Matches AMLL reference within floating-point precision
- ✅ <5ms per frame at 50 subdivisions, 3x3 control points
- ✅ All unit tests pass
- ✅ Zero memory allocations in updateMesh() per frame

---

### PHASE 3: IMAGE PROCESSING & PRESETS (Week 2) - 32 hours

**Goal**: Album art processing and control point presets  
**Artifacts**: Image processor, all 5 presets implemented

#### 3.1 Image Processing Pipeline (12 hours)
**File**: `lib/mesh_gradient/utils/image_processor.dart`

```dart
class ImageProcessor {
  /// Resize image to 32x32
  static Future<ui.Image> resizeAlbumArt(
    ui.Image source,
    {int targetSize = 32}
  ) async { ... }
  
  /// Apply color transformations
  static void applyColorTransform(ByteData pixels) {
    // Contrast 0.4, Saturate 3.0, Contrast 1.7, Brightness 0.75
  }
  
  /// Apply Gaussian blur
  static void gaussianBlur(
    ByteData pixels,
    int width, int height,
    {int radius = 2, int iterations = 4}
  ) { ... }
  
  /// Full pipeline: resize → transform → blur
  static Future<ByteData> processAlbumArt(ui.Image source) async { ... }
}
```

- [ ] Implement resize algorithm (canvas-based)
- [ ] Implement exact color transformations from AMLL (index.ts:1226-1255)
- [ ] Implement Gaussian blur with configurable radius/iterations
- [ ] Test with sample album art
- [ ] Verify output visually matches AMLL

#### 3.2 Preset Control Points (12 hours)
**File**: `lib/mesh_gradient/utils/cp_presets.dart`

From AMLL cp-presets.ts - 5 main presets:
1. 5x5 grid - complex organic
2. 4x4 grid - landscape orientation (simple)
3. 4x4 grid - landscape orientation (complex)
4. 5x5 grid - portrait orientation (complex, procedural-like)
5. 5x5 grid - portrait orientation (organic)

```dart
class ControlPointPreset {
  final int width, height;
  final List<ControlPointConf> conf;
  
  const ControlPointPreset({...});
}

const List<ControlPointPreset> CONTROL_POINT_PRESETS = [
  preset5x5_1,   // From AMLL lines 40-66
  preset4x4_1,   // From AMLL lines 68-85
  preset4x4_2,   // From AMLL lines 86-103
  preset5x5_2,   // From AMLL lines 104-130
  preset5x5_3,   // From AMLL lines 131-157
  preset5x5_4,   // From AMLL lines 158-185
];
```

- [ ] Convert all 5+ presets from AMLL cp-presets.ts (exactly)
- [ ] Create ControlPointConf and ControlPointPreset classes
- [ ] Implement preset selection (random or by index)
- [ ] Write tests to verify all presets load correctly

#### 3.3 Procedural Generation (8 hours)
**File**: `lib/mesh_gradient/utils/cp_presets.dart` (continued)

From AMLL cp-generate.ts:
```dart
ControlPointPreset generateControlPoints(
  int width, int height,
  {double variationFraction = 0.5,
   double normalOffset = 0.3,
   double blendFactor = 0.8,
   int smoothIters = 3,
   double smoothFactor = 0.3}
) {
  // 1. Create base grid
  // 2. Add perturbations (Perlin-like noise)
  // 3. Smooth with kernel filter
  // Return preset
}
```

- [ ] Implement Perlin-like noise function
- [ ] Implement smoothness filter (Gaussian kernel)
- [ ] Implement gradient computation for noise
- [ ] Test generation produces valid presets
- [ ] Create 20-30 random presets for testing

#### 3.4 Testing & Validation (4 hours)
- [ ] Unit tests for image processing
- [ ] Unit tests for preset loading
- [ ] Visual validation of processed images
- [ ] Performance profile: image processing <100ms total

**Success Criteria**:
- ✅ All 5 presets correctly implemented
- ✅ Image processing matches AMLL output
- ✅ Procedural generation produces valid presets
- ✅ <100ms for full image processing pipeline

---

### PHASE 4: RENDERING SYSTEM (Week 3) - 48 hours

**Goal**: OpenGL/Canvas rendering system with state management  
**Artifacts**: Complete rendering pipeline, widget wrapper

#### 4.1 State Management (12 hours)
**File**: `lib/mesh_gradient/core/mesh_state.dart`

```dart
class MeshState {
  final BHPMesh mesh;
  final ui.Image textureImage;
  double alpha = 0.0;
  
  void dispose() { ... }
}

class MeshGradientRenderer extends ChangeNotifier {
  final List<MeshState> meshStates = [];
  bool isTransitioningOut = false;
  
  double frameTime = 0;
  double smoothedVolume = 0;
  double flowSpeed = 1.0;
  
  void addMeshState(MeshState state) { ... }
  void transitionOut(double deltaTime) { ... }
  void transitionIn(double deltaTime) { ... }
  void update(double deltaTime) { ... }
}
```

- [ ] Implement MeshState class
- [ ] Implement MeshGradientRenderer orchestrator
- [ ] Implement state transition logic (fade in/out)
- [ ] Implement alpha blending with easeInOutSine
- [ ] Implement resource disposal

#### 4.2 Canvas Rendering (20 hours)
**File**: `lib/mesh_gradient/core/mesh_gradient_renderer.dart`

```dart
class MeshGradientRenderer extends ChangeNotifier {
  // Two-pass rendering:
  // Pass 1: Render mesh to intermediate texture/buffer
  // Pass 2: Composite to screen with alpha blending
  
  void render(Canvas canvas, Size size) {
    // Update time accumulation
    // For each mesh state:
    //   - Render mesh
    //   - Apply shader effects
    //   - Blend with easeInOutSine alpha
  }
  
  void _renderMeshState(
    Canvas canvas,
    MeshState state,
    Size size,
    double alpha,
  ) {
    // Draw mesh geometry
    // Apply album texture
    // Apply shader effects (volume rotation, vignetting, etc.)
  }
}
```

- [ ] Implement mesh rendering to canvas
- [ ] Implement vertex painting (triangles from index data)
- [ ] Implement per-vertex color application
- [ ] Implement UV coordinate mapping to album texture
- [ ] Implement volume-based UV rotation shader effect
- [ ] Implement vignetting effect
- [ ] Implement dithering for banding prevention
- [ ] Implement alpha blending for state transitions
- [ ] Test rendering performance

#### 4.3 Shader Integration (10 hours)
**File**: `assets/shaders/mesh_gradient.frag`

Create fragment shader (or use Canvas-based approach):

```glsl
precision highp float;

varying vec3 v_color;
varying vec2 v_uv;

uniform sampler2D u_texture;
uniform float u_time;
uniform float u_volume;
uniform float u_alpha;

// Implement:
// - Gradient noise (dithering)
// - UV rotation based on time + volume
// - Vignetting
// - Volume dampening
```

- [ ] Create shader file (or implement in Canvas)
- [ ] Verify shader compiles (if used)
- [ ] Test shader effects visually
- [ ] Profile shader performance

#### 4.4 Widget Wrapper (6 hours)
**File**: `lib/mesh_gradient/widgets/mesh_gradient_widget.dart`

```dart
class MeshGradientWidget extends StatefulWidget {
  final ui.Image? albumArt;
  final double volume;
  final bool isPlaying;
  final Listenable repaint;
  
  @override
  State<MeshGradientWidget> createState() => _MeshGradientWidgetState();
}

class _MeshGradientWidgetState extends State<MeshGradientWidget> {
  late MeshGradientRenderer _renderer;
  
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _MeshGradientPainter(_renderer),
      child: const SizedBox.expand(),
    );
  }
}
```

- [ ] Implement widget lifecycle management
- [ ] Implement dependency updates
- [ ] Implement resource cleanup
- [ ] Test widget in Flutter app

**Success Criteria**:
- ✅ Rendering produces correct visual output
- ✅ State transitions smooth with easeInOutSine
- ✅ Performance target: 60 FPS on desktop, 30 FPS on mobile
- ✅ All resources properly disposed
- ✅ Widget integrates cleanly with Flutter

---

### PHASE 5: PURE MUSIC INTEGRATION (Week 3-4) - 40 hours

**Goal**: Integrate with existing Pure Music architecture  
**Artifacts**: Working integration, Now Playing page with mesh gradient

#### 5.1 Audio Pipeline Connection (12 hours)
**Files Modified**:
- `lib/play_service/playback_service.dart` - Add volume stream
- `lib/play_service/play_service.dart` - Add accessor
- `lib/mesh_gradient/core/mesh_gradient_renderer.dart` - Subscribe

```dart
// In PlaybackService
Stream<double> get volumeStream {
  // Already exists, but expose if needed
  return _player.volumeStream.map((v) => v / 10.0);
}

// In MeshGradientRenderer
void subscribeToAudioData(PlaybackService playService) {
  // Volume updates
  _volumeStream = playService.volumeStream.listen((volume) {
    setVolume(volume);
  });
  
  // State updates
  _stateStream = playService.playerStateStream.listen((state) {
    if (state == PlayerState.playing) resume();
    else pause();
  });
  
  // Spectrum (if available)
  if (playService.spectrumStream != null) {
    _spectrumStream = playService.spectrumStream!.listen((data) {
      updateFrequencyData(data);
    });
  }
}
```

- [ ] Expose volume stream from PlaybackService
- [ ] Expose playback state stream
- [ ] Expose spectrum frequency data (if available)
- [ ] Implement audio subscription in MeshGradientRenderer
- [ ] Test audio data flows correctly

#### 5.2 Album Art Integration (12 hours)
**Files Modified**:
- `lib/amll_background/core/amll_background_render.dart` - Already exists
- `lib/page/now_playing_page/now_playing_page.dart` - Use existing image

```dart
// In AmllBackgroundRender (already exists)
Future<void> setImage(ui.Image? image) async {
  _currentImage = image;
  // Notify listeners (MeshGradient widget)
  notifyListeners();
}

// In NowPlayingPage
void _onAlbumChange() {
  final image = _amllBackgroundRender.currentImage;
  if (image != null) {
    _meshGradient.setAlbum(image);
  }
}
```

- [ ] Hook into existing AmllBackgroundRender
- [ ] Subscribe to image changes
- [ ] Trigger mesh generation on new album
- [ ] Extract dominant color from album art
- [ ] Pass color to shader/renderer

#### 5.3 Theme Integration (8 hours)
**Files Modified**:
- `lib/page/now_playing_page/now_playing_page.dart` - Use theme colors
- `lib/mesh_gradient/core/mesh_gradient_renderer.dart` - Accept colors

```dart
// In MeshGradientRenderer
void setColors(Color? dominant, Color? accent) {
  // Use in shader for effects
  // Update mesh coloring if procedural
}

// In NowPlayingPage
final colorScheme = Theme.of(context).colorScheme;
final dominantColor = _extractDominantColor(_albumArt);

_meshGradient.setColors(dominantColor, colorScheme.primary);
```

- [ ] Extract dominant color from album art
- [ ] Use Material You theme colors
- [ ] Apply color scheme to mesh/shader
- [ ] Test with different themes

#### 5.4 Now Playing Page Integration (8 hours)
**File Modified**: `lib/page/now_playing_page/now_playing_page.dart`

Replace or augment existing shader background:

```dart
// Current code uses NowPlayingShaderBackground
// Option 1: Replace entirely
@override
Widget _buildBackground(BuildContext context) {
  return MeshGradientWidget(
    albumArt: _amllBackgroundRender.currentImage,
    volume: _currentVolume,
    isPlaying: _isPlaying,
    repaint: _animationController,
  );
}

// Option 2: Stack both for layered effects
@override
Widget _buildBackground(BuildContext context) {
  return Stack(
    children: [
      MeshGradientWidget(...),
      NowPlayingShaderBackground(...),  // Overlay
    ],
  );
}
```

- [ ] Update Now Playing page to use MeshGradientWidget
- [ ] Connect animation controller
- [ ] Test visual appearance
- [ ] Verify performance on real device

#### 5.5 Testing & Refinement (4 hours)
- [ ] Integration tests with audio pipeline
- [ ] Test state transitions with music playback
- [ ] Test theme changes
- [ ] Test album art changes
- [ ] Verify memory cleanup

**Success Criteria**:
- ✅ Mesh gradient renders behind Now Playing page
- ✅ Responds to volume changes in real-time
- ✅ Transitions smoothly when album changes
- ✅ Uses theme colors appropriately
- ✅ No memory leaks

---

### PHASE 6: OPTIMIZATION & POLISH (Week 4-5) - 48 hours

**Goal**: Performance optimization and visual polish  
**Artifacts**: Sub-5ms mesh update time, smooth 60 FPS

#### 6.1 Performance Profiling (12 hours)
- [ ] Profile mesh generation time (target: <5ms)
- [ ] Profile rendering time (target: <10ms)
- [ ] Profile memory usage
- [ ] Identify hot paths
- [ ] Memory allocation tracking

**Tools**:
```dart
final sw = Stopwatch()..start();
// Code to profile
sw.stop();
print('Elapsed: ${sw.elapsedMilliseconds}ms');
```

#### 6.2 CPU Optimizations (16 hours)
- [ ] Eliminate allocations in hot loops
- [ ] Cache frequently-computed values
- [ ] Use Float64List instead of List<double>
- [ ] Inline critical operations
- [ ] Reduce matrix operations per frame

```dart
// Before (allocates each frame)
for (int i = 0; i < n; i++) {
  final temp = Matrix4.zero();  // ❌ Allocates n times
  temp.multiply(a);
}

// After (reuses allocation)
final temp = Matrix4.zero();
for (int i = 0; i < n; i++) {
  temp.copy(someValue);  // ✅ No allocation
  temp.multiply(a);
}
```

- [ ] Profile each optimization
- [ ] Verify visual output unchanged
- [ ] Document performance improvements

#### 6.3 GPU Optimizations (12 hours)
If using Flutter shaders:
- [ ] Reduce shader precision where possible
- [ ] Pre-compute shader constants
- [ ] Optimize UV rotation calculation
- [ ] Reduce texture lookups

#### 6.4 Adaptive Quality (8 hours)
```dart
class AdaptiveQuality {
  static int getSubdivisions(DeviceInfo device) {
    if (device.gpuTier >= 4) return 50;   // Desktop premium
    else if (device.gpuTier >= 2) return 35;   // Mid-range
    else return 20;                        // Mobile/low-end
  }
  
  static int getFrameSkip(int currentFPS, int targetFPS) {
    if (currentFPS < targetFPS * 0.8) {
      return (targetFPS / currentFPS).ceil();  // Skip frames
    }
    return 1;  // Render every frame
  }
}
```

- [ ] Implement device detection
- [ ] Implement adaptive subdivision levels
- [ ] Implement frame skipping
- [ ] Test on different device tiers

#### 6.5 Visual Polish (8 hours)
- [ ] Fine-tune color transformations
- [ ] Adjust vignetting intensity
- [ ] Test dithering effectiveness
- [ ] Verify shader effects
- [ ] Compare to AMLL reference
- [ ] Create screenshot comparisons

**Success Criteria**:
- ✅ Mesh update: <5ms (50 subdivisions, 3x3 control points)
- ✅ Frame time: <16ms at 60 FPS
- ✅ Memory: <10MB for mesh state
- ✅ Visual quality matches AMLL reference
- ✅ Smooth transitions and animations

---

### PHASE 7: DOCUMENTATION & RELEASE (Week 5-6) - 24 hours

**Goal**: Complete documentation and production-ready code  
**Artifacts**: Full documentation, code examples, user guide

#### 7.1 Code Documentation (8 hours)
- [ ] Document all public APIs with dartdoc comments
- [ ] Document algorithm with inline comments
- [ ] Create architecture diagrams (as text/markdown)
- [ ] Document pre-computed matrices and optimizations
- [ ] Add performance notes to critical functions

```dart
/// Evaluates the Bicubic Hermite Patch surface at parameters (u, v).
///
/// This function implements the core surface evaluation algorithm:
/// S(u,v) = [u³ u² u 1] · H^T · M · H · [v³ v² v 1]^T
///
/// The result is a smooth 2D point on the surface with per-vertex color.
/// Pre-computation of the accumulation matrix Acc = H^T · M · H
/// reduces this from 4×4 matrix multiplications to simple dot products.
///
/// Performance: O(subdivisions²) for a single patch
/// Memory: Pre-allocates all temporary matrices to avoid GC pressure
///
/// Returns: Vertex data as [x, y, r, g, b, u, v] arrays
Vector4 evaluateSurfacePoint(double u, double v, Matrix4 accumulationMatrix) {
  // Implementation...
}
```

#### 7.2 User Documentation (8 hours)
Create `MESH_GRADIENT_USER_GUIDE.md`:
- Quick start guide
- Configuration options
- Performance tuning tips
- Troubleshooting guide
- FAQ

#### 7.3 Architecture Document (4 hours)
Create `MESH_GRADIENT_ARCHITECTURE.md`:
- System overview
- Component relationships
- Data flow diagrams (as text)
- Extension points

#### 7.4 Code Review & Testing (4 hours)
- [ ] Self-review all code
- [ ] Fix any code style issues
- [ ] Run full test suite
- [ ] Check coverage (target: >85%)
- [ ] Lint verification

**Success Criteria**:
- ✅ All code well-documented
- ✅ Public APIs have dartdoc comments
- ✅ Architecture clearly explained
- ✅ User guide complete
- ✅ No lint warnings

---

## INTEGRATION CHECKLIST

### Files to Create
- [ ] `lib/mesh_gradient/core/hermite_math.dart`
- [ ] `lib/mesh_gradient/core/control_point.dart`
- [ ] `lib/mesh_gradient/core/bhp_mesh.dart`
- [ ] `lib/mesh_gradient/core/mesh_state.dart`
- [ ] `lib/mesh_gradient/core/mesh_gradient_renderer.dart`
- [ ] `lib/mesh_gradient/models/mesh_config.dart`
- [ ] `lib/mesh_gradient/utils/image_processor.dart`
- [ ] `lib/mesh_gradient/utils/cp_presets.dart`
- [ ] `lib/mesh_gradient/widgets/mesh_gradient_widget.dart`
- [ ] `lib/mesh_gradient/exports.dart`
- [ ] `test/mesh_gradient/hermite_math_test.dart`
- [ ] `test/mesh_gradient/bhp_mesh_test.dart`
- [ ] `assets/shaders/mesh_gradient.frag` (optional)

### Files to Modify
- [ ] `pubspec.yaml` - Add vector_math dependency
- [ ] `lib/page/now_playing_page/now_playing_page.dart` - Integrate widget
- [ ] `lib/amll_background/core/amll_background_render.dart` - Connect image
- [ ] `lib/play_service/playback_service.dart` - Expose streams
- [ ] `lib/play_service/play_service.dart` - Add accessors

### Dependencies to Add
```yaml
dependencies:
  vector_math: ^2.1.4  # Already likely present in Pure Music
```

### Build Commands
```bash
# Analyze
flutter analyze

# Run tests
flutter test

# Build
flutter build windows --release

# Run
flutter run -d windows
```

---

## TIMELINE SUMMARY

| Phase | Duration | Key Deliverables | Status |
|-------|----------|------------------|--------|
| 1: Foundation | Week 1 | HermiteMath, ControlPoint, tests | 🔷 Ready |
| 2: Mesh Gen | Week 1-2 | BHPMesh, algorithm, validation | 🔷 Ready |
| 3: Image/Presets | Week 2 | ImageProcessor, 5 presets | 🔷 Ready |
| 4: Rendering | Week 3 | Renderer, widget, shader | 🔷 Ready |
| 5: Integration | Week 3-4 | Pure Music hookup, Now Playing | ⏳ Next |
| 6: Optimization | Week 4-5 | Perf tuning, adaptive quality | ⏳ Next |
| 7: Documentation | Week 5-6 | Complete docs, release | ⏳ Final |

**Total: 4-6 weeks, ~260 hours of development**

---

## REFERENCE MATERIALS

### Source Code References
- AMLL Main: `.trae/good/applemusic-like-lyrics/packages/core/src/bg-render/mesh-renderer/index.ts`
- Presets: `.trae/good/applemusic-like-lyrics/packages/core/src/bg-render/mesh-renderer/cp-presets.ts`
- Generation: `.trae/good/applemusic-like-lyrics/packages/core/src/bg-render/mesh-renderer/cp-generate.ts`
- Shader: `.trae/good/applemusic-like-lyrics/packages/core/src/bg-render/mesh-renderer/mesh.frag.glsl`

### Documentation Generated
- `AMLL_MESH_GRADIENT_COMPLETE_GUIDE.md` - Full technical guide
- `AMLL_QUICK_REFERENCE.md` - Quick reference & snippets
- `Pure-music-integration-roadmap.md` - This document

### External Resources
- [flutter-vector-math](https://github.com/google/vector_math.dart)
- [Flutter CustomPaint](https://api.flutter.dev/flutter/rendering/CustomPaint-class.html)
- [Bicubic Hermite Wikipedia](https://en.wikipedia.org/wiki/Hermite_interpolation)
- [Moving Parts Blog](https://movingparts.io/gradient-meshes)

