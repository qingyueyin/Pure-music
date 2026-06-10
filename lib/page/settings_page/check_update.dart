import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/update_checker.dart';
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
                  final newest = await UpdateChecker.checkForUpdate();
                  if (!context.mounted) return;

                  if (newest != null &&
                      UpdateChecker.hasNewVersion(
                          newest.tagName, AppSettings.version)) {
                    if (!context.mounted) return;
                    showDialog(
                      context: context,
                      builder: (context) => NewestUpdateView(info: newest),
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
    required this.info,
  });

  final UpdateInfo info;

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
                    info.name ?? '新版本',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 18.0,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 16.0),
                  Text(
                    info.tagName,
                    style: TextStyle(color: scheme.onSurface),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Markdown(
                data: info.body ?? '',
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
                      if (info.htmlUrl != null) {
                        rust_utils.launchInBrowser(uri: info.htmlUrl!);
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

/// 自动检查更新开关
class AutoUpdateToggle extends StatelessWidget {
  const AutoUpdateToggle({super.key});

  @override
  Widget build(BuildContext context) {
    return StatefulBuilder(
      builder: (context, setState) {
        final enabled = AppPreference.instance.autoCheckUpdate;
        return SettingsTile(
          description: '启动时自动检查更新',
          subtitle: enabled ? '已开启' : '已关闭',
          action: Switch(
            value: enabled,
            onChanged: (value) {
              AppPreference.instance.autoCheckUpdate = value;
              AppPreference.instance.save();
              setState(() {});
            },
          ),
        );
      },
    );
  }
}
