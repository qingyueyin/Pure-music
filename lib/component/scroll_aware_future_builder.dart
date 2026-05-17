import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class ScrollAwareFutureBuilder<T> extends StatefulWidget {
  final Future<T> Function() future;
  final AsyncWidgetBuilder builder;
  final String? identity;

  const ScrollAwareFutureBuilder({
    super.key,
    required this.future,
    required this.builder,
    this.identity,
  });

  @override
  State<ScrollAwareFutureBuilder<T>> createState() =>
      _ScrollAwareFutureBuilderState<T>();
}

class _ScrollAwareFutureBuilderState<T>
    extends State<ScrollAwareFutureBuilder<T>> {
  Future<T>? _future;
  Timer? _loadTimer;

  void _scheduleLoad() {
    _loadTimer?.cancel();
    _future = null;

    if (!context.mounted) {
      SchedulerBinding.instance.scheduleFrameCallback((_) {
        scheduleMicrotask(_scheduleLoad);
      });
      return;
    }

    if (Scrollable.recommendDeferredLoadingForContext(context)) {
      SchedulerBinding.instance.scheduleFrameCallback((_) {
        if (mounted) {
          _scheduleLoad();
        }
      });
      return;
    }

    _loadTimer = Timer(
      Duration(milliseconds: 80 + (Random().nextInt(80))),
      () {
        if (!context.mounted) return;
        setState(() => _future = widget.future());
      },
    );
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
      _scheduleLoad();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_future == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return FutureBuilder<T>(
      future: _future,
      builder: widget.builder,
    );
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
    super.dispose();
  }
}