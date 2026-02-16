part of 'page.dart';

class _NowPlayingPage_Immersive extends StatelessWidget {
  const _NowPlayingPage_Immersive();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24.0, 8.0, 24.0, 24.0),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.center,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520.0),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _NowPlayingInfo(),
                    SizedBox(height: 24.0),
                    _NowPlayingSlider(),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820.0),
                child: const VerticalLyricView(
                  showControls: false,
                  enableSeekOnTap: false,
                  centerVertically: true,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ImmersiveHelpOverlay extends StatefulWidget {
  const _ImmersiveHelpOverlay();

  @override
  State<_ImmersiveHelpOverlay> createState() => _ImmersiveHelpOverlayState();
}

class _ImmersiveHelpOverlayState extends State<_ImmersiveHelpOverlay> {
  bool _visible = false;
  Timer? _timer;

  void _bump() {
    _timer?.cancel();
    if (!_visible) {
      setState(() {
        _visible = true;
      });
    }
    _timer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() {
        _visible = false;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _showDialog() {
    showDialog<void>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final textStyle = TextStyle(color: scheme.onSurface);
        return AlertDialog(
          title: const Text("快捷键"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Space：播放/暂停", style: textStyle),
              const SizedBox(height: 8),
              Text("Ctrl + ←：上一曲", style: textStyle),
              const SizedBox(height: 8),
              Text("Ctrl + →：下一曲", style: textStyle),
              const SizedBox(height: 8),
              Text("Ctrl + ↑：音量 +", style: textStyle),
              const SizedBox(height: 8),
              Text("Ctrl + ↓：音量 -", style: textStyle),
              const SizedBox(height: 8),
              Text("F1：进入/退出沉浸模式", style: textStyle),
              const SizedBox(height: 8),
              Text("ESC：退出沉浸并回到主界面", style: textStyle),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("关闭"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: MouseRegion(
            onHover: (_) => _bump(),
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          right: 20,
          bottom: 120,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 200),
            curve: Curves.fastOutSlowIn,
            offset: _visible ? Offset.zero : const Offset(0.0, 0.2),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              curve: Curves.fastOutSlowIn,
              opacity: _visible ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !_visible,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Material(
                      color: scheme.secondaryContainer.withOpacity(0.92),
                      borderRadius: BorderRadius.circular(999),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12.0,
                          vertical: 10.0,
                        ),
                        child: Text(
                          "快捷键说明",
                          style: TextStyle(
                            color: scheme.onSecondaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Material(
                      color: scheme.secondaryContainer.withOpacity(0.92),
                      shape: const CircleBorder(),
                      child: IconButton(
                        onPressed: _showDialog,
                        icon: Icon(
                          Symbols.help_outline,
                          color: scheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
