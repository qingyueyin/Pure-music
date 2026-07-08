import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/setting_action_state.dart';
import 'package:pure_music/core/update_checker.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/native/rust/api/utils.dart' as rust_utils;
import 'package:pure_music/core/utils.dart';

Future<void> _launchBrowserUrl(String uri) async {
  final opened = await rust_utils.launchInBrowser(uri: uri);
  if (!opened) {
    showTextOnSnackBar('打开链接失败');
  }
}

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
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Symbols.update),
        label: Text(isChecking ? '检查中' : '检查更新'),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Wrap(
                  spacing: 8.0,
                  runSpacing: 8.0,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      info.name ?? '\u65b0\u7248\u672c',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 18.0,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    _VersionPill(version: info.tagName),
                  ],
                ),
              ),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.3,
                    ),
                    borderRadius: BorderRadius.circular(12.0),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Markdown(
                    data: info.body?.trim().isNotEmpty == true
                        ? info.body!
                        : '\u8fd9\u4e2a\u7248\u672c\u6682\u65f6\u6ca1\u6709\u66f4\u65b0\u8bf4\u660e\u3002',
                    onTapLink: (text, href, title) {
                      if (href != null) {
                        _launchBrowserUrl(href);
                      }
                    },
                    padding: const EdgeInsets.all(12.0),
                    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 16.0),
                child: OverflowBar(
                  alignment: MainAxisAlignment.end,
                  spacing: 8.0,
                  overflowSpacing: 8.0,
                  children: [
                    TextButton(
                      onPressed: () {
                        Navigator.pop(context);
                      },
                      child: const Text('\u53d6\u6d88'),
                    ),
                    FilledButton.icon(
                      onPressed: !hasUpdateUrl
                          ? null
                          : () {
                              _launchBrowserUrl(updateUrl!);
                              Navigator.pop(context);
                            },
                      icon: const Icon(Symbols.arrow_outward),
                      label: const Text('\u83b7\u53d6\u66f4\u65b0'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VersionPill extends StatelessWidget {
  const _VersionPill({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      height: 28.0,
      padding: const EdgeInsets.symmetric(horizontal: 10.0),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(14.0),
      ),
      child: Text(
        version,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontSize: 12.0,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class AutoUpdateToggle extends StatefulWidget {
  const AutoUpdateToggle({super.key});

  @override
  State<AutoUpdateToggle> createState() => _AutoUpdateToggleState();
}

class _AutoUpdateToggleState extends State<AutoUpdateToggle> {
  bool _isSaving = false;

  @override
  Widget build(BuildContext context) {
    final enabled = AppPreference.instance.autoCheckUpdate;
    final canChange = canChangeSetting(isSaving: _isSaving);
    return SettingsTile(
      description: '启动时自动检查更新',
      subtitle: _isSaving
          ? '保存中'
          : enabled
              ? '已开启'
              : '已关闭',
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isSaving) ...[
            const SizedBox(
              width: 16.0,
              height: 16.0,
              child: CircularProgressIndicator(strokeWidth: 2.0),
            ),
            const SizedBox(width: 8.0),
          ],
          Switch(
            value: enabled,
            onChanged: !canChange
                ? null
                : (value) async {
                    setState(() {
                      _isSaving = true;
                      AppPreference.instance.autoCheckUpdate = value;
                    });
                    try {
                      await AppPreference.instance.save();
                    } finally {
                      if (mounted) setState(() => _isSaving = false);
                    }
                  },
          ),
        ],
      ),
    );
  }
}
