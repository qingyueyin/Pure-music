import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';

/// 设置分组入口行：图标 + 组名 + 描述 + 箭头
class SettingsGroupEntry extends StatelessWidget {
  const SettingsGroupEntry({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: AppRadius.mdCircular,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.mdCircular,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer.withValues(alpha: 0.5),
                  borderRadius: AppRadius.smCircular,
                ),
                child: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: AppType.subtitle,
                        fontWeight: AppType.weightSemibold,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: AppType.caption,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Symbols.chevron_right, size: 20, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}
