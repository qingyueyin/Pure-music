// ignore_for_file: camel_case_types

import 'dart:ui';

import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/component/horizontal_lyric_view.dart';
import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/component/search_dialog.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:window_manager/window_manager.dart';

class TitleBar extends StatelessWidget {
  static final _blurFilter = ImageFilter.blur(sigmaX: 20, sigmaY: 20);

  const TitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    return ResponsiveBuilder(
      builder: (context, screenType) {
        switch (screenType) {
          case ScreenType.small:
            return const _TitleBar_Small();
          case ScreenType.medium:
            return const _TitleBar_Medium();
          case ScreenType.large:
            return const _TitleBar_Large();
        }
      },
    );
  }
}

class _TitleBar_Small extends StatelessWidget {
  const _TitleBar_Small();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ClipRect(
      child: BackdropFilter(
        filter: TitleBar._blurFilter,
        child: Container(
          color: scheme.surface.withAlpha(31),
          height: 56.0,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Row(
              children: [
                const _OpenDrawerBtn(),
                const SizedBox(width: 8.0),
                const NavBackBtn(),
                Expanded(
                  child: DragToMoveArea(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: Text(
                        'Pure Music',
                        style: TextStyle(color: scheme.onSurface, fontSize: AppType.subtitle),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '搜索',
                  onPressed: () => SearchDialog.show(context),
                  style: ButtonStyle(
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: AppRadius.smCircular,
                      ),
                    ),
                  ),
                  icon: const Icon(Symbols.search),
                ),
                const WindowControlls(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TitleBar_Medium extends StatelessWidget {
  const _TitleBar_Medium();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ClipRect(
      child: BackdropFilter(
        filter: TitleBar._blurFilter,
        child: Container(
          color: scheme.surface.withAlpha(31),
          child: Row(
            children: [
              const SizedBox(
                width: 80,
                child: Center(child: NavBackBtn()),
              ),
              Expanded(
                child: DragToMoveArea(
                  child: Row(
                    children: [
                      Text(
                        'Pure Music',
                        style: TextStyle(color: scheme.onSurface, fontSize: AppType.subtitle),
                      ),
                      const Expanded(
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 16.0,
                            vertical: 8.0,
                          ),
                          child: HorizontalLyricView(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: '搜索',
                onPressed: () => SearchDialog.show(context),
                style: ButtonStyle(
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(
                      borderRadius: AppRadius.smCircular,
                    ),
                  ),
                ),
                icon: const Icon(Symbols.search),
              ),
              const WindowControlls(),
              const SizedBox(width: 8.0),
            ],
          ),
        ),
      ),
    );
  }
}

class _TitleBar_Large extends StatelessWidget {
  const _TitleBar_Large();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ClipRect(
      child: BackdropFilter(
        filter: TitleBar._blurFilter,
        child: Container(
          color: scheme.surface.withAlpha(31),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Row(
              children: [
                const NavBackBtn(),
                const SizedBox(width: 8.0),
                Expanded(
                  child: DragToMoveArea(
                    child: Row(
                      children: [
                        SizedBox(
                          width: 200,
                          child: Row(
                            children: [
                              Image.asset('app_icon.ico', width: 24, height: 24),
                              const SizedBox(width: 8.0),
                              Text(
                                'Pure Music',
                                style: TextStyle(
                                  color: scheme.onSurface,
                                  fontSize: AppType.subtitle,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Expanded(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(16, 8.0, 16.0, 8.0),
                            child: HorizontalLyricView(compact: true),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '搜索',
                  onPressed: () => SearchDialog.show(context),
                  style: ButtonStyle(
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: AppRadius.smCircular,
                      ),
                    ),
                  ),
                  icon: const Icon(Symbols.search),
                ),
                const WindowControlls(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OpenDrawerBtn extends StatelessWidget {
  const _OpenDrawerBtn();

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '打开导航栏',
      onPressed: Scaffold.of(context).openDrawer,
      icon: const Icon(Symbols.side_navigation),
    );
  }
}

class NavBackBtn extends StatelessWidget {
  const NavBackBtn({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '返回',
      onPressed: () {
        if (context.canPop()) {
          context.pop();
        }
      },
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
        ),
      ),
      icon: const Icon(Symbols.navigate_before),
    );
  }
}

class WindowControlls extends StatefulWidget {
  const WindowControlls({super.key});

  @override
  State<WindowControlls> createState() => _WindowControllsState();
}

class _WindowControllsState extends State<WindowControlls> with WindowListener {
  bool _isMaximized = false;
  bool _isProcessing = false;
  bool _isClosing = false;

  Future<void> _withTimeout(Future<void> future, Duration duration, String name) async {
    try {
      await future.timeout(duration);
    } catch (e) {
      logger.w('$name timeout or error: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _updateWindowStates();
  }

  Future<void> _updateWindowStates() async {
    final isMaximized = await windowManager.isMaximized();
    if (mounted) {
      setState(() {
        _isMaximized = isMaximized;
        _isProcessing = false;
      });
    }
  }

  Future<void> _toggleMaximized() async {
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      if (_isMaximized) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    } catch (e) {
      rethrow;
    } finally {
      if (mounted) {
        await _updateWindowStates();
      }
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _shutdownAndExit() async {
    if (_isClosing) return;
    _isClosing = true;

    try {
      // 1. 先保存窗口状态（窗口必须可见才能获取正确尺寸）
      try {
        await _withTimeout(AppSettings.instance.saveSettings(), const Duration(seconds: 1), 'saveSettings');
      } catch (e) {
        logger.w('saveSettings error: $e');
      }

      // 2. 隐藏窗口，给用户即时反馈
      try {
        await windowManager.hide().timeout(const Duration(milliseconds: 500));
      } catch (_) {}

      // 3. 快速取消快捷键注册（轻量操作）
      try {
        await HotkeysHelper.unregisterAll().timeout(const Duration(milliseconds: 300));
      } catch (_) {}

      // 4. 关闭播放服务（释放音频资源、销毁 AudioLibrary、清除缓存等）
      try {
        await _withTimeout(PlayService.instance.close(), const Duration(seconds: 3), 'PlayService.close');
      } catch (e) {
        logger.w('PlayService.close error: $e');
      }

      // 5. 执行剩余保存操作（此时 PlayService 已关闭，不会访问已释放的资源）
      try {
        await _withTimeout(savePlaylists(), const Duration(seconds: 2), 'savePlaylists');
      } catch (e) {
        logger.w('savePlaylists error: $e');
      }

      try {
        await _withTimeout(saveLyricSources(), const Duration(seconds: 2), 'saveLyricSources');
      } catch (e) {
        logger.w('saveLyricSources error: $e');
      }

      try {
        await _withTimeout(AppPreference.instance.save(), const Duration(seconds: 1), 'savePreference');
      } catch (e) {
        logger.w('savePreference error: $e');
      }

      // 5. 关闭数据库连接（释放 SQLite 资源）
      try {
        AppDb.instance.dispose();
      } catch (e) {
        logger.w('AppDb.dispose error: $e');
      }

      // 6. 最终销毁窗口
      try {
        await _withTimeout(windowManager.destroy(), const Duration(seconds: 2), 'windowManager.destroy');
      } catch (_) {
        // 如果 destroy 超时，强制退出
        logger.w('windowManager.destroy timeout, force exit');
      }
    } catch (e, trace) {
      // 最后的兜底：确保能退出
      logger.e('_shutdownAndExit error: $e\n$trace');
      try {
        await windowManager.destroy();
      } catch (_) {}
    }
  }

  @override
  void onWindowClose() {
    _shutdownAndExit();
  }

  @override
  void onWindowMaximize() {
    _updateWindowStates();
    AppSettings.instance.saveSettings();
  }

  @override
  void onWindowUnmaximize() {
    _updateWindowStates();
    AppSettings.instance.saveSettings();
  }

  @override
  void onWindowRestore() {
    _updateWindowStates();
    AppSettings.instance.saveSettings();
  }

  @override
  void onWindowResized() async {
    super.onWindowResized();
    if (_isMaximized) return;
    // 移除强制窗口尺寸调整逻辑，允许用户自由调整窗口大小
    // 不再限制窗口不能覆盖任务栏
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '最小化',
          onPressed: windowManager.minimize,
          icon: const Icon(Symbols.remove),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 46, minHeight: 40),
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) return scheme.onSurface.withValues(alpha: 0.15);
              if (states.contains(WidgetState.hovered)) return scheme.onSurface.withValues(alpha: 0.10);
              return Colors.transparent;
            }),
            shape: WidgetStateProperty.all(
              RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
            ),
          ),
        ),
        const SizedBox(width: 12.0),
        IconButton(
          tooltip: _isMaximized ? '还原' : '最大化',
          onPressed: _isProcessing ? null : _toggleMaximized,
          icon: Icon(
            _isMaximized ? Symbols.fullscreen_exit : Symbols.fullscreen,
          ),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 46, minHeight: 40),
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) return scheme.onSurface.withValues(alpha: 0.15);
              if (states.contains(WidgetState.hovered)) return scheme.onSurface.withValues(alpha: 0.10);
              return Colors.transparent;
            }),
            shape: WidgetStateProperty.all(
              RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
            ),
          ),
        ),
        const SizedBox(width: 12.0),
        IconButton(
          tooltip: '关闭',
          onPressed: _shutdownAndExit,
          icon: const Icon(Symbols.close),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 46, minHeight: 40),
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) return scheme.error.withValues(alpha: 0.30);
              if (states.contains(WidgetState.hovered)) return scheme.error.withValues(alpha: 0.20);
              return Colors.transparent;
            }),
            shape: WidgetStateProperty.all(
              RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
            ),
          ),
        ),
      ],
    );
  }
}
