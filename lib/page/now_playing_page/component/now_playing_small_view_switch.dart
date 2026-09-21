import 'package:flutter/material.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/settings.dart';

/// 未悬停时的图标透明度：能看清去哪一页，又不抢歌词/封面。
const nowPlayingSmallViewSwitchRestOpacity = 0.56;

/// 默认跟光标一起藏；「播放控件常驻」打开后才常显。
bool nowPlayingSmallViewSwitchRevealed({
  required bool alwaysShowControls,
  required bool cursorHidden,
}) => alwaysShowControls || !cursorHidden;

/// 竖屏播放页左右两侧的视图切换条，高度拉满内容区。
class NowPlayingSmallViewSwitch extends StatefulWidget {
  const NowPlayingSmallViewSwitch({
    super.key,
    required this.onTap,
    required this.icon,
    this.tooltip,
    this.revealed = true,
    this.busy = false,
    this.enabled = true,
  });

  final VoidCallback onTap;
  final IconData icon;
  final String? tooltip;
  final bool revealed;
  final bool busy;
  final bool enabled;

  @override
  State<NowPlayingSmallViewSwitch> createState() =>
      _NowPlayingSmallViewSwitchState();
}

class _NowPlayingSmallViewSwitchState extends State<NowPlayingSmallViewSwitch> {
  bool _hovered = false;

  Widget _maybeTooltip({required Widget child}) {
    final tooltip = widget.tooltip;
    if (tooltip == null || tooltip.isEmpty) return child;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final iconColor = useMonet ? scheme.primary : scheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: SizedBox(
        width: 40,
        child: Material(
          borderRadius: AppRadius.mdCircular,
          type: MaterialType.transparency,
          child: AnimatedOpacity(
            duration: reduceMotion ? Duration.zero : MotionDuration.fast,
            curve: MotionCurve.standard,
            opacity: !widget.revealed
                ? 0.0
                : (_hovered ? 1.0 : nowPlayingSmallViewSwitchRestOpacity),
            child: AnimatedContainer(
              duration: reduceMotion ? Duration.zero : MotionDuration.fast,
              curve: MotionCurve.standard,
              decoration: BoxDecoration(
                color: _hovered && widget.enabled && widget.revealed
                    ? scheme.onSecondaryContainer.withValues(alpha: 0.06)
                    : Colors.transparent,
                borderRadius: AppRadius.mdCircular,
              ),
              child: InkWell(
                borderRadius: AppRadius.mdCircular,
                hoverColor: scheme.onSecondaryContainer.withValues(alpha: 0.02),
                highlightColor: scheme.onSecondaryContainer.withValues(
                  alpha: 0.04,
                ),
                splashColor: Colors.transparent,
                onTap: widget.enabled ? widget.onTap : null,
                onHover: (hasEntered) {
                  final hovered = hasEntered && widget.enabled;
                  if (_hovered == hovered) return;
                  setState(() => _hovered = hovered);
                },
                child: Center(
                  child: _maybeTooltip(
                    child: widget.busy
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: iconColor,
                            ),
                          )
                        : AnimatedScale(
                            duration: reduceMotion
                                ? Duration.zero
                                : MotionDuration.fast,
                            curve: MotionCurve.standard,
                            scale: _hovered && widget.enabled ? 1.04 : 1.0,
                            child: Icon(
                              widget.icon,
                              color: widget.enabled
                                  ? iconColor
                                  : iconColor.withValues(alpha: 0.38),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
