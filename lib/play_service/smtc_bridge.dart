import 'dart:async';

import 'package:pure_music/core/utils.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';

abstract interface class SmtcBackend {
  Stream<SMTCControlEvent> get controlEvents;
  Stream<int> get positionChangeEvents;

  Future<void> updateDisplay({
    required String title,
    required String artist,
    required String album,
    required int duration,
    required String path,
  });
  Future<void> updateState(SMTCState state);
  Future<void> updateTimeProperties(int progress);
  Future<void> clearDisplay();
  Future<void> close();
}

class NativeSmtcBackend implements SmtcBackend {
  NativeSmtcBackend() : _native = SmtcFlutter();

  final SmtcFlutter _native;

  @override
  Stream<SMTCControlEvent> get controlEvents =>
      _native.subscribeToControlEvents();

  @override
  Stream<int> get positionChangeEvents => _native
      .subscribeToPositionChangeEvents()
      .map((position) => position.toInt());

  @override
  Future<void> updateDisplay({
    required String title,
    required String artist,
    required String album,
    required int duration,
    required String path,
  }) {
    return _native.updateDisplay(
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      path: path,
    );
  }

  @override
  Future<void> updateState(SMTCState state) =>
      _native.updateState(state: state);

  @override
  Future<void> updateTimeProperties(int progress) =>
      _native.updateTimeProperties(progress: progress);

  @override
  Future<void> clearDisplay() => _native.clearDisplay();

  @override
  Future<void> close() => _native.close();
}

class SmtcBridge {
  SmtcBridge.withBackend(this._backend);

  factory SmtcBridge.create() {
    try {
      return SmtcBridge.withBackend(NativeSmtcBackend());
    } catch (error, stackTrace) {
      logger.w('[smtc] initialization failed: $error\n$stackTrace');
      return SmtcBridge.withBackend(null);
    }
  }

  final SmtcBackend? _backend;
  static const _operationTimeout = Duration(seconds: 2);
  Future<void> _operationChain = Future<void>.value();
  _SmtcDisplayUpdate? _pendingDisplay;
  SMTCState? _pendingState;
  int? _pendingProgress;
  bool _displayDrainQueued = false;
  bool _stateDrainQueued = false;
  bool _timelineDrainQueued = false;
  bool _closed = false;

  Stream<SMTCControlEvent> get controlEvents =>
      _backend?.controlEvents ?? const Stream<SMTCControlEvent>.empty();

  Stream<int> get positionChangeEvents =>
      _backend?.positionChangeEvents ?? const Stream<int>.empty();

  Future<void> updateDisplay({
    required String title,
    required String artist,
    required String album,
    required int duration,
    required String path,
  }) {
    if (_closed || _backend == null) return Future<void>.value();
    _pendingDisplay = _SmtcDisplayUpdate(
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      path: path,
    );
    if (_displayDrainQueued) return _operationChain;
    _displayDrainQueued = true;
    return _enqueue((backend) async {
      try {
        while (!_closed) {
          final update = _pendingDisplay;
          _pendingDisplay = null;
          if (update == null) break;
          await backend.updateDisplay(
            title: update.title,
            artist: update.artist,
            album: update.album,
            duration: update.duration,
            path: update.path,
          );
        }
      } finally {
        _displayDrainQueued = false;
      }
    }, 'update display');
  }

  Future<void> updateState(SMTCState state) {
    if (_closed || _backend == null) return Future<void>.value();
    _pendingState = state;
    if (_stateDrainQueued) return _operationChain;
    _stateDrainQueued = true;
    return _enqueue((backend) async {
      try {
        while (!_closed) {
          final state = _pendingState;
          _pendingState = null;
          if (state == null) break;
          await backend.updateState(state);
        }
      } finally {
        _stateDrainQueued = false;
      }
    }, 'update state');
  }

  Future<void> updateTimeProperties(int progress) {
    if (_closed || _backend == null) return Future<void>.value();
    _pendingProgress = progress;
    if (_timelineDrainQueued) return _operationChain;
    _timelineDrainQueued = true;
    return _enqueue((backend) async {
      try {
        while (!_closed) {
          final progress = _pendingProgress;
          _pendingProgress = null;
          if (progress == null) break;
          await backend.updateTimeProperties(progress);
        }
      } finally {
        _timelineDrainQueued = false;
      }
    }, 'update timeline');
  }

  Future<void> clearDisplay() {
    if (_closed || _backend == null) return Future<void>.value();
    _pendingDisplay = null;
    _pendingState = null;
    _pendingProgress = null;
    return _enqueue((backend) => backend.clearDisplay(), 'clear display');
  }

  Future<void> flush() => _operationChain;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pendingDisplay = null;
    _pendingState = null;
    _pendingProgress = null;
    await _operationChain;
    final backend = _backend;
    if (backend == null) return;
    try {
      await backend.close().timeout(const Duration(milliseconds: 750));
    } catch (error, stackTrace) {
      logger.w('[smtc] close failed: $error\n$stackTrace');
    }
  }

  Future<void> _enqueue(
    Future<void> Function(SmtcBackend backend) operation,
    String name,
  ) {
    final backend = _backend;
    if (_closed || backend == null) return Future<void>.value();
    _operationChain = _operationChain.then((_) async {
      try {
        await operation(backend).timeout(_operationTimeout);
      } catch (error, stackTrace) {
        logger.w('[smtc] $name failed: $error\n$stackTrace');
      }
    });
    return _operationChain;
  }
}

class _SmtcDisplayUpdate {
  const _SmtcDisplayUpdate({
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.path,
  });

  final String title;
  final String artist;
  final String album;
  final int duration;
  final String path;
}
