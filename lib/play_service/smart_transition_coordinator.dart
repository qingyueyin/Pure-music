import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/native/rust/api/smart_transition.dart' as native;
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';

final class SmartTransitionTarget {
  const SmartTransitionTarget({
    required this.playlistRevision,
    required this.outgoingIndex,
    required this.incomingIndex,
    required this.outgoing,
    required this.incoming,
    required this.isGaplessCandidate,
    required this.userSpeed,
    required this.pitch,
    required this.outgoingReplayGainDb,
  });

  final int playlistRevision;
  final int outgoingIndex;
  final int incomingIndex;
  final Audio outgoing;
  final Audio incoming;
  final bool isGaplessCandidate;
  final double userSpeed;
  final double pitch;
  final double? outgoingReplayGainDb;
}

final class SmartTransitionCommit {
  const SmartTransitionCommit({
    required this.transitionId,
    required this.target,
    required this.transition,
  });

  final int transitionId;
  final SmartTransitionTarget target;
  final GaplessTransition transition;
}

final class _PendingSmartTransition {
  _PendingSmartTransition({
    required this.transitionId,
    required this.generation,
    required this.sourceGeneration,
    required this.target,
  });

  final int transitionId;
  final int generation;
  final int sourceGeneration;
  final SmartTransitionTarget target;
  int? analysisJobId;
  String? outgoingProfileJson;
  String? incomingProfileJson;
  Map<String, Object?>? plan;
  SmartTransitionPreparation? preparation;
  bool windowOpen = false;
  bool incomingAnalysisStarted = false;
  bool transferred = false;
  bool reserved = false;
  bool committed = false;
  bool terminal = false;
  int lastEventSequence = 0;
  int reconcileAttempts = 0;
  double lastPositionSeconds = 0;
  Timer? startRecoveryTimer;
  Timer? completionRecoveryTimer;

  void cancelTimers() {
    startRecoveryTimer?.cancel();
    startRecoveryTimer = null;
    completionRecoveryTimer?.cancel();
    completionRecoveryTimer = null;
  }
}

final class SmartTransitionCoordinator {
  SmartTransitionCoordinator({
    required BassPlayer player,
    required Future<String> Function() readLibraryRoot,
    required SmartTransitionTarget? Function() readTarget,
    required bool Function(SmartTransitionTarget target) validateTarget,
    required int Function() nextTransitionId,
    required Future<double?> Function(Audio audio) readReplayGain,
    required void Function(SmartTransitionCommit commit) commitTransition,
    required bool Function(SmartTransitionTarget target, String reason)
    prepareFallback,
    required void Function() prepareAfterCompletion,
  }) : _player = player,
       _readLibraryRoot = readLibraryRoot,
       _readTarget = readTarget,
       _validateTarget = validateTarget,
       _nextTransitionId = nextTransitionId,
       _readReplayGain = readReplayGain,
       _commitTransition = commitTransition,
       _prepareFallback = prepareFallback,
       _prepareAfterCompletion = prepareAfterCompletion {
    try {
      _eventSubscription = native
          .initSmartTransitionEvents(bassDir: _player.bassDirectory)
          .listen(
            _handleNativeEvent,
            onError: (Object error, StackTrace trace) {
              _lastFallbackReason = 'native_event_stream: $error';
              logger.w(
                '[smart transition] native event stream failed',
                error: error,
                stackTrace: trace,
              );
            },
          );
    } catch (error, trace) {
      _lastFallbackReason = 'native_event_init: $error';
      logger.w(
        '[smart transition] native event stream unavailable',
        error: error,
        stackTrace: trace,
      );
    }
  }

  final BassPlayer _player;
  final Future<String> Function() _readLibraryRoot;
  final SmartTransitionTarget? Function() _readTarget;
  final bool Function(SmartTransitionTarget target) _validateTarget;
  final int Function() _nextTransitionId;
  final Future<double?> Function(Audio audio) _readReplayGain;
  final void Function(SmartTransitionCommit commit) _commitTransition;
  final bool Function(SmartTransitionTarget target, String reason)
  _prepareFallback;
  final void Function() _prepareAfterCompletion;

  StreamSubscription<String>? _eventSubscription;
  _PendingSmartTransition? _pending;
  int _generation = 0;
  int _nextAnalysisJobId = 1;
  String _state = 'idle';
  String? _lastFallbackReason;
  Map<String, Object?>? _lastPlan;
  Map<String, Object?>? _lastNativeSnapshot;
  int? _lastTransitionId;

  Map<String, Object?> get diagnostics {
    Map<String, Object?>? nativeDiagnostics;
    try {
      nativeDiagnostics = _decodeMap(native.smartTransitionDiagnosticsJson());
    } catch (_) {}
    final plan = _lastPlan;
    return {
      'state': _state,
      'generation': _generation,
      'transitionId': _pending?.transitionId ?? _lastTransitionId,
      'plan': plan?['mode'],
      'confidence': plan?['confidence'],
      'cue': {
        'outgoingMs': plan?['outgoing_cue_ms'],
        'incomingMs': plan?['incoming_cue_ms'],
      },
      'durationMs': plan?['duration_ms'],
      'fallbackReason': _lastFallbackReason,
      'bassError': _lastNativeSnapshot?['lastBassError'],
      'native': nativeDiagnostics,
    };
  }

  void rebuild() {
    cancel('rebuild');
    final target = _readTarget();
    if (target == null) {
      _state = 'idle';
      return;
    }
    final pending = _PendingSmartTransition(
      transitionId: _nextTransitionId(),
      generation: ++_generation,
      sourceGeneration: _player.sourceGeneration,
      target: target,
    );
    _lastTransitionId = pending.transitionId;
    pending.windowOpen = target.outgoing.duration <= 45;
    _pending = pending;
    _lastFallbackReason = null;
    _lastPlan = null;
    _lastNativeSnapshot = null;
    _state = 'analyzing_outgoing';
    AudioEchoLogRecorder.instance.mark(
      'smart_transition_rebuild',
      extra: {
        'transitionId': pending.transitionId,
        'generation': pending.generation,
        'sourceGeneration': pending.sourceGeneration,
        'outgoingIndex': target.outgoingIndex,
        'incomingIndex': target.incomingIndex,
        'gaplessCandidate': target.isGaplessCandidate,
        'outgoingPath': target.outgoing.path,
        'incomingPath': target.incoming.path,
      },
    );

    if (!_player.canUseSmartTransition) {
      _fallback(pending, 'mixer_unavailable');
      return;
    }
    final capabilities = _capabilities();
    if (capabilities['available'] != true ||
        capabilities['absoluteScheduling'] != true ||
        capabilities['envelope'] != true ||
        capabilities['playbackSync'] != true) {
      _fallback(
        pending,
        'native_capability: ${capabilities['error'] ?? 'incomplete'}',
      );
      return;
    }
    unawaited(_analyzeOutgoing(pending));
  }

  void onPositionTick(double positionSeconds, double lengthSeconds) {
    final pending = _pending;
    if (pending == null || pending.terminal || pending.committed) return;
    if (pending.sourceGeneration != _player.sourceGeneration ||
        !_validateTarget(pending.target)) {
      rebuild();
      return;
    }
    pending.lastPositionSeconds = positionSeconds;
    if (lengthSeconds - positionSeconds <= 45.0) {
      pending.windowOpen = true;
      _startIncomingAnalysisIfReady(pending);
    }
  }

  bool handlePlayerCompleted() {
    final pending = _pending;
    if (pending == null || !pending.reserved) return false;
    final committed = cancel('player_completed');
    return resolvePlayerCompleted(
      committed: committed,
      targetIsValid: _validateTarget(pending.target),
      prepareFallback: () {
        _lastFallbackReason = 'player_completed_before_native_start';
        return _prepareFallback(pending.target, _lastFallbackReason!);
      },
    );
  }

  @visibleForTesting
  static bool resolvePlayerCompleted({
    required bool committed,
    required bool targetIsValid,
    required bool Function() prepareFallback,
  }) {
    if (committed) return true;
    if (!targetIsValid) return false;
    return prepareFallback();
  }

  bool cancel(String reason) {
    final pending = _pending;
    AudioEchoLogRecorder.instance.mark(
      'smart_transition_cancel',
      extra: {
        'transitionId': pending?.transitionId,
        'generation': pending?.generation,
        'sourceGeneration':
            pending?.sourceGeneration ?? _player.sourceGeneration,
        'reason': reason,
        'state': _state,
        'transferred': pending?.transferred,
        'reserved': pending?.reserved,
      },
    );
    _generation++;
    if (pending == null) return false;
    pending.cancelTimers();
    final jobId = pending.analysisJobId;
    if (jobId != null) {
      native.cancelSmartTransitionAnalysis(jobId: BigInt.from(jobId));
      pending.analysisJobId = null;
    }

    if (!pending.transferred) {
      final preparation = pending.preparation;
      if (preparation != null) {
        _player.discardSmartTransition(
          pending.transitionId,
          incomingReleasedByNative: false,
        );
      }
      pending.terminal = true;
      _pending = null;
      _state = 'cancelled';
      return false;
    }

    final snapshot = _decodeMap(
      native.cancelNativeSmartTransitionJson(
        transitionId: BigInt.from(pending.transitionId),
        reason: reason,
      ),
    );
    _lastNativeSnapshot = snapshot;
    final state = snapshot['state'] as String? ?? 'missing';
    if (_hasStarted(state)) {
      _commitStarted(pending, snapshot);
    } else {
      _player.discardSmartTransition(
        pending.transitionId,
        incomingReleasedByNative: true,
      );
    }
    if (state == 'completed') {
      _complete(pending, snapshot, prepareNext: false);
    } else {
      native.acknowledgeNativeSmartTransition(
        transitionId: BigInt.from(pending.transitionId),
      );
      pending.terminal = true;
      _pending = null;
      _state = state;
    }
    return pending.committed;
  }

  Future<void> close() async {
    try {
      cancel('close');
    } catch (error, trace) {
      logger.w(
        '[smart transition] close cancellation failed',
        error: error,
        stackTrace: trace,
      );
    }
    try {
      native.closeSmartTransitionEvents();
    } catch (error, trace) {
      logger.w(
        '[smart transition] event stream close failed',
        error: error,
        stackTrace: trace,
      );
    }
    final subscription = _eventSubscription;
    _eventSubscription = null;
    await subscription?.cancel();
  }

  Future<void> _analyzeOutgoing(_PendingSmartTransition pending) async {
    final jobId = _nextAnalysisJobId++;
    pending.analysisJobId = jobId;
    AudioEchoLogRecorder.instance.mark(
      'smart_transition_analyze_outgoing_start',
      extra: {
        'transitionId': pending.transitionId,
        'generation': pending.generation,
        'sourceGeneration': pending.sourceGeneration,
        'jobId': jobId,
      },
    );
    try {
      final libraryRoot = await _readLibraryRoot();
      if (!_isCurrent(pending)) return;
      final profile = await native.analyzeSmartTransitionTrack(
        jobId: BigInt.from(jobId),
        path: pending.target.outgoing.path,
        libraryRoot: libraryRoot,
      );
      if (!_isCurrent(pending) || pending.analysisJobId != jobId) return;
      pending.analysisJobId = null;
      pending.outgoingProfileJson = profile;
      _state = pending.windowOpen ? 'analyzing_incoming' : 'waiting_window';
      AudioEchoLogRecorder.instance.mark(
        'smart_transition_analyze_outgoing_complete',
        extra: {
          'transitionId': pending.transitionId,
          'generation': pending.generation,
          'sourceGeneration': pending.sourceGeneration,
          'jobId': jobId,
          'state': _state,
        },
      );
      _startIncomingAnalysisIfReady(pending);
    } catch (error, trace) {
      if (!_isCurrent(pending)) return;
      logger.w(
        '[smart transition] outgoing analysis failed',
        error: error,
        stackTrace: trace,
      );
      _fallback(pending, 'outgoing_analysis: $error');
    }
  }

  void _startIncomingAnalysisIfReady(_PendingSmartTransition pending) {
    if (!_isCurrent(pending) ||
        !pending.windowOpen ||
        pending.outgoingProfileJson == null ||
        pending.incomingAnalysisStarted) {
      return;
    }
    pending.incomingAnalysisStarted = true;
    _state = 'analyzing_incoming';
    AudioEchoLogRecorder.instance.mark(
      'smart_transition_analyze_incoming',
      extra: {
        'transitionId': pending.transitionId,
        'generation': pending.generation,
        'sourceGeneration': pending.sourceGeneration,
        'position': pending.lastPositionSeconds,
        'length': pending.target.outgoing.duration,
      },
    );
    unawaited(_analyzeIncoming(pending));
  }

  Future<void> _analyzeIncoming(_PendingSmartTransition pending) async {
    final jobId = _nextAnalysisJobId++;
    pending.analysisJobId = jobId;
    try {
      final libraryRoot = await _readLibraryRoot();
      if (!_isCurrent(pending)) return;
      final profile = await native.analyzeSmartTransitionTrack(
        jobId: BigInt.from(jobId),
        path: pending.target.incoming.path,
        libraryRoot: libraryRoot,
      );
      if (!_isCurrent(pending) || pending.analysisJobId != jobId) return;
      pending.analysisJobId = null;
      pending.incomingProfileJson = profile;
      await _planAndArm(pending);
    } catch (error, trace) {
      if (!_isCurrent(pending)) return;
      logger.w(
        '[smart transition] incoming analysis failed',
        error: error,
        stackTrace: trace,
      );
      _fallback(pending, 'incoming_analysis: $error');
    }
  }

  Future<void> _planAndArm(_PendingSmartTransition pending) async {
    if (!_isCurrent(pending) || !_validateTarget(pending.target)) {
      cancel('target_changed_before_plan');
      return;
    }
    _state = 'planning';
    final incomingReplayGainDb = await _readReplayGain(pending.target.incoming);
    if (!_isCurrent(pending) || !_validateTarget(pending.target)) return;
    final capabilities = _capabilities();
    try {
      final planJson = await native.planSmartTransitionJson(
        outgoingProfileJson: pending.outgoingProfileJson!,
        incomingProfileJson: pending.incomingProfileJson!,
        isGaplessCandidate: pending.target.isGaplessCandidate,
        userSpeed: pending.target.userSpeed,
        pitch: pending.target.pitch,
        tempoAtCueAvailable: capabilities['tempoAtCue'] == true,
        outgoingReplayGainDb: pending.target.outgoingReplayGainDb ?? 0.0,
        incomingReplayGainDb: incomingReplayGainDb ?? 0.0,
      );
      if (!_isCurrent(pending) || !_validateTarget(pending.target)) return;
      final plan = _decodeMap(planJson);
      pending.plan = plan;
      _lastPlan = plan;
      _state = 'preparing';
      AudioEchoLogRecorder.instance.mark(
        'smart_transition_plan',
        extra: {
          'transitionId': pending.transitionId,
          'generation': pending.generation,
          'sourceGeneration': pending.sourceGeneration,
          'mode': plan['mode'],
          'confidence': plan['confidence'],
          'outgoingCueMs': plan['outgoing_cue_ms'],
          'incomingCueMs': plan['incoming_cue_ms'],
          'durationMs': plan['duration_ms'],
          'diagnostics': jsonEncode(plan['diagnostics']),
        },
      );
      final preparation = _player.prepareSmartTransition(
        pending.target.incoming.path,
        transitionId: pending.transitionId,
        replayGainDb: incomingReplayGainDb,
      );
      if (preparation == null) {
        _fallback(pending, 'incoming_prepare_failed');
        return;
      }
      pending.preparation = preparation;
      if (!_isCurrent(pending) ||
          !_validateTarget(pending.target) ||
          preparation.sourceGeneration != _player.sourceGeneration) {
        _player.discardSmartTransition(
          pending.transitionId,
          incomingReleasedByNative: false,
        );
        pending.preparation = null;
        cancel('target_changed_before_arm');
        return;
      }
      final outcome = _decodeMap(
        native.armSmartTransitionJson(
          bassDir: _player.bassDirectory,
          requestJson: jsonEncode({
            'transitionId': pending.transitionId,
            'sourceGeneration': preparation.sourceGeneration,
            'mixerHandle': preparation.mixerHandle,
            'outgoingHandle': preparation.outgoingHandle,
            'incomingHandle': preparation.incomingHandle,
            'incomingPath': preparation.path,
            'incomingReplayGainDb': preparation.replayGainDb,
            'plan': plan,
          }),
        ),
      );
      if (outcome['accepted'] != true) {
        _player.discardSmartTransition(
          pending.transitionId,
          incomingReleasedByNative: false,
        );
        pending.preparation = null;
        _fallback(pending, 'native_arm: ${outcome['error'] ?? 'rejected'}');
        return;
      }
      pending.transferred = true;
      pending.reserved = true;
      _player.markSmartTransitionTransferred(pending.transitionId);
      final snapshot = _objectMap(outcome['snapshot']);
      _lastNativeSnapshot = snapshot;
      final state = snapshot?['state'] as String? ?? 'armed';
      if (state == 'failed' || state == 'cancelled') {
        _player.discardSmartTransition(
          pending.transitionId,
          incomingReleasedByNative: true,
        );
        native.acknowledgeNativeSmartTransition(
          transitionId: BigInt.from(pending.transitionId),
        );
        pending.transferred = false;
        pending.reserved = false;
        _fallback(pending, 'native_arm: ${outcome['error'] ?? state}');
        return;
      }
      _state = 'armed';
      AudioEchoLogRecorder.instance.mark(
        'smart_transition_armed',
        extra: {
          'transitionId': pending.transitionId,
          'generation': pending.generation,
          'sourceGeneration': pending.sourceGeneration,
          'nativeState': state,
          'snapshot': jsonEncode(snapshot),
        },
      );
      _scheduleStartRecovery(pending);
      logger.i(
        '[smart transition] plan id=${pending.transitionId} '
        'mode=${plan['mode']} confidence=${plan['confidence']} '
        'cue=${plan['outgoing_cue_ms']} duration=${plan['duration_ms']}',
      );
    } catch (error, trace) {
      if (!_isCurrent(pending)) return;
      logger.w(
        '[smart transition] planning or arm failed',
        error: error,
        stackTrace: trace,
      );
      _fallback(pending, 'plan_or_arm: $error');
    }
  }

  void _handleNativeEvent(String raw) {
    try {
      final payload = _decodeMap(raw);
      final snapshot = _objectMap(payload['snapshot']);
      if (snapshot == null) return;
      final transitionId = _asInt(snapshot['transitionId']);
      final pending = _pending;
      if (pending == null || transitionId != pending.transitionId) {
        final state = snapshot['state'] as String?;
        if (transitionId != null &&
            (state == 'completed' ||
                state == 'cancelled' ||
                state == 'failed')) {
          AudioEchoLogRecorder.instance.mark(
            'smart_transition_late_terminal',
            extra: {
              'transitionId': transitionId,
              'nativeState': state,
              'snapshot': jsonEncode(snapshot),
            },
          );
          native.acknowledgeNativeSmartTransition(
            transitionId: BigInt.from(transitionId),
          );
        }
        return;
      }
      final sequence = _asInt(payload['eventSequence']) ?? 0;
      if (sequence <= pending.lastEventSequence) return;
      pending.lastEventSequence = sequence;
      AudioEchoLogRecorder.instance.mark(
        'smart_transition_native_event',
        extra: {
          'transitionId': pending.transitionId,
          'generation': pending.generation,
          'sourceGeneration': pending.sourceGeneration,
          'eventSequence': sequence,
          'nativeState': snapshot['state'],
          'snapshot': jsonEncode(snapshot),
        },
      );
      _applySnapshot(pending, snapshot);
    } catch (error, trace) {
      logger.w(
        '[smart transition] invalid native event',
        error: error,
        stackTrace: trace,
      );
    }
  }

  void _applySnapshot(
    _PendingSmartTransition pending,
    Map<String, Object?> snapshot,
  ) {
    if (!_isCurrent(pending)) return;
    _lastNativeSnapshot = snapshot;
    final state = snapshot['state'] as String? ?? 'unknown';
    AudioEchoLogRecorder.instance.mark(
      'smart_transition_snapshot',
      extra: {
        'transitionId': pending.transitionId,
        'generation': pending.generation,
        'sourceGeneration': pending.sourceGeneration,
        'nativeState': snapshot['state'],
      },
    );
    if (_hasStarted(state)) {
      _commitStarted(pending, snapshot);
    }
    if (state == 'completed') {
      _complete(pending, snapshot, prepareNext: true);
    } else if (state == 'failed' || state == 'cancelled') {
      _player.discardSmartTransition(
        pending.transitionId,
        incomingReleasedByNative: true,
      );
      native.acknowledgeNativeSmartTransition(
        transitionId: BigInt.from(pending.transitionId),
      );
      pending.terminal = true;
      _pending = null;
      _state = state;
      if (!pending.committed && _validateTarget(pending.target)) {
        _lastFallbackReason = snapshot['error'] as String? ?? 'native_$state';
        _prepareFallback(pending.target, _lastFallbackReason!);
      }
    }
  }

  void _commitStarted(
    _PendingSmartTransition pending,
    Map<String, Object?> snapshot,
  ) {
    if (pending.committed || !_validateTarget(pending.target)) return;
    native.adoptNativeSmartTransitionJson(
      transitionId: BigInt.from(pending.transitionId),
    );
    final transition = _player.adoptSmartTransition(pending.transitionId);
    if (transition == null) return;
    pending.committed = true;
    AudioEchoLogRecorder.instance.mark(
      'smart_transition_commit',
      extra: {
        'transitionId': pending.transitionId,
        'generation': pending.generation,
        'sourceGeneration': pending.sourceGeneration,
        'nativeState': snapshot['state'],
      },
    );
    pending.startRecoveryTimer?.cancel();
    pending.startRecoveryTimer = null;
    pending.reconcileAttempts = 0;
    _state = 'started';
    _commitTransition(
      SmartTransitionCommit(
        transitionId: pending.transitionId,
        target: pending.target,
        transition: transition,
      ),
    );
    final durationMs = _asInt(pending.plan?['duration_ms']) ?? 0;
    pending.completionRecoveryTimer = Timer(
      Duration(milliseconds: durationMs + 100),
      () => _reconcile(pending),
    );
  }

  void _complete(
    _PendingSmartTransition pending,
    Map<String, Object?> snapshot, {
    required bool prepareNext,
  }) {
    if (pending.terminal) return;
    AudioEchoLogRecorder.instance.mark(
      'smart_transition_complete',
      extra: {
        'transitionId': pending.transitionId,
        'generation': pending.generation,
        'sourceGeneration': pending.sourceGeneration,
        'nativeState': snapshot['state'],
        'committed': pending.committed,
      },
    );
    if (!pending.committed) _commitStarted(pending, snapshot);
    _player.completeSmartTransition(pending.transitionId);
    native.acknowledgeNativeSmartTransition(
      transitionId: BigInt.from(pending.transitionId),
    );
    pending.cancelTimers();
    pending.terminal = true;
    _pending = null;
    _state = 'completed';
    if (prepareNext && pending.committed) {
      _prepareAfterCompletion();
    }
  }

  void _scheduleStartRecovery(_PendingSmartTransition pending) {
    final cueMs = _asInt(pending.plan?['outgoing_cue_ms']) ?? 0;
    final remainingMs = cueMs - (pending.lastPositionSeconds * 1000).round();
    pending.startRecoveryTimer = Timer(
      Duration(milliseconds: remainingMs.clamp(100, 60000) + 100),
      () => _reconcile(pending),
    );
  }

  void _reconcile(_PendingSmartTransition pending) {
    if (!_isCurrent(pending) || !pending.transferred) return;
    try {
      final snapshot = _decodeMap(
        native.nativeSmartTransitionSnapshotJson(
          transitionId: BigInt.from(pending.transitionId),
        ),
      );
      _applySnapshot(pending, snapshot);
      final state = snapshot['state'] as String?;
      if (!_isCurrent(pending)) return;
      if (state == 'started') {
        if (pending.reconcileAttempts++ < 5) {
          pending.completionRecoveryTimer = Timer(
            const Duration(milliseconds: 100),
            () => _reconcile(pending),
          );
          return;
        }
        final recovered = _decodeMap(
          native.cancelNativeSmartTransitionJson(
            transitionId: BigInt.from(pending.transitionId),
            reason: 'completion_watchdog',
          ),
        );
        _lastNativeSnapshot = recovered;
        AudioEchoLogRecorder.instance.mark(
          'smart_transition_completion_recovery',
          extra: {
            'transitionId': pending.transitionId,
            'generation': pending.generation,
            'sourceGeneration': pending.sourceGeneration,
            'nativeState': recovered['state'],
          },
        );
        _applySnapshot(pending, recovered);
      } else if ((state == 'armed' || state == 'completing') &&
          pending.reconcileAttempts++ < 5) {
        pending.startRecoveryTimer = Timer(
          const Duration(milliseconds: 100),
          () => _reconcile(pending),
        );
      }
    } catch (error, trace) {
      logger.w(
        '[smart transition] snapshot reconciliation failed',
        error: error,
        stackTrace: trace,
      );
    }
  }

  void _fallback(_PendingSmartTransition pending, String reason) {
    if (!_isCurrent(pending)) return;
    AudioEchoLogRecorder.instance.mark(
      'smart_transition_fallback',
      extra: {
        'transitionId': pending.transitionId,
        'generation': pending.generation,
        'sourceGeneration': pending.sourceGeneration,
        'state': _state,
        'reason': reason,
        'transferred': pending.transferred,
        'reserved': pending.reserved,
      },
    );
    pending.cancelTimers();
    final jobId = pending.analysisJobId;
    if (jobId != null) {
      native.cancelSmartTransitionAnalysis(jobId: BigInt.from(jobId));
      pending.analysisJobId = null;
    }
    final preparation = pending.preparation;
    if (preparation != null) {
      if (pending.transferred) {
        final snapshot = _decodeMap(
          native.cancelNativeSmartTransitionJson(
            transitionId: BigInt.from(pending.transitionId),
            reason: reason,
          ),
        );
        _lastNativeSnapshot = snapshot;
        final state = snapshot['state'] as String? ?? 'missing';
        if (_hasStarted(state)) {
          _commitStarted(pending, snapshot);
          _complete(pending, snapshot, prepareNext: false);
          return;
        }
        _player.discardSmartTransition(
          pending.transitionId,
          incomingReleasedByNative: true,
        );
        native.acknowledgeNativeSmartTransition(
          transitionId: BigInt.from(pending.transitionId),
        );
      } else {
        _player.discardSmartTransition(
          pending.transitionId,
          incomingReleasedByNative: false,
        );
      }
    }
    pending.terminal = true;
    _pending = null;
    _lastFallbackReason = reason;
    _state = 'fallback';
    logger.i('[smart transition] fallback id=${pending.transitionId} $reason');
    if (_validateTarget(pending.target)) {
      _prepareFallback(pending.target, reason);
    }
  }

  bool _isCurrent(_PendingSmartTransition pending) =>
      identical(_pending, pending) &&
      pending.generation == _generation &&
      !pending.terminal;

  Map<String, Object?> _capabilities() {
    try {
      return _decodeMap(
        native.smartTransitionCapabilitiesJson(bassDir: _player.bassDirectory),
      );
    } catch (error) {
      return {'available': false, 'error': error.toString()};
    }
  }

  bool _hasStarted(String state) =>
      state == 'started' || state == 'completing' || state == 'completed';

  Map<String, Object?> _decodeMap(String value) {
    final decoded = jsonDecode(value);
    return _objectMap(decoded) ?? <String, Object?>{};
  }

  Map<String, Object?>? _objectMap(Object? value) {
    if (value is! Map) return null;
    return value.map((key, item) => MapEntry(key.toString(), item));
  }

  int? _asInt(Object? value) => value is num ? value.toInt() : null;
}
