import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/update_checker.dart';
import 'package:pure_music/native/rust/api/utils.dart' as rust_utils;
import 'package:pure_music/core/utils.dart';

Future<void> _launchBrowserUrl(String uri) async {
  final opened = await rust_utils.launchInBrowser(uri: uri);
  if (!opened) {
    showTextOnSnackBar('打开链接失败');
  }
}

class NewestUpdateView extends StatelessWidget {
  const NewestUpdateView({
    super.key,
    required this.info,
  });

  final UpdateInfo info;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48.0).clamp(320.0, 720.0).toDouble();
    final height = (size.height - 96.0).clamp(360.0, 640.0).toDouble();
    final updateUrl = info.htmlUrl?.trim();
    final hasUpdateUrl = updateUrl?.isNotEmpty == true;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 24.0,
        vertical: 24.0,
      ),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '有新更新',
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: AppType.hero,
                  fontWeight: AppType.weightBold,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: Spacing.md),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color:
                        scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: AppRadius.mdCircular,
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Markdown(
                    data: info.body?.trim().isNotEmpty == true
                        ? info.body!
                        : '这个版本暂时没有更新说明。',
                    onTapLink: (text, href, title) {
                      if (href != null) {
                        _launchBrowserUrl(href);
                      }
                    },
                    padding: const EdgeInsets.all(Spacing.md),
                    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
                  ),
                ),
              ),
              const SizedBox(height: Spacing.lg),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: Spacing.sm,
                overflowSpacing: Spacing.sm,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  FilledButton.icon(
                    onPressed: !hasUpdateUrl
                        ? null
                        : () {
                            _launchBrowserUrl(updateUrl!);
                            Navigator.pop(context);
                          },
                    icon: const Icon(Symbols.arrow_outward),
                    label: const Text('获取更新'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
