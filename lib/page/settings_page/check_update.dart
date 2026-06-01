import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:github/github.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/native/rust/api/utils.dart' as rust_utils;
import 'package:pure_music/core/utils.dart';

class CheckForUpdate extends StatefulWidget {
  const CheckForUpdate({super.key});

  @override
  State<CheckForUpdate> createState() => _CheckForUpdateState();
}

class _CheckForUpdateState extends State<CheckForUpdate> {
  bool isChecking = false;

  static int compareSemVer(String a, String b) {
    final cleanA = a.replaceAll(RegExp(r'[^0-9.]'), '');
    final cleanB = b.replaceAll(RegExp(r'[^0-9.]'), '');

    final partsA = cleanA.split('.').where((s) => s.isNotEmpty).toList();
    final partsB = cleanB.split('.').where((s) => s.isNotEmpty).toList();

    final maxLen = partsA.length > partsB.length ? partsA.length : partsB.length;

    for (int i = 0; i < maxLen; i++) {
      final numA = i < partsA.length ? int.tryParse(partsA[i]) ?? 0 : 0;
      final numB = i < partsB.length ? int.tryParse(partsB[i]) ?? 0 : 0;
      if (numA != numB) return numA.compareTo(numB);
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '当前版本',
      subtitle: AppSettings.version,
      action: FilledButton.icon(
        icon: isChecking
            ? const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Symbols.update),
        label: const Text('检查更新'),
        onPressed: isChecking
            ? null
            : () async {
                setState(() => isChecking = true);

                try {
                  final newest = await AppSettings.github.repositories
                      .listReleases(
                        RepositorySlug.full(AppPreference.instance.updateRepoSlug),
                      )
                      .first;
                  final newestTag = newest.tagName ?? '';
                  const currVer = AppSettings.version;

                  if (!context.mounted) return;
                  if (compareSemVer(newestTag, currVer) > 0) {
                    showDialog(
                      context: context,
                      builder: (context) => NewestUpdateView(release: newest),
                    );
                  } else {
                    showTextOnSnackBar('无新版本');
                  }
                } catch (err, trace) {
                  logger.e(err, stackTrace: trace);
                  if (context.mounted) showTextOnSnackBar('网络异常');
                }

                if (mounted) setState(() => isChecking = false);
              },
      ),
    );
  }
}

class NewestUpdateView extends StatelessWidget {
  const NewestUpdateView({
    super.key,
    required this.release,
  });

  final Release release;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    release.name ?? '新版本',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 18.0,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 16.0),
                  Text(
                    '${release.tagName}\n${release.publishedAt}',
                    style: TextStyle(color: scheme.onSurface),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Markdown(
                data: release.body ?? '',
                onTapLink: (text, href, title) {
                  if (href != null) {
                    rust_utils.launchInBrowser(uri: href);
                  }
                },
                padding: EdgeInsets.zero,
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                    },
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 16.0),
                  TextButton.icon(
                    onPressed: () {
                      if (release.htmlUrl != null) {
                        rust_utils.launchInBrowser(uri: release.htmlUrl!);
                      }
                      Navigator.pop(context);
                    },
                    icon: const Icon(Symbols.arrow_outward),
                    label: const Text('获取更新'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
