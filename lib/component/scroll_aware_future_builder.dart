import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class ScrollAwareFutureBuilder<T> extends StatefulWidget {
  final Future<T> Function() future;
  final AsyncWidgetBuilder<T> builder;
  final String? identity;
  final T? initialData;

  const ScrollAwareFutureBuilder({
    super.key,
    required this.future,
    required this.builder,
    this.identity,
    this.initialData,
  });

  @override
  State<ScrollAwareFutureBuilder<T>> createState() =>
      _ScrollAwareFutureBuilderState<T>();
}

class _ScrollAwareFutureBuilderState<T>
    extends State<ScrollAwareFutureBuilder<T>> {
  Future<T>? _future;
  Timer? _loadTimer;
  int _loadGeneration = 0;

  void _scheduleLoad() {
    _loadTimer?.cancel();
    final generation = ++_loadGeneration;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _tryLoad(generation);
    });
  }

  void _tryLoad(int generation) {
    if (!mounted || generation != _loadGeneration) return;
    if (Scrollable.recommendDeferredLoadingForContext(context)) {
      _loadTimer = Timer(
        const Duration(milliseconds: 64),
        () => _tryLoad(generation),
      );
      return;
    }
    final future = widget.future();
    setState(() => _future = future);
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
    _loadTimer?.cancel();
    super.dispose();
  }
}
