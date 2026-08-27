import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

final _DeferredLoadQueue _deferredLoadQueue = _DeferredLoadQueue();

class _DeferredLoadRequest {
  _DeferredLoadRequest(this.callback);

  void Function(bool force) callback;
  int deferrals = 0;
}

class _DeferredLoadQueue {
  static const _retryDelay = Duration(milliseconds: 64);
  static const _maximumDeferral = Duration(milliseconds: 192);
  static const _maximumForcedLoadsPerFlush = 2;

  final LinkedHashMap<Object, _DeferredLoadRequest> _pending =
      LinkedHashMap<Object, _DeferredLoadRequest>.identity();
  Timer? _timer;

  void enqueue(Object key, void Function(bool force) callback) {
    final existing = _pending[key];
    if (existing != null) {
      existing.callback = callback;
    } else {
      _pending[key] = _DeferredLoadRequest(callback);
    }
    _timer ??= Timer(_retryDelay, _flush);
  }

  void remove(Object key) {
    _pending.remove(key);
    if (_pending.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _flush() {
    _timer = null;
    if (_pending.isEmpty) return;
    final requests = _pending.entries.toList(growable: false);
    _pending.clear();
    var forcedLoads = 0;
    for (final entry in requests) {
      final force =
          forcedLoads < _maximumForcedLoadsPerFlush &&
          entry.value.deferrals * _retryDelay.inMilliseconds >=
              _maximumDeferral.inMilliseconds;
      if (force) forcedLoads++;
      entry.value.callback(force);
      final requeued = _pending[entry.key];
      if (requeued != null) {
        requeued.deferrals = entry.value.deferrals + 1;
      }
    }
    if (_pending.isNotEmpty && _timer == null) {
      _timer = Timer(_retryDelay, _flush);
    }
  }
}

class ScrollAwareFutureBuilder<T> extends StatefulWidget {
  final Future<T> Function() future;
  final AsyncWidgetBuilder<T> builder;
  final String? identity;
  final T? initialData;
  final bool deferWhileScrolling;

  const ScrollAwareFutureBuilder({
    super.key,
    required this.future,
    required this.builder,
    this.identity,
    this.initialData,
    this.deferWhileScrolling = true,
  });

  @override
  State<ScrollAwareFutureBuilder<T>> createState() =>
      _ScrollAwareFutureBuilderState<T>();
}

class _ScrollAwareFutureBuilderState<T>
    extends State<ScrollAwareFutureBuilder<T>> {
  Future<T>? _future;
  int _loadGeneration = 0;

  void _scheduleLoad() {
    _deferredLoadQueue.remove(this);
    final generation = ++_loadGeneration;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _tryLoad(generation, false);
    });
  }

  void _tryLoad(int generation, bool force) {
    if (!mounted || generation != _loadGeneration) return;
    if (!force &&
        widget.deferWhileScrolling &&
        Scrollable.recommendDeferredLoadingForContext(context)) {
      _deferredLoadQueue.enqueue(this, (force) => _tryLoad(generation, force));
      return;
    }
    _deferredLoadQueue.remove(this);
    final future = widget.future();
    setState(() {
      _future = future;
    });
  }

  @override
  void initState() {
    super.initState();
    _scheduleLoad();
  }

  @override
  void didUpdateWidget(ScrollAwareFutureBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.identity != oldWidget.identity) {
      _deferredLoadQueue.remove(this);
      _future = null;
      _scheduleLoad();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      key: ValueKey(widget.identity),
      future: _future,
      initialData: widget.initialData,
      builder: widget.builder,
    );
  }

  @override
  void dispose() {
    _loadGeneration++;
    _deferredLoadQueue.remove(this);
    super.dispose();
  }
}
