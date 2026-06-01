import 'package:flutter/material.dart';

class SettingsTile extends StatelessWidget {
  const SettingsTile(
      {super.key, required this.description, required this.action, this.subtitle});

  final String description;
  final String? subtitle;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Column(
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
          ),
        ),
        action,
      ],
    );
  }
}
