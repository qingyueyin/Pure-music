import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:flutter/material.dart';

/// title, actions, body
///
/// 提供基本的响应式布局：
///
/// 小屏幕时，标题在上、操作按钮在下，互不挤压；
/// 中大屏幕时，标题和操作按钮在同一行排列。
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    this.subtitle,
    required this.actions,
    required this.body,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 16.0,
        vertical: 8.0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ResponsiveBuilder(
            builder: (context, screenType) {
              return Padding(
                padding: const EdgeInsets.all(16.0),
                child: switch (screenType) {
                  ScreenType.small => _buildSmallLayout(scheme),
                  ScreenType.medium ||
                  ScreenType.large =>
                    _buildWideLayout(scheme),
                },
              );
            },
          ),
          Container(
            height: 10,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  scheme.surfaceContainer.withValues(alpha: 0.08),
                  Colors.transparent,
                ],
              ),
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _buildSmallLayout(ColorScheme scheme) {
    if (actions.isEmpty) {
      return _titleWidget(scheme);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _titleWidget(scheme),
        const SizedBox(height: 16.0),
        Wrap(spacing: 8.0, runSpacing: 8.0, children: actions),
      ],
    );
  }

  Widget _buildWideLayout(ColorScheme scheme) {
    if (actions.isEmpty) {
      return _titleWidget(scheme);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: _titleWidget(scheme)),
        const SizedBox(width: 16.0),
        Flexible(
          child: Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8.0,
              runSpacing: 8.0,
              children: actions,
            ),
          ),
        ),
      ],
    );
  }

  Widget _titleWidget(ColorScheme scheme) {
    if (subtitle == null) {
      return Text(
        title,
        style: TextStyle(
          fontSize: AppType.display,
          fontWeight: AppType.weightSemibold,
          color: scheme.onSurface,
        ),
        overflow: TextOverflow.ellipsis,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: AppType.display,
            fontWeight: AppType.weightSemibold,
            color: scheme.onSurface,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6.0),
        Text(
          subtitle!,
          style: TextStyle(
            fontSize: AppType.body,
            color: scheme.onSurfaceVariant,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
