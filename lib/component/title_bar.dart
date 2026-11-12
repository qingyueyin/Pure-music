// ignore_for_file: camel_case_types

import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/update_download_monitor.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/window_lifecycle.dart';
import 'package:pure_music/component/frosted_chrome.dart';
import 'package:pure_music/component/horizontal_lyric_view.dart';
import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/component/search_dialog.dart';
import 'package:pure_music/page/settings_page/check_update.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:window_manager/window_manager.dart';

class TitleBar extends StatelessWidget {
  const TitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings.backgroundNotifier,
      builder: (context, _) {
        return ResponsiveBuilder(
          builder: (context, screenType) {
            final frosted = AppSettings.instance.enableTitleBarFrostedGlass;
            switch (screenType) {
              case ScreenType.small:
                return _TitleBar_Small(frosted: frosted);
              case ScreenType.medium:
                return _TitleBar_Medium(frosted: frosted);
              case ScreenType.large:
                return _TitleBar_Large(frosted: frosted);
            }
          },
        );
      },
    );
  }
}

class _TitleBar_Small extends StatelessWidget {
  const _TitleBar_Small({required this.frosted});

  final bool frosted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return FrostedChrome(
      enabled: frosted,
      height: 56.0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: Row(
          children: [
            const _OpenDrawerBtn(),
            const SizedBox(width: 8.0),
            const NavBackBtn(),
            Expanded(child: _UpdateAwareSlot(child: _smallTitle(scheme))),
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
          ],
        ),
      ),
    );
  }

  Widget _smallTitle(ColorScheme scheme) {
    return DragToMoveArea(
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
    );
  }


}

class _TitleBar_Medium extends StatelessWidget {
  const _TitleBar_Medium({required this.frosted});

  final bool frosted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return FrostedChrome(
      enabled: frosted,
      child: Row(
        children: [
          const SizedBox(width: 80, child: Center(child: NavBackBtn())),
          Expanded(child: _mediumBrand(scheme)),
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
    );
  }

  Widget _mediumBrand(ColorScheme scheme) {
    return Row(
      children: [
        DragToMoveArea(
          child: Text(
            'Pure Music',
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: AppType.subtitle,
            ),
          ),
        ),
        const _TitleLyricSlot(
          padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        ),
      ],
    );
  }


}

class _TitleBar_Large extends StatelessWidget {
  const _TitleBar_Large({required this.frosted});

  final bool frosted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FrostedChrome(
      enabled: frosted,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: Row(
          children: [
            const NavBackBtn(),
            const SizedBox(width: 8.0),
            Expanded(child: _dragArea(scheme)),
            _searchButton(context),
            const WindowControlls(),
          ],
        ),
      ),
    );
  }


  Widget _largeBrand(ColorScheme scheme) {
    return Row(
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
    );
  }

  Widget _dragArea(ColorScheme scheme) {
    return Row(
      children: [
        DragToMoveArea(
          child: SizedBox(width: 200, child: _largeBrand(scheme)),
        ),
        const _TitleLyricSlot(
          compact: true,
          padding: EdgeInsets.fromLTRB(16, 8.0, 16.0, 8.0),
        ),
      ],
    );
  }

  Widget _searchButton(BuildContext context) {
    return IconButton(
      tooltip: '搜索',
      onPressed: () => SearchDialog.show(context),
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
        ),
      ),
      icon: const Icon(Symbols.search),
    );
  }
}


class _TitleLyricSlot extends StatelessWidget {
  const _TitleLyricSlot({this.compact = false, required this.padding});

  final bool compact;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      // 不用 DragToMoveArea：它的双击识别会让单击等待 300ms，搜索因此慢半拍
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) => windowManager.startDragging(),
        child: Padding(
          padding: padding,
          child: _UpdateAwareSlot(
            child: HorizontalLyricView(compact: compact),
          ),
        ),
      ),
    );
  }
}

class _UpdateAwareSlot extends StatelessWidget {
  const _UpdateAwareSlot({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: UpdateDownloadMonitor.instance,
      builder: (context, _) {
        if (!UpdateDownloadMonitor.instance.visible) return child;
        return const Align(
          alignment: Alignment.centerLeft,
          child: UpdateTitleStatus(),
        );
      },
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
  void onWindowResized() {
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
        _windowButton(
          tooltip: '最小化',
          onPressed: windowManager.minimize,
          icon: const Icon(Symbols.remove),
          hover: scheme.onSurface,
        ),
        const SizedBox(width: 12.0),
        _windowButton(
          tooltip: _isMaximized ? '还原' : '最大化',
          onPressed: _isProcessing ? null : _toggleMaximized,
          icon: Icon(
            _isMaximized ? Symbols.fullscreen_exit : Symbols.fullscreen,
          ),
          hover: scheme.onSurface,
        ),
        const SizedBox(width: 12.0),
        _windowButton(
          tooltip: '关闭',
          onPressed: WindowLifecycleService.instance.requestClose,
          icon: const Icon(Symbols.close),
          hover: scheme.error,
          pressedAlpha: 0.30,
          hoverAlpha: 0.20,
        ),
      ],
    );
  }

  Widget _windowButton({
    required String tooltip,
    required VoidCallback? onPressed,
    required Widget icon,
    required Color hover,
    double pressedAlpha = 0.15,
    double hoverAlpha = 0.10,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: icon,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 46, minHeight: 40),
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) {
            return hover.withValues(alpha: pressedAlpha);
          }
          if (states.contains(WidgetState.hovered)) {
            return hover.withValues(alpha: hoverAlpha);
          }
          return Colors.transparent;
        }),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
        ),
      ),
    );
  }
}
