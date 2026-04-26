import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 帧级位置插值器
/// 将低频的位置流（8-33ms）通过 Ticker 插值到屏幕刷新率
/// 实现类似垂直同步的逐帧精确进度更新
class FramePositionInterpolator {
  /// 当前插值后的位置（毫秒）
  double _interpolatedPositionMs = 0;

  /// 最后一次流更新的时间戳（微秒）
  int _lastStreamUpdateUs = 0;

  /// 最后一次插值帧的时间戳（微秒）
  int _lastFrameUs = 0;

  /// 是否正在播放
  bool _isPlaying = false;

  /// Ticker 控制器
  Ticker? _ticker;

  /// 插值位置流
  final StreamController<double> _interpolatedStreamController =
      StreamController<double>.broadcast();

  /// 获取插值后的位置流（毫秒）
  Stream<double> get interpolatedPositionStream =>
      _interpolatedStreamController.stream;

  /// 获取当前插值位置（毫秒）
  double get currentPositionMs => _interpolatedPositionMs;

  FramePositionInterpolator();

  /// 开始监听原始位置流并启动插值
  void bind(Stream<double> rawPositionStream) {
    rawPositionStream.listen(
      _onPositionUpdate,
      onError: (_) {},
    );
  }

  /// 接收位置流更新
  void _onPositionUpdate(double positionSeconds) {
    final now = DateTime.now().microsecondsSinceEpoch;
    final positionMs = positionSeconds * 1000;

    _interpolatedPositionMs = positionMs;
    _lastStreamUpdateUs = now;
    _lastFrameUs = now;

    if (!_isPlaying) {
      _isPlaying = true;
      _startTicker();
    }

    _interpolatedStreamController.add(positionMs);
  }

  /// 启动帧级 Ticker
  void _startTicker() {
    _ticker?.stop();
    _ticker = Ticker(_onTick)..start();
  }

  /// 每一帧调用
  void _onTick(Duration elapsed) {
    if (!_isPlaying) return;

    final now = DateTime.now().microsecondsSinceEpoch;
    final timeSinceLastStreamUs = now - _lastStreamUpdateUs;

    // 如果超过 200ms 没有收到流更新，认为可能暂停了
    if (timeSinceLastStreamUs > 200000) {
      _isPlaying = false;
      _ticker?.stop();
      return;
    }

    // 插值：基于流逝的墙钟时间
    final timeSinceLastFrameUs = now - _lastFrameUs;
    final deltaMs = timeSinceLastFrameUs / 1000.0;

    _interpolatedPositionMs += deltaMs;
    _lastFrameUs = now;

    _interpolatedStreamController.add(_interpolatedPositionMs);
  }

  /// 停止插值
  void stop() {
    _isPlaying = false;
    _ticker?.stop();
  }

  /// 释放资源
  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    _interpolatedStreamController.close();
  }
}

/// 混入组件：自动管理帧级位置插值
/// 用法：在 StatefulWidget 中 mixin 此 trait
mixin FramePositionInterpolatorMixin<T extends StatefulWidget> on State<T> {
  FramePositionInterpolator? _interpolator;
  double _currentPositionMs = 0;

  double get interpolatedPositionMs => _currentPositionMs;

  /// 绑定到原始位置流
  void bindPositionStream(Stream<double> rawStream) {
    _interpolator?.dispose();
    _interpolator = FramePositionInterpolator();
    _interpolator!.bind(rawStream);
    _interpolator!.interpolatedPositionStream.listen((pos) {
      if (!mounted) return;
      setState(() {
        _currentPositionMs = pos;
      });
    });
  }

  @override
  void dispose() {
    _interpolator?.dispose();
    _interpolator = null;
    super.dispose();
  }
}
