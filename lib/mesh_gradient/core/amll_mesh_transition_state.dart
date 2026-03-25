import 'package:flutter/foundation.dart';

@immutable
class MeshGradientSceneSnapshot<T> {
  final int signature;
  final T payload;

  const MeshGradientSceneSnapshot({
    required this.signature,
    required this.payload,
  });
}

@immutable
class MeshGradientTransitionState<T> {
  final MeshGradientSceneSnapshot<T>? previous;
  final MeshGradientSceneSnapshot<T>? current;

  const MeshGradientTransitionState({
    this.previous,
    this.current,
  });

  const MeshGradientTransitionState.empty() : previous = null, current = null;

  bool get hasTransition => previous != null && current != null;

  MeshGradientTransitionState<T> push(MeshGradientSceneSnapshot<T> next) {
    if (current?.signature == next.signature) {
      return MeshGradientTransitionState(previous: previous, current: next);
    }
    return MeshGradientTransitionState(previous: current, current: next);
  }

  MeshGradientTransitionState<T> settle() {
    return MeshGradientTransitionState(previous: null, current: current);
  }
}
