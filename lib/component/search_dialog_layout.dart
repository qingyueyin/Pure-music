import 'package:flutter/material.dart';
import 'package:pure_music/core/design_tokens.dart';

class SearchDialogFrame extends StatelessWidget {
  const SearchDialogFrame({
    super.key,
    required this.title,
    required this.child,
  });

  final Widget title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 64).clamp(280.0, 900.0).toDouble();
    final height = (size.height - 180).clamp(300.0, 720.0).toDouble();

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: title,
      content: SizedBox(width: width, height: height, child: child),
    );
  }
}

class SearchCategoryButton extends StatelessWidget {
  const SearchCategoryButton({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
    this.count,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onPressed;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text(
              '$count',
              style: TextStyle(
                color: selected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
                fontSize: AppType.caption,
                fontWeight: AppType.weightMedium,
              ),
            ),
          ],
        ],
      ),
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(
          selected ? scheme.onSecondaryContainer : scheme.onSurface,
        ),
        backgroundColor: WidgetStatePropertyAll(
          selected ? scheme.secondaryContainer : scheme.surfaceContainerHighest,
        ),
        side: WidgetStatePropertyAll(
          BorderSide(color: selected ? scheme.primary : scheme.outline),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
    );
  }
}
