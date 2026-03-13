// ignore_for_file: public_member_api_docs

/// Mesh Gradient module - Apple Music-like Lyrics (AMLL) mesh gradient rendering.
///
/// This module implements bicubic Hermite patch (BHP) surface interpolation for
/// creating smooth, deformable mesh gradients similar to Apple Music lyrics interface.
/// 
/// Core components:
/// - [HermiteMath]: Pre-computed matrices and batch vertex evaluation
/// - [ControlPoint]: Individual control points with tangent information
/// - [Map2D]: 2D grid container for organizing control points
library;

export 'core/hermite_math.dart';
export 'core/control_point.dart';
