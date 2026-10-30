import 'dart:async';

class PlaybackSongChangeTasks {
  int _token = 0;
  Timer? _metadataTimer;
  Timer? _prefetchTimer;
  Timer? _persistTimer;
  Timer? _cleanupTimer;

  int begin() => ++_token;

  bool isCurrent(int token) => token == _token;

  void schedule({
    required int token,
    required void Function() onMetadata,
    required void Function() onPrefetch,
    required void Function() onPersist,
    required void Function() onCleanup,
  }) {
    cancel();
    _metadataTimer = Timer(
      const Duration(milliseconds: 96),
      () => _run(token, _metadataTimer, onMetadata),
    );
    _prefetchTimer = Timer(
      const Duration(milliseconds: 220),
      () => _run(token, _prefetchTimer, onPrefetch),
    );
    _persistTimer = Timer(
      const Duration(milliseconds: 650),
      () => _run(token, _persistTimer, onPersist),
    );
    _cleanupTimer = Timer(
      const Duration(milliseconds: 1800),
      () => _run(token, _cleanupTimer, onCleanup),
    );
  }

  void cancel() {
    _metadataTimer?.cancel();
    _metadataTimer = null;
    _prefetchTimer?.cancel();
    _prefetchTimer = null;
    _persistTimer?.cancel();
    _persistTimer = null;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
  }

  void _run(int token, Timer? timer, void Function() callback) {
    if (identical(timer, _metadataTimer)) _metadataTimer = null;
    if (identical(timer, _prefetchTimer)) _prefetchTimer = null;
    if (identical(timer, _persistTimer)) _persistTimer = null;
    if (identical(timer, _cleanupTimer)) _cleanupTimer = null;
    if (!isCurrent(token)) return;
    callback();
  }
}
