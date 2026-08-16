// ignore_for_file: camel_case_types

import 'dart:ui';

import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/window_lifecycle.dart';
import 'package:pure_music/component/horizontal_lyric_view.dart';
import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/component/search_dialog.dart';
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
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: AppType.subtitle,
                        ),
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
              const SizedBox(width: 80, child: Center(child: NavBackBtn())),
              Expanded(
                child: DragToMoveArea(
                  child: Row(
                    children: [
                      Text(
                        'Pure Music',
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: AppType.subtitle,
                        ),
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
                    RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
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
                              Image.asset(
                                'app_icon.ico',
                                width: 24,
                                height: 24,
                              ),
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
              if (states.contains(WidgetState.pressed)) {
                return scheme.onSurface.withValues(alpha: 0.15);
              }
              if (states.contains(WidgetState.hovered)) {
                return scheme.onSurface.withValues(alpha: 0.10);
              }
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
              if (states.contains(WidgetState.pressed)) {
                return scheme.onSurface.withValues(alpha: 0.15);
              }
              if (states.contains(WidgetState.hovered)) {
                return scheme.onSurface.withValues(alpha: 0.10);
              }
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
          onPressed: WindowLifecycleService.instance.requestClose,
          icon: const Icon(Symbols.close),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 46, minHeight: 40),
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) {
                return scheme.error.withValues(alpha: 0.30);
              }
              if (states.contains(WidgetState.hovered)) {
                return scheme.error.withValues(alpha: 0.20);
              }
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
