import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/update_checker.dart';
import 'package:pure_music/core/update_installer.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/native/rust/api/utils.dart' as rust_utils;

Future<void> _launchBrowserUrl(String uri) async {
  final opened = await rust_utils.launchInBrowser(uri: uri);
  if (!opened) {
    showTextOnSnackBar('打开链接失败');
  }
}

Future<UpdateChannel?> _showUpdateChannelDialog(
  BuildContext context, {
  UpdateChannel? selected,
}) => showDialog<UpdateChannel>(
  context: context,
  barrierDismissible: false,
  builder: (dialogContext) {
    var current = selected;
    return StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('选择更新渠道'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioGroup<UpdateChannel>(
              groupValue: current,
              onChanged: (value) => setDialogState(() => current = value),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<UpdateChannel>(
                    value: UpdateChannel.github,
                    title: Text(UpdateChannel.github.label),
                    subtitle: const Text('从 GitHub 获取版本和安装包'),
                  ),
                  RadioListTile<UpdateChannel>(
                    value: UpdateChannel.gitee,
                    title: Text(UpdateChannel.gitee.label),
                    subtitle: const Text('从 Gitee 获取版本和安装包'),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: current == null
                ? null
                : () => Navigator.pop(dialogContext, current),
            child: const Text('继续'),
          ),
        ],
      ),
    );
  },
);

Future<UpdateChannel?> ensureUpdateChannel(BuildContext context) async {
  final preference = AppPreference.instance;
  final saved = UpdateChannel.parse(preference.updateChannel);
  if (saved != null) return saved;

  final selected = await _showUpdateChannelDialog(context);
  if (selected == null) return null;
  preference.updateChannel = selected.name;
  if (!await preference.save()) {
    preference.updateChannel = null;
    showTextOnSnackBar('保存更新渠道失败', variant: ToastVariant.error);
    return null;
  }
  return selected;
}

Future<bool> chooseAndSaveUpdateChannel(BuildContext context) async {
  final preference = AppPreference.instance;
  final previous = UpdateChannel.parse(preference.updateChannel);
  final selected = await _showUpdateChannelDialog(context, selected: previous);
  if (selected == null || selected == previous) return selected != null;

  preference.updateChannel = selected.name;
  final saved = await preference.save();
  if (!saved) {
    preference.updateChannel = previous?.name;
    showTextOnSnackBar('保存更新渠道失败', variant: ToastVariant.error);
  }
  return saved;
}

String _formatMb(int bytes) {
  if (bytes <= 0) return '0 MB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

enum _UpdatePhase {
  idle,
  downloading,
  preparing,
  verifying,
  installing,
  switchingChannel,
  error,
}

class NewestUpdateView extends StatefulWidget {
  const NewestUpdateView({
    super.key,
    required this.info,
    required this.channel,
  });

  final UpdateInfo info;
  final UpdateChannel channel;

  @override
  State<NewestUpdateView> createState() => _NewestUpdateViewState();
}

class _NewestUpdateViewState extends State<NewestUpdateView> {
  _UpdatePhase _phase = _UpdatePhase.idle;
  int _received = 0;
  int _total = 0;
  CancelToken? _cancelToken;
  late UpdateInfo _info;
  late UpdateChannel _channel;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _info = widget.info;
    _channel = widget.channel;
  }

  String? get _updateUrl {
    final url = _info.releasePageUrl(_channel)?.trim();
    if (url == null || url.isEmpty) return null;
    return url;
  }

  Future<void> _startUpdate() async {
    if (_phase != _UpdatePhase.idle && _phase != _UpdatePhase.error) return;
    final downloadUrl = _info.downloadUrl(
      channel: _channel,
      portableBuild: portableBuild,
    );
    if (downloadUrl == null || downloadUrl.isEmpty) {
      if (_updateUrl != null) {
        await _openReleasePage();
        if (!mounted) return;
        Navigator.pop(context);
      } else if (mounted) {
        showTextOnSnackBar('缺少下载地址', variant: ToastVariant.error);
      }
      return;
    }

    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    setState(() {
      _phase = _UpdatePhase.downloading;
      _errorMessage = null;
      _received = 0;
      _total = _info.downloadSize(portableBuild: portableBuild) ?? 0;
    });

    try {
      final outcome = await UpdateInstaller.run(
        info: _info,
        channel: _channel,
        cancelToken: cancelToken,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            if (total > 0) _total = total;
          });
        },
        onPhase: (phase) {
          if (!mounted) return;
          setState(() {
            if (phase == '正在解压更新') {
              _phase = _UpdatePhase.preparing;
            } else if (phase == '正在校验') {
              _phase = _UpdatePhase.verifying;
            } else if (phase == '正在启动安装程序') {
              _phase = _UpdatePhase.installing;
            } else if (phase == '正在切换版本') {
              _phase = _UpdatePhase.installing;
            } else {
              _phase = _UpdatePhase.downloading;
            }
          });
        },
      );
      if (outcome == UpdateInstallOutcome.portableStarted && mounted) {
        Navigator.pop(context);
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        if (mounted) setState(() => _phase = _UpdatePhase.idle);
        return;
      }
      await _fail(e.message ?? '更新失败');
    } on UpdateInstallException catch (e) {
      await _fail(e.message);
    } catch (_) {
      await _fail('更新失败');
    }
  }

  Future<void> _openReleasePage() async {
    final updateUrl = _updateUrl;
    if (updateUrl == null) return;
    await _launchBrowserUrl(updateUrl);
  }

  Future<void> _fail(String message) async {
    if (!mounted) return;
    setState(() {
      _phase = _UpdatePhase.error;
      _errorMessage = message;
    });
    showTextOnSnackBar(message, variant: ToastVariant.error);
  }

  Future<void> _switchChannelAndRetry() async {
    if (_busy) return;
    final target = _channel.alternate;
    setState(() {
      _phase = _UpdatePhase.switchingChannel;
      _errorMessage = null;
    });

    final preference = AppPreference.instance;
    final previous = preference.updateChannel;
    preference.updateChannel = target.name;
    if (!await preference.save()) {
      preference.updateChannel = previous;
      if (mounted) {
        setState(() {
          _phase = _UpdatePhase.error;
          _errorMessage = '保存更新渠道失败';
        });
      }
      return;
    }

    try {
      final newest = await UpdateChecker.checkForUpdate(channel: target);
      if (newest == null ||
          !UpdateChecker.hasNewVersion(newest.tagName, AppSettings.version)) {
        throw UpdateInstallException('${target.label}暂未提供可用的新版本');
      }
      if (newest
              .downloadUrl(channel: target, portableBuild: portableBuild)
              ?.isNotEmpty !=
          true) {
        throw UpdateInstallException('${target.label}暂未提供对应安装包');
      }
      if (!mounted) return;
      setState(() {
        _channel = target;
        _info = newest;
        _phase = _UpdatePhase.idle;
      });
      await _startUpdate();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _channel = target;
        _phase = _UpdatePhase.error;
        _errorMessage = error is UpdateInstallException
            ? error.message
            : '无法从${target.label}获取更新';
      });
    }
  }

  void _cancel() {
    _cancelToken?.cancel();
  }

  String get _progressLabel {
    final received = _received;
    final total = _total;
    if (total > 0) {
      final percent = ((received / total) * 100).clamp(0, 100).round();
      return '$percent% · ${_formatMb(received)} / ${_formatMb(total)}';
    }
    return _formatMb(received);
  }

  String get _statusLabel {
    switch (_phase) {
      case _UpdatePhase.idle:
        return '准备安装';
      case _UpdatePhase.downloading:
        return '正在下载 $_progressLabel';
      case _UpdatePhase.preparing:
        return '正在解压更新';
      case _UpdatePhase.verifying:
        return '正在校验完整性';
      case _UpdatePhase.installing:
        return '正在启动安装程序';
      case _UpdatePhase.switchingChannel:
        return '正在切换到${_channel.alternate.label}';
      case _UpdatePhase.error:
        return _errorMessage ?? '更新失败';
    }
  }

  bool get _busy =>
      _phase == _UpdatePhase.downloading ||
      _phase == _UpdatePhase.preparing ||
      _phase == _UpdatePhase.verifying ||
      _phase == _UpdatePhase.installing ||
      _phase == _UpdatePhase.switchingChannel;

  bool get _hasDownload =>
      _info
          .downloadUrl(channel: _channel, portableBuild: portableBuild)
          ?.isNotEmpty ==
      true;

  @override
  void dispose() {
    _cancelToken?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48.0).clamp(320.0, 720.0).toDouble();
    final height = (size.height - 96.0).clamp(360.0, 640.0).toDouble();
    final updateUrl = _updateUrl;
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
              const SizedBox(height: Spacing.xs),
              Text(
                '更新渠道：${_channel.label}',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: AppType.body,
                ),
              ),
              const SizedBox(height: Spacing.md),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: AppRadius.mdCircular,
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Markdown(
                    data: _info.body?.trim().isNotEmpty == true
                        ? _info.body!
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
              if (_busy) ...[
                const SizedBox(height: Spacing.md),
                ClipRRect(
                  borderRadius: AppRadius.smCircular,
                  child: LinearProgressIndicator(
                    value: _phase == _UpdatePhase.downloading && _total > 0
                        ? (_received / _total).clamp(0.0, 1.0)
                        : null,
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  _statusLabel,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: AppType.body,
                  ),
                ),
              ],
              if (_phase == _UpdatePhase.error && _errorMessage != null) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  _errorMessage!,
                  style: TextStyle(color: scheme.error, fontSize: AppType.body),
                ),
              ],
              const SizedBox(height: Spacing.lg),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: Spacing.sm,
                overflowSpacing: Spacing.sm,
                children: [
                  TextButton(
                    onPressed: () {
                      if (_busy) {
                        _cancel();
                        return;
                      }
                      Navigator.pop(context);
                    },
                    child: Text(_busy ? '取消' : '关闭'),
                  ),
                  if (_phase == _UpdatePhase.error)
                    OutlinedButton.icon(
                      onPressed: _switchChannelAndRetry,
                      icon: const Icon(Symbols.swap_horiz, size: 18),
                      label: Text('切换到${_channel.alternate.label}'),
                    ),
                  if (!_hasDownload && !hasUpdateUrl)
                    FilledButton.icon(
                      onPressed: null,
                      icon: const Icon(Symbols.arrow_outward),
                      label: const Text('获取更新'),
                    )
                  else if (_busy)
                    FilledButton.icon(
                      onPressed: null,
                      icon: const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      label: const Text('处理中'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _hasDownload
                          ? _startUpdate
                          : () async {
                              await _openReleasePage();
                              if (context.mounted) Navigator.pop(context);
                            },
                      icon: Icon(
                        _hasDownload ? Symbols.download : Symbols.arrow_outward,
                      ),
                      label: Text(
                        _hasDownload
                            ? (portableBuild ? '下载更新' : '下载并安装')
                            : '打开网页',
                      ),
                    ),
                  if (hasUpdateUrl && _hasDownload && !_busy)
                    TextButton.icon(
                      onPressed: () async {
                        await _openReleasePage();
                        if (context.mounted) Navigator.pop(context);
                      },
                      icon: const Icon(Symbols.arrow_outward, size: 18),
                      label: const Text('打开网页'),
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
