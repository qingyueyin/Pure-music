import 'package:flutter/material.dart';

Future<bool> showDangerConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  Widget? details,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => DangerConfirmDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      details: details,
    ),
  );

  return result ?? false;
}

class DangerConfirmDialog extends StatelessWidget {
  const DangerConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.details,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final Widget? details;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message),
          if (details != null) ...[
            const SizedBox(height: 12.0),
            details!,
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
