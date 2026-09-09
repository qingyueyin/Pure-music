import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/native/rust/api/utils.dart' as rust_utils;
import 'package:pure_music/services/lastfm/lastfm_models.dart';
import 'package:pure_music/services/lastfm/lastfm_service.dart';

class LastFmSettingsPanel extends StatefulWidget {
  const LastFmSettingsPanel({super.key});

  @override
  State<LastFmSettingsPanel> createState() => _LastFmSettingsPanelState();
}

class _LastFmSettingsPanelState extends State<LastFmSettingsPanel> {
  final _apiKeyController = TextEditingController();
  final _secretController = TextEditingController();
  bool _busy = false;
  bool _loaded = false;

  LastFmService get _service => LastFmService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
    _service.ensureLoaded().then((_) {
      if (!mounted) return;
      _syncControllers();
      setState(() => _loaded = true);
    });
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    _apiKeyController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _syncControllers() {
    final credentials = _service.credentials;
    if (_apiKeyController.text != credentials.apiKey) {
      _apiKeyController.value = TextEditingValue(
        text: credentials.apiKey,
        selection: TextSelection.collapsed(offset: credentials.apiKey.length),
      );
    }
    if (_secretController.text != credentials.sharedSecret) {
      _secretController.value = TextEditingValue(
        text: credentials.sharedSecret,
        selection: TextSelection.collapsed(
          offset: credentials.sharedSecret.length,
        ),
      );
    }
  }

  Future<void> _commitCredentials() {
    return _service.updateAppCredentials(
      _apiKeyController.text,
      _secretController.text,
    );
  }

  Future<void> _setEnabled(bool value) async {
    setState(() => AppSettings.instance.lastFmEnabled = value);
    await AppSettings.instance.saveSettings();
    if (value) {
      unawaited(_service.flushPendingScrobbles());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) showTextOnSnackBar('已完成', variant: ToastVariant.success);
    } catch (error) {
      if (mounted) {
        showTextOnSnackBar(
          error is LastFmApiException ? error.message : '操作失败：$error',
          variant: ToastVariant.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    final credentials = _service.credentials;
    final pendingCount = _service.pendingScrobbles.length;
    final status = !_loaded
        ? '读取中'
        : credentials.isAuthorized
        ? '已连接 ${credentials.username}${pendingCount > 0 ? ' · 待提交 $pendingCount 条' : ''}'
        : credentials.pendingToken.isNotEmpty
        ? '已打开授权页，完成后点完成授权'
        : '未连接';

    final canAuthorize =
        _apiKeyController.text.trim().isNotEmpty &&
        _secretController.text.trim().isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsTile(
          description: 'Last.fm',
          subtitle: '播放达到一半或 4 分钟后提交记录',
          action: Switch(
            value: settings.lastFmEnabled,
            onChanged: _busy ? null : _setEnabled,
          ),
        ),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: '连接状态',
          subtitle: status,
          action: const SizedBox.shrink(),
        ),
        const SizedBox(height: 16.0),
        _LastFmTextField(
          label: 'API Key',
          controller: _apiKeyController,
          enabled: !_busy && _loaded,
          obscure: false,
          onChanged: (_) => setState(() {}),
          onFocusChange: (focused) {
            if (!focused) unawaited(_commitCredentials());
          },
        ),
        const SizedBox(height: 16.0),
        _LastFmTextField(
          label: 'Shared Secret',
          controller: _secretController,
          enabled: !_busy && _loaded,
          obscure: true,
          onChanged: (_) => setState(() {}),
          onFocusChange: (focused) {
            if (!focused) unawaited(_commitCredentials());
          },
        ),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: '申请 API Key',
          subtitle: '在 Last.fm 创建应用后填到上面',
          action: OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    final opened = await rust_utils.launchInBrowser(
                      uri: 'https://www.last.fm/api/account/create',
                    );
                    if (!opened) {
                      showTextOnSnackBar(
                        '打开页面失败',
                        variant: ToastVariant.error,
                      );
                    }
                  },
            child: const Text('打开'),
          ),
        ),
        const SizedBox(height: 16.0),
        SettingsTile(
          description: '打开授权页',
          subtitle: '用自己的 API Key 在浏览器里授权',
          action: FilledButton(
            onPressed: _busy || !canAuthorize
                ? null
                : () => _run(() async {
                    await _commitCredentials();
                    await _service.beginAuthorization();
                  }),
            child: const Text('授权'),
          ),
        ),
        if (credentials.pendingToken.isNotEmpty) ...[
          const SizedBox(height: 16.0),
          SettingsTile(
            description: '完成授权',
            subtitle: '浏览器同意后再点',
            action: FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await _commitCredentials();
                      AppSettings.instance.lastFmEnabled = true;
                      await AppSettings.instance.saveSettings();
                      await _service.completeAuthorization();
                    }),
              child: const Text('完成'),
            ),
          ),
        ],
        if (credentials.isAuthorized) ...[
          const SizedBox(height: 16.0),
          SettingsTile(
            description: '重试提交队列',
            subtitle: pendingCount == 0 ? '没有待提交记录' : '待提交 $pendingCount 条',
            action: OutlinedButton(
              onPressed: _busy || pendingCount == 0 || !settings.lastFmEnabled
                  ? null
                  : () => _run(_service.flushPendingScrobbles),
              child: const Text('重试'),
            ),
          ),
          const SizedBox(height: 16.0),
          SettingsTile(
            description: '断开连接',
            subtitle: '清除授权，保留 API Key',
            action: OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _run(_service.clearAuthorization),
              child: const Text('断开'),
            ),
          ),
        ],
      ],
    );
  }
}

class _LastFmTextField extends StatelessWidget {
  const _LastFmTextField({
    required this.label,
    required this.controller,
    required this.enabled,
    required this.obscure,
    required this.onChanged,
    required this.onFocusChange,
  });

  final String label;
  final TextEditingController controller;
  final bool enabled;
  final bool obscure;
  final ValueChanged<String> onChanged;
  final ValueChanged<bool> onFocusChange;

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: label,
      action: SizedBox(
        width: 260,
        child: Focus(
          onFocusChange: (focused) {
            HotkeysHelper.onFocusChanges(focused);
            onFocusChange(focused);
          },
          child: TextField(
            controller: controller,
            enabled: enabled,
            obscureText: obscure,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}
