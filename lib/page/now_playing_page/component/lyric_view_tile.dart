import 'dart:async';
import 'dart:math';

import 'package:pure_music/core/enums.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 歌词间奏表示
/// lrcLine 和 syncLine 必须有且只有一个不为空
class LyricTransitionTile extends StatefulWidget {
  final LrcLine? lrcLine;
  final SyncLyricLine? syncLine;
  final LyricTextAlign? alignment;
  final bool enableBreathing;
  final bool compact;
  final bool useMaterialYouColor;
  const LyricTransitionTile({
    super.key,
    this.lrcLine,
    this.syncLine,
    this.alignment,
    this.enableBreathing = true,
    this.compact = false,
    this.useMaterialYouColor = true,
  });

  @override
  State<LyricTransitionTile> createState() => _LyricTransitionTileState();
}

class _LyricTransitionTileState extends State<LyricTransitionTile> {
  late LyricTransitionTileController controller;

  @override
  void initState() {
    super.initState();
    controller = LyricTransitionTileController(
        widget.lrcLine, widget.syncLine, widget.enableBreathing);
  }

  @override
  void didUpdateWidget(LyricTransitionTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lrcLine != widget.lrcLine ||
        oldWidget.syncLine != widget.syncLine) {
      controller.dispose();
      controller = LyricTransitionTileController(
          widget.lrcLine, widget.syncLine, widget.enableBreathing);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // 间奏结束后隐藏，避免动画残留
    if (controller.progress >= 1) {
      return const SizedBox.shrink();
    }

    final align = widget.alignment ?? LyricTextAlign.left;
    final alignment = switch (align) {
      LyricTextAlign.left => Alignment.centerLeft,
      LyricTextAlign.center => Alignment.center,
      LyricTextAlign.right => Alignment.centerRight,
    };

    if (widget.compact) {
      return Align(
        alignment: alignment,
        child: SizedBox(
          height: 24.0,
          width: 72.0,
          child: CustomPaint(
            painter: LyricTransitionPainter(
              scheme,
              controller,
              compact: true,
              alignment: align,
              useMaterialYouColor: widget.useMaterialYouColor,
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      height: 40.0,
      child: CustomPaint(
        painter: LyricTransitionPainter(
          scheme,
          controller,
          alignment: align,
          useMaterialYouColor: widget.useMaterialYouColor,
        ),
      ),
    );
  }
}

class LyricTransitionPainter extends CustomPainter {
  final ColorScheme scheme;
  final LyricTransitionTileController controller;
  final bool compact;
  final bool useMaterialYouColor;
  final LyricTextAlign alignment;

  final Paint circlePaint1 = Paint();
  final Paint circlePaint2 = Paint();
  final Paint circlePaint3 = Paint();

  final double radius = 6;

  LyricTransitionPainter(this.scheme, this.controller,
      {this.compact = false,
      this.useMaterialYouColor = true,
      this.alignment = LyricTextAlign.left})
      : super(repaint: controller);

  @override
  void paint(Canvas canvas, Size size) {
    final progress = controller.progress.clamp(0.0, 1.0);
    final enterOpacity =
        Curves.easeOutCubic.transform((progress / 0.12).clamp(0.0, 1.0));
    final exitOpacity = Curves.easeOutCubic
        .transform(((1.0 - progress) / 0.18).clamp(0.0, 1.0));
    final opacityEnvelope = enterOpacity * exitOpacity;

    final a1 = (255 *
            opacityEnvelope *
            (0.05 + min(controller.progress * 3, 1) * 0.95))
        .round()
        .clamp(0, 255);
    final a2 = (255 *
            opacityEnvelope *
            (0.05 + min(max(controller.progress - 1 / 3, 0) * 3, 1) * 0.95))
        .round()
        .clamp(0, 255);
    final a3 = (255 *
            opacityEnvelope *
            (0.05 + min(max(controller.progress - 2 / 3, 0) * 3, 1) * 0.95))
        .round()
        .clamp(0, 255);
    final transitionColor = useMaterialYouColor
        ? scheme.onSecondaryContainer
        : (scheme.brightness == Brightness.dark ? Colors.white : Colors.black);
    circlePaint1.color = transitionColor.withAlpha(a1);
    circlePaint2.color = transitionColor.withAlpha(a2);
    circlePaint3.color = transitionColor.withAlpha(a3);

    final cy = size.height / 2;
    if (compact) {
      final r = 4 + controller.sizeFactor * 0.5;
      final gap = 3.0 * r;
      final double x1, x2, x3;
      switch (alignment) {
        case LyricTextAlign.left:
          x1 = 10.0;
          x2 = x1 + gap;
          x3 = x2 + gap;
        case LyricTextAlign.center:
          x2 = size.width / 2;
          x1 = x2 - gap;
          x3 = x2 + gap;
        case LyricTextAlign.right:
          x3 = size.width - 10.0;
          x2 = x3 - gap;
          x1 = x2 - gap;
      }
      canvas.drawCircle(Offset(x1, cy), r, circlePaint1);
      canvas.drawCircle(Offset(x2, cy), r, circlePaint2);
      canvas.drawCircle(Offset(x3, cy), r, circlePaint3);
    } else {
      final rWithFactor = radius + controller.sizeFactor;
      final gap = 3.0 * rWithFactor;
      final double x1, x2, x3;
      switch (alignment) {
        case LyricTextAlign.left:
          x1 = 12.0;
          x2 = x1 + gap;
          x3 = x2 + gap;
        case LyricTextAlign.center:
          x2 = size.width / 2;
          x1 = x2 - gap;
          x3 = x2 + gap;
        case LyricTextAlign.right:
          x3 = size.width - 12.0;
          x2 = x3 - gap;
          x1 = x2 - gap;
      }
      canvas.drawCircle(Offset(x1, cy), rWithFactor, circlePaint1);
      canvas.drawCircle(Offset(x2, cy), rWithFactor, circlePaint2);
      canvas.drawCircle(Offset(x3, cy), rWithFactor, circlePaint3);
    }
  }

  @override
  bool shouldRepaint(LyricTransitionPainter oldDelegate) => false;

  @override
  bool shouldRebuildSemantics(LyricTransitionPainter oldDelegate) => false;
}

/// 全局共享的间奏动画控制器管理器
/// 避免每个 LyricTransitionTile 都独立订阅 positionStream
class _TransitionControllerManager {
  static final _TransitionControllerManager _instance =
      _TransitionControllerManager._();
  static _TransitionControllerManager get instance => _instance;

  _TransitionControllerManager._();

  StreamSubscription<double>? _sharedPositionSub;
  final Set<LyricTransitionTileController> _controllers = {};
  int _lastUpdateMs = 0;
  static const int _throttleMs = 50;

  void register(LyricTransitionTileController controller) {
    _controllers.add(controller);
    _ensureSubscribed();
  }

  void unregister(LyricTransitionTileController controller) {
    _controllers.remove(controller);
    if (_controllers.isEmpty) {
      _sharedPositionSub?.cancel();
      _sharedPositionSub = null;
    }
  }

  void _ensureSubscribed() {
    if (_sharedPositionSub != null) return;
    try {
      _sharedPositionSub =
          PlayService.instance.playbackService.positionStream.listen(
        (position) {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - _lastUpdateMs < _throttleMs) return;
          _lastUpdateMs = now;

          // 遍历快照，避免并发修改
          final controllers = List<LyricTransitionTileController>.from(
            _controllers,
          );
          for (final c in controllers) {
            if (c._disposed) {
              _controllers.remove(c);
            } else {
              c._updateProgress(position);
            }
          }

          // 如果全部已 dispose，取消订阅
          if (_controllers.isEmpty) {
            _sharedPositionSub?.cancel();
            _sharedPositionSub = null;
          }
        },
        onError: (_) {
          // 流错误时清理订阅，下次 register 会重新订阅
          _sharedPositionSub?.cancel();
          _sharedPositionSub = null;
        },
        cancelOnError: false,
      );
    } catch (_) {
      _sharedPositionSub = null;
    }
  }
}

class LyricTransitionTileController extends ChangeNotifier {
  final LrcLine? lrcLine;
  final SyncLyricLine? syncLine;

  @override
  void addListener(VoidCallback listener) {
    if (_disposed) return;
    super.addListener(listener);
  }

  final playbackService = PlayService.instance.playbackService;

  double progress = 0;

  double sizeFactor = 0;
  double k = 1;
  late final Ticker factorTicker;
  bool _disposed = false;

  LyricTransitionTileController(
      [this.lrcLine, this.syncLine, bool enableBreathing = true]) {
    _TransitionControllerManager.instance.register(this);
    if (enableBreathing) {
      factorTicker = Ticker((elapsed) {
        if (_disposed) return;
        sizeFactor += k * 1 / 180;
        if (sizeFactor > 1) {
          k = -1;
          sizeFactor = 1;
        } else if (sizeFactor < 0) {
          k = 1;
          sizeFactor = 0;
        }
        notifyListeners();
      });
      factorTicker.start();
    } else {
      factorTicker = Ticker((_) {});
    }
  }

  void _updateProgress(double position) {
    if (_disposed) return;

    late int startInMs;
    late int lengthInMs;
    if (lrcLine != null) {
      startInMs = lrcLine!.start.inMilliseconds;
      lengthInMs = lrcLine!.length.inMilliseconds;
    } else {
      startInMs = syncLine!.start.inMilliseconds;
      lengthInMs = syncLine!.length.inMilliseconds;
    }
    // 防止除零：lengthInMs 可能因数据异常为 0
    if (lengthInMs <= 0) {
      progress = 1.0;
      notifyListeners();
      dispose();
      return;
    }
    final sinceStart = position * 1000 - startInMs;
    progress = max(sinceStart, 0) / lengthInMs;
    notifyListeners();

    if (progress >= 1) {
      dispose();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    _TransitionControllerManager.instance.unregister(this);

    try {
      factorTicker.stop();
      factorTicker.dispose();
    } catch (_) {}

    super.dispose();
  }
}
