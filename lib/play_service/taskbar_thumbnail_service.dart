import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/window_render_gate.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/play_service.dart';

/// 任务栏播放控制和自定义封面管理。
///
/// 播放按钮和封面预览可独立开关，仅 Windows 生效。
class TaskbarThumbnailService {
  TaskbarThumbnailService._();

  static final TaskbarThumbnailService instance = TaskbarThumbnailService._();

  // 和改动前一样用 512。预览里按封面自己的比例放大到放得下，不再另解一张 1280 的图。
  static const _coverSize = 512;
  static const _quickCoverSize = 96;
  static const _fallbackCoverSize = 64;
  static const _channel = MethodChannel('pure_music/taskbar_thumbnail');

  bool _initialized = false;
  bool _enabled = false;
  bool _pendingEnable = false;
  bool _playbackControlsEnabled = false;
  bool _coverPreviewEnabled = false;
  double _coverScale = 1.0;
  int _lifecycleGeneration = 0;
  int _coverGeneration = 0;
  bool _lastFramesEnabled = true;
  ValueNotifier<Audio?>? _nowPlayingNotifier;
  ValueNotifier<PlayerState>? _playerStateNotifier;
  ValueNotifier<List<Audio>>? _playlistNotifier;

  bool get enabled => _enabled;

  /// 应用启动时初始化任务栏集成（主窗口已创建）
  void init() {
    if (!Platform.isWindows || _initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
    final playback = PlayService.instance.playbackService;
    _nowPlayingNotifier = playback.nowPlayingNotifier;
    _nowPlayingNotifier?.addListener(_onNowPlayingChanged);
    _playerStateNotifier = playback.playerStateNotifier;
    _playerStateNotifier?.addListener(_onPlayerStateChanged);
    _playlistNotifier = playback.playlistNotifier;
    _playlistNotifier?.addListener(_onPlaylistChanged);
    _lastFramesEnabled = WindowRenderGate.instance.framesEnabled.value;
    WindowRenderGate.instance.framesEnabled.addListener(_onFramesEnabledChanged);
    final pref = AppPreference.instance;
    _playbackControlsEnabled = pref.taskbarPlaybackControls;
    _coverPreviewEnabled = pref.taskbarCoverPreview;
    _coverScale = pref.taskbarCoverScale;
    if (_playbackControlsEnabled || _coverPreviewEnabled) {
      unawaited(_enable());
    }
  }

  void setPlaybackControlsEnabled(bool enabled) {
    AppPreference.instance.taskbarPlaybackControls = enabled;
    _playbackControlsEnabled = enabled;
    if (enabled) {
      if (_enabled) {
        unawaited(_syncPlaybackControlsEnabled());
      } else {
        unawaited(_enable());
      }
    } else if (_coverPreviewEnabled) {
      if (_enabled) unawaited(_syncPlaybackControlsEnabled());
    } else {
      _disable();
    }
    unawaited(AppPreference.instance.save());
  }

  void setCoverPreviewEnabled(bool enabled) {
    AppPreference.instance.taskbarCoverPreview = enabled;
    _coverPreviewEnabled = enabled;
    if (enabled) {
      if (_enabled) {
        unawaited(_activateCoverPreview());
      } else {
        unawaited(_enable());
      }
    } else {
      _coverGeneration++;
      if (_playbackControlsEnabled) {
        if (_enabled) unawaited(_setNativeCoverPreview(false));
      } else {
        _disable();
      }
    }
    unawaited(AppPreference.instance.save());
  }

  void setCoverScale(double scale) {
    final normalized = scale.clamp(0.5, 2.0).toDouble();
    AppPreference.instance.taskbarCoverScale = normalized;
    _coverScale = normalized;
    if (_enabled) unawaited(_syncCoverScale());
    unawaited(AppPreference.instance.save());
  }

  /// 窗口已经藏起后，把 Flutter 绘制表面缩成 1 像素，丢掉整窗大小的显存缓冲。
  Future<void> parkRenderSurface() async {
    if (!Platform.isWindows || !_initialized) return;
    try {
      await _channel.invokeMethod<void>('parkRenderSurface');
    } catch (error, stackTrace) {
      log.app.warn(
        'legacy',
        '[taskbar-thumbnail] park render surface error: $error\n$stackTrace',
      );
    }
  }

  /// 窗口重新显示前，把绘制表面恢复成客户区大小。
  Future<void> restoreRenderSurface() async {
    if (!Platform.isWindows || !_initialized) return;
    try {
      await _channel.invokeMethod<void>('restoreRenderSurface');
    } catch (error, stackTrace) {
      log.app.warn(
        'legacy',
        '[taskbar-thumbnail] restore render surface error: $error\n$stackTrace',
      );
    }
  }

  /// 释放整窗大小的任务栏预览位图，保留 512 封面源图，窗口回来后按当前比例重画。
  void releasePreviewBitmap() {
    if (!_initialized || !_enabled) return;
    unawaited(_releasePreviewBitmap());
  }

  Future<void> _releasePreviewBitmap() async {
    try {
      await _channel.invokeMethod<void>('releasePreviewBitmap');
    } catch (error, stackTrace) {
      log.app.warn('legacy', '[taskbar-thumbnail] release preview bitmap error: $error\n$stackTrace');
    }
  }

  void refreshNowPlaying() {
    if (!_initialized) return;
    unawaited(_setTitle());
    unawaited(_setControls());
    if (!_coverPreviewEnabled) return;
    final generation = ++_coverGeneration;
    unawaited(_updateCoverFor(_nowPlayingNotifier?.value, generation));
  }

  void _onNowPlayingChanged() {
    refreshNowPlaying();
  }

  // 切歌后马上最小化时，预览也要换成当前这首，不能把刚画好的封面清掉。
  void _onFramesEnabledChanged() {
    final framesEnabled = WindowRenderGate.instance.framesEnabled.value;
    if (framesEnabled == _lastFramesEnabled) return;
    _lastFramesEnabled = framesEnabled;
    refreshNowPlaying();
  }

  void _onPlaylistChanged() {
    if (!_enabled) return;
    unawaited(_setControls());
  }

  void _onPlayerStateChanged() {
    if (!_enabled) return;
    unawaited(_setPlaying());
  }

  Future<void> _setPlaying() async {
    try {
      await _channel.invokeMethod<void>('setPlaying', {
        'playing': _playerStateNotifier?.value == PlayerState.playing,
      });
    } catch (error, stackTrace) {
      log.app.warn('legacy', '[taskbar-thumbnail] set playing error: $error\n$stackTrace');
    }
  }

  Future<void> _syncPlaybackControlsEnabled() async {
    if (!_enabled) return;
    try {
      await _channel.invokeMethod<void>('setPlaybackControlsEnabled', {
        'enabled': _playbackControlsEnabled,
      });
    } catch (error, stackTrace) {
      log.app.warn('legacy', '[taskbar-thumbnail] set playback controls error: $error\n$stackTrace',);
    }
  }

  Future<void> _syncCoverScale() async {
    if (!_enabled) return;
    try {
      await _channel.invokeMethod<void>('setCoverScale', {
        'scale': _coverScale,
      });
    } catch (error, stackTrace) {
      log.app.warn('legacy', '[taskbar-thumbnail] set cover scale error: $error\n$stackTrace',);
    }
  }

  Future<void> _setControls() async {
    if (!_enabled) return;
    try {
      final hasTrack = _nowPlayingNotifier?.value != null;
      await _channel.invokeMethod<void>('setControls', {
        'hasTrack': hasTrack,
        'canSkip': hasTrack && (_playlistNotifier?.value.length ?? 0) > 1,
      });
    } catch (error, stackTrace) {
      log.app.warn('legacy', '[taskbar-thumbnail] set controls error: $error\n$stackTrace');
    }
  }

  Future<void> _setTitle() async {
    if (!_enabled) return;
    try {
      await _channel.invokeMethod<void>('setTitle', {
        'title': _nowPlayingNotifier?.value?.title ?? '',
      });
    } catch (error, stackTrace) {
      log.app.warn('legacy', '[taskbar-thumbnail] set title error: $error\n$stackTrace');
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != 'control' || call.arguments is! String) return;
    final playback = PlayService.instance.playbackService;
    switch (call.arguments as String) {
      case 'previous':
        playback.lastAudio();
      case 'playPause':
        if (playback.playerState == PlayerState.playing) {
          playback.pause();
        } else {
          playback.start();
        }
      case 'next':
        playback.nextAudio();
    }
  }

  Future<void> _enable() async {
    if (_enabled || _pendingEnable) return;
    _pendingEnable = true;
    final generation = ++_lifecycleGeneration;
    try {
      final enabled = await _channel.invokeMethod<bool>('enable') ?? false;
      if (generation != _lifecycleGeneration) {
        if (enabled) unawaited(_channel.invokeMethod<void>('disable'));
        return;
      }
      if (!enabled) {
        log.app.warn('legacy', '[taskbar-thumbnail] enable failed');
        return;
      }
      _enabled = true;
      unawaited(_syncPlaybackControlsEnabled());
      unawaited(_syncCoverScale());
      unawaited(_setTitle());
      unawaited(_setControls());
      if (_coverPreviewEnabled) unawaited(_activateCoverPreview());
      _onPlayerStateChanged();
    } catch (error, stackTrace) {
      log.app.warn('legacy', '[taskbar-thumbnail] enable error: $error\n$stackTrace');
    } finally {
      if (generation == _lifecycleGeneration) _pendingEnable = false;
    }
  }

  Future<void> _activateCoverPreview() async {
    if (!_enabled || !_coverPreviewEnabled) return;
    final generation = ++_coverGeneration;
    await _pushDefaultCover(() => _isCurrentCover(generation));
    if (!_isCurrentCover(generation)) return;
    if (!await _setNativeCoverPreview(true) || !_isCurrentCover(generation)) {
      return;
    }
    unawaited(_updateCoverFor(_nowPlayingNotifier?.value, generation));
  }

  Future<bool> _setNativeCoverPreview(bool enabled) async {
    try {
      return await _channel.invokeMethod<bool>('setCoverPreview', {
            'enabled': enabled,
          }) ??
          false;
    } catch (error, stackTrace) {
      log.app.warn('legacy', '[taskbar-thumbnail] set cover preview error: $error\n$stackTrace',);
      return false;
    }
  }

  void _disable() {
    final shouldDisable = _enabled || _pendingEnable;
    _lifecycleGeneration++;
    _coverGeneration++;
    _enabled = false;
    _pendingEnable = false;
    if (shouldDisable) unawaited(_invokeDisable());
  }

  Future<void> _invokeDisable() async {
    try {
      await _channel.invokeMethod<void>('disable');
    } catch (error, stackTrace) {
      log.app.warn('legacy', '[taskbar-thumbnail] disable error: $error\n$stackTrace');
    }
  }

  bool _isCurrentCover(int generation) =>
      _enabled && _coverPreviewEnabled && generation == _coverGeneration;

  Future<void> _updateCoverFor(Audio? audio, int generation) async {
    if (!_isCurrentCover(generation)) return;
    try {
      if (audio == null) {
        await _pushDefaultCover(() => _isCurrentCover(generation));
        return;
      }
      final cachedQuickBytes = audio.smallCoverBytes;
      final quickFuture = cachedQuickBytes != null
          ? Future<Uint8List?>.value(cachedQuickBytes)
          : audio.loadSmallCoverBytes();
      final fullFuture = _loadFullCover(audio.path);
      final quickBytes = await quickFuture;
      if (!_isCurrentCover(generation)) return;
      final quickPushed =
          quickBytes != null &&
          await _pushCoverBytes(quickBytes, generation, _quickCoverSize);
      final fullBytes = await fullFuture;
      if (!_isCurrentCover(generation)) return;
      final fullPushed =
          fullBytes != null &&
          await _pushCoverBytes(fullBytes, generation, _coverSize);
      if (!quickPushed && !fullPushed) {
        await _pushDefaultCover(() => _isCurrentCover(generation));
      }
    } catch (error, stackTrace) {
      log.app.warn('legacy', '[taskbar-thumbnail] cover update error: $error\n$stackTrace');
    }
  }

  Future<Uint8List?> _loadFullCover(String path) async {
    try {
      return await CoverImageCache.instance.loadPhysicalBytes(
        path: path,
        width: _coverSize,
        height: _coverSize,
      );
    } catch (error, stackTrace) {
      log.app.warn('legacy', '[taskbar-thumbnail] cover load error: $error\n$stackTrace');
      return null;
    }
  }

  Future<bool> _pushCoverBytes(
    Uint8List bytes,
    int generation,
    int targetSize,
  ) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          final codec = await _openCoverCodec(descriptor, targetSize);
          try {
            final source = (await codec.getNextFrame()).image;
            try {
              final bgra = await _imageToBgra(source);
              if (!_isCurrentCover(generation)) return false;
              await _channel.invokeMethod<void>('setCover', {
                'bgra': bgra,
                'width': source.width,
                'height': source.height,
              });
              return true;
            } finally {
              source.dispose();
            }
          } finally {
            codec.dispose();
          }
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } catch (error, stackTrace) {
      log.app.warn('legacy', '[taskbar-thumbnail] cover decode error: $error\n$stackTrace');
      return false;
    }
  }

  // 只有原图比目标大时才按长边缩小解码，小图保持原尺寸，也不把封面拉成正方形。
  Future<ui.Codec> _openCoverCodec(
    ui.ImageDescriptor descriptor,
    int targetSize,
  ) {
    final width = descriptor.width;
    final height = descriptor.height;
    if (width <= targetSize && height <= targetSize) {
      return descriptor.instantiateCodec();
    }
    final scale = targetSize / (width > height ? width : height);
    return descriptor.instantiateCodec(
      targetWidth: (width * scale).round().clamp(1, targetSize).toInt(),
      targetHeight: (height * scale).round().clamp(1, targetSize).toInt(),
    );
  }

  /// 无歌曲或无封面时推送主题色占位位图，避免任务栏空白
  Future<void> _pushDefaultCover(bool Function() isCurrent) async {
    try {
      final scheme = ThemeProvider.instance.currScheme;
      final bg = scheme.primaryContainer.toARGB32();
      final fg = scheme.onPrimaryContainer.toARGB32();
      final pixels = Uint8List(_fallbackCoverSize * _fallbackCoverSize * 4);
      for (var i = 0; i < pixels.length; i += 4) {
        pixels[i] = bg & 0xFF;
        pixels[i + 1] = (bg >> 8) & 0xFF;
        pixels[i + 2] = (bg >> 16) & 0xFF;
        pixels[i + 3] = 0xFF;
      }
      // 中央圆形占位
      const cx = _fallbackCoverSize ~/ 2;
      const cy = _fallbackCoverSize ~/ 2;
      const r = _fallbackCoverSize ~/ 4;
      for (var y = 0; y < _fallbackCoverSize; y++) {
        for (var x = 0; x < _fallbackCoverSize; x++) {
          final dx = x - cx;
          final dy = y - cy;
          if (dx * dx + dy * dy > r * r) continue;
          final i = (y * _fallbackCoverSize + x) * 4;
          pixels[i] = fg & 0xFF;
          pixels[i + 1] = (fg >> 8) & 0xFF;
          pixels[i + 2] = (fg >> 16) & 0xFF;
        }
      }
      if (!isCurrent()) return;
      await _channel.invokeMethod<void>('setCover', {
        'bgra': pixels,
        'width': _fallbackCoverSize,
        'height': _fallbackCoverSize,
      });
    } catch (error, stackTrace) {
      log.app.warn('legacy', '[taskbar-thumbnail] default cover error: $error\n$stackTrace');
    }
  }

  /// 原始 RGBA 数据转 BGRA（DWM 的 32bpp DIBSection 使用 BGRA）
  Future<Uint8List> _imageToBgra(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final bgra = Uint8List(bytes.length);
    for (var i = 0; i < bytes.length; i += 4) {
      bgra[i] = bytes[i + 2];
      bgra[i + 1] = bytes[i + 1];
      bgra[i + 2] = bytes[i];
      bgra[i + 3] = bytes[i + 3];
    }
    return bgra;
  }

  void dispose() {
    _disable();
    _channel.setMethodCallHandler(null);
    _initialized = false;
    _nowPlayingNotifier?.removeListener(_onNowPlayingChanged);
    _nowPlayingNotifier = null;
    _playerStateNotifier?.removeListener(_onPlayerStateChanged);
    _playerStateNotifier = null;
    _playlistNotifier?.removeListener(_onPlaylistChanged);
    _playlistNotifier = null;
    WindowRenderGate.instance.framesEnabled.removeListener(
      _onFramesEnabledChanged,
    );
  }
}
