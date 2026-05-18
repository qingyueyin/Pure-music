import 'dart:async';

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

    if (!context.mounted) {
      SchedulerBinding.instance.scheduleFrameCallback((_) {
        scheduleMicrotask(_scheduleLoad);
      });
      return;
    }

    if (Scrollable.recommendDeferredLoadingForContext(context)) {
      // 仍在快速滚动，推迟到下一帧再尝试
      SchedulerBinding.instance.scheduleFrameCallback((_) {
        if (mounted) {
          _scheduleLoad();
        }
      });
      return;
    }

    // 不设 _future = null — 避免每次重载都闪一下转圈。
    // 直接取 future，如果 Audio._coverImage 已缓存则返回已完成的 Future，
    // FutureBuilder 会立即用 snapshot.data 渲染图片，无闪烁。
    setState(() => _future = widget.future());
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