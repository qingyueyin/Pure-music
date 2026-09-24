import 'package:pure_music/library/audio_library.dart';

class SmartSortOptions {
  const SmartSortOptions({
    required this.tracks,
    this.climaxPosition = 0.82,
    this.contrast = 0.85,
    this.takeCount = 0,
    this.smoothness = 0.5,
    this.outroStyle = 0,
    this.taste = 0,
    this.onProgress,
    this.isCancelled,
  });

  final List<Audio> tracks;
  final double climaxPosition;
  final double contrast;
  final int takeCount;
  final double smoothness;
  final int outroStyle;
  final int taste;
  final void Function(int done, int total)? onProgress;
  final bool Function()? isCancelled;
}
