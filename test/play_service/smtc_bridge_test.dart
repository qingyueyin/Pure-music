import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/play_service/smtc_bridge.dart';

void main() {
  test('rapid timeline updates keep only the latest pending value', () async {
    final backend = _FakeSmtcBackend();
    final bridge = SmtcBridge.withBackend(backend);

    for (var progress = 0; progress < 100; progress++) {
      unawaited(bridge.updateTimeProperties(progress));
    }
    await bridge.flush();

    expect(backend.progressUpdates, <int>[99]);
  });

  test('display and state updates preserve cross-stack order', () async {
    final backend = _FakeSmtcBackend();
    final bridge = SmtcBridge.withBackend(backend);

    unawaited(bridge.updateDisplay(
      title: 'title',
      artist: 'artist',
      album: 'album',
      duration: 1000,
      path: 'track.wav',
    ));
    unawaited(bridge.updateState(SMTCState.playing));
    await bridge.flush();

    expect(backend.operations, <String>['display:title', 'state:playing']);
  });

  test('updates arriving during a native call are conflated', () async {
    final backend = _FakeSmtcBackend();
    final firstCall = Completer<void>();
    backend.timelineGate = firstCall.future;
    final bridge = SmtcBridge.withBackend(backend);

    unawaited(bridge.updateTimeProperties(10));
    await backend.firstTimelineCall.future;
    for (var progress = 11; progress <= 40; progress++) {
      unawaited(bridge.updateTimeProperties(progress));
    }
    firstCall.complete();
    await bridge.flush();

    expect(backend.progressUpdates, <int>[10, 40]);
  });

  test('close releases the backend and ignores later work', () async {
    final backend = _FakeSmtcBackend();
    final bridge = SmtcBridge.withBackend(backend);

    await bridge.close();
    await bridge.updateState(SMTCState.playing);

    expect(backend.closed, isTrue);
    expect(backend.operations, <String>['close']);
  });
}

class _FakeSmtcBackend implements SmtcBackend {
  final operations = <String>[];
  final progressUpdates = <int>[];
  final firstTimelineCall = Completer<void>();
  Future<void>? timelineGate;
  bool closed = false;

  @override
  Stream<SMTCControlEvent> get controlEvents => const Stream.empty();

  @override
  Stream<int> get positionChangeEvents => const Stream.empty();

  @override
  Future<void> clearDisplay() async {
    operations.add('clear');
  }

  @override
  Future<void> refreshDisplay() async {
    operations.add('refresh');
  }

  @override
  Future<void> close() async {
    closed = true;
    operations.add('close');
  }

  @override
  Future<void> updateDisplay({
    required String title,
    required String artist,
    required String album,
    required int duration,
    required String path,
  }) async {
    operations.add('display:$title');
  }

  @override
  Future<void> updateState(SMTCState state) async {
    operations.add('state:${state.name}');
  }

  @override
  Future<void> updateTimeProperties(int progress) async {
    progressUpdates.add(progress);
    if (!firstTimelineCall.isCompleted) firstTimelineCall.complete();
    await timelineGate;
    timelineGate = null;
  }
}
