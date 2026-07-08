import 'package:flutter/material.dart';

class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.description,
    required this.action,
    this.subtitle,
  });

  final String description;
  final String? subtitle;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth.isFinite && constraints.maxWidth < 560.0;
        final descriptionView = _SettingsTileDescription(
          description: description,
          subtitle: subtitle,
        );

        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              descriptionView,
              const SizedBox(height: 12.0),
              SizedBox(
                width: double.infinity,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: action,
                ),
              ),
            ],
          );
        }

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: descriptionView),
            const SizedBox(width: 16.0),
            action,
          ],
        );
      },
    );
  }
}

class _SettingsTileDescription extends StatelessWidget {
  const _SettingsTileDescription({
    required this.description,
    required this.subtitle,
  });

  final String description;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          description,
          style: TextStyle(color: scheme.onSurface, fontSize: 18.0),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 4.0),
            child: Text(
              subtitle!,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 13.0,
              ),
            ),
          ),
      ],
    );
  }
}
