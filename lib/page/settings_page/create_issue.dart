import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/setting_action_state.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/native/rust/api/utils.dart' as rust_utils;
import 'package:pure_music/core/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:flutter/services.dart';

const bool enableIssueReporting = bool.fromEnvironment(
  'ENABLE_ISSUE_REPORTING',
  defaultValue: true,
);

class CreateIssueTile extends StatelessWidget {
  const CreateIssueTile({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '报告问题',
      action: FilledButton.icon(
        onPressed: enableIssueReporting
            ? () => context.push(app_paths.SETTINGS_ISSUE_PAGE)
            : null,
        label: const Text('创建问题'),
        icon: const Icon(Symbols.help),
      ),
    );
  }
}

class SettingsIssuePage extends StatefulWidget {
  const SettingsIssuePage({super.key});

  @override
  State<SettingsIssuePage> createState() => _SettingsIssuePageState();
}

class _SettingsIssuePageState extends State<SettingsIssuePage> {
  final titleEditingController = TextEditingController();
  final descEditingController = TextEditingController();
  final logEditingController = TextEditingController();
  bool _logExpanded = true;
  bool _isPreparingLog = false;

  String _buildEnvironmentInfo() {
    final locale = WidgetsBinding.instance.platformDispatcher.locale;
    return [
      'OS: ${Platform.operatingSystem}',
      'OS Version: ${Platform.operatingSystemVersion}',
      'Runtime: ${Platform.version}',
      'Locale: ${locale.toLanguageTag()}',
    ].join('\n');
  }

  String _buildAppInfo() {
    const mode = kReleaseMode
        ? 'release'
        : kProfileMode
            ? 'profile'
            : 'debug';
    return [
      'App Version: ${AppSettings.version}',
      'Build Mode: $mode',
    ].join('\n');
  }

  String _buildPreferenceSnapshot() {
    final pref = AppPreference.instance;
    final pb = pref.playbackPref;
    final np = pref.nowPlayingPagePref;
    final map = <String, Object?>{
      'playback': {
        'playMode': pb.playMode.name,
        'volumeDsp': pb.volumeDsp,
        'eqPreampDb': pb.eqPreampDb,
        'eqAutoGainEnabled': pb.eqAutoGainEnabled,
        'eqAutoHeadroomDb': pb.eqAutoHeadroomDb,
        'reinitOnSetSource': pb.reinitOnSetSource,
      },
      'nowPlaying': {
        'nowPlayingViewMode': np.nowPlayingViewMode.name,
        'backgroundMode': np.backgroundMode.name,
        'lyricTextAlign': np.lyricTextAlign.name,
        'lyricFontSize': np.lyricFontSize,
        'translationFontSize': np.translationFontSize,
        'showLyricTranslation': np.showLyricTranslation,
        'lyricFontWeight': np.lyricFontWeight,
        'enableLyricBlur': np.enableLyricBlur,
      }
    };
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  String _buildNowPlayingSnapshot() {
    final pb = PlayService.instance.playbackService;
    final now = pb.nowPlaying;
    final base = <String, Object?>{
      'playerState': pb.playerState.name,
      'position': pb.position,
      'length': pb.length,
      'exclusive': pb.wasapiExclusive.value,
      'pitch': pb.pitch.value,
      'rate': pb.rate.value,
      'shuffle': pb.shuffle.value,
      'playlistIndex': pb.playlistIndex,
      'playlistLen': pb.playlist.value.length,
      'bass': pb.bassDebugStateLine,
    };
    if (now == null) {
      base['nowPlaying'] = null;
      return const JsonEncoder.withIndent('  ').convert(base);
    }
    base['nowPlaying'] = {
      'track': now.track,
      'duration': now.duration,
      'bitrate': now.bitrate,
      'sampleRate': now.sampleRate,
    };
    return const JsonEncoder.withIndent('  ').convert(base);
  }

  String _buildDescTemplate() {
    return [
      '### 复现步骤',
      '1. ',
      '2. ',
      '',
      '### 期望结果',
      '',
      '### 实际结果',
      '',
      '### 发生频率',
      '',
      '### 其他补充（可选）',
      '',
    ].join('\n');
  }

  String _buildLogSnapshot() {
    final logStrBuf = StringBuffer();
    for (final event in loggerMemoryOutput.buffer) {
      if (event.level.index < Level.info.index) continue;
      final firstLine = event.lines.isNotEmpty ? event.lines.first : '';
      if (firstLine.contains('[desktop lyric] sendLyricLineMessage') ||
          firstLine.contains('[desktop lyric] first word:')) {
        continue;
      }
      for (var line in event.lines) {
        logStrBuf.writeln(line);
      }
    }
    return redactDiagnosticData(logStrBuf.toString());
  }

  Future<String> _buildLogSnapshotFull() async {
    final parts = <String>[];
    parts.add('== APP ==');
    parts.add(_buildAppInfo());
    parts.add('');
    parts.add('== ENV ==');
    parts.add(_buildEnvironmentInfo());
    parts.add('');
    parts.add('== AUDIO_ECHO_LOG ==');
    final echoLog = await AudioEchoLogRecorder.instance.readLatestLog();
    parts.add(echoLog == null ? '-' : redactDiagnosticData(echoLog));
    parts.add('');
    parts.add('== PREF ==');
    parts.add(_buildPreferenceSnapshot());
    parts.add('');
    parts.add('== NOW_PLAYING ==');
    parts.add(_buildNowPlayingSnapshot());
    parts.add('');
    parts.add('== LOGGER_MEMORY ==');
    parts.add(_buildLogSnapshot());
    return parts.join('\n');
  }

  void _ensureFieldsPrepared() {
    if (descEditingController.text.trim().isEmpty) {
      descEditingController.text = _buildDescTemplate();
    }
  }

  Future<void> _fillAndCopyLogSnapshot() async {
    if (_isPreparingLog) return;
    if (!enableIssueReporting) {
      showTextOnSnackBar('未启用 Issue 上报');
      return;
    }
    setState(() => _isPreparingLog = true);
    try {
      _ensureFieldsPrepared();
      final snapshot = await _buildLogSnapshotFull();
      logEditingController.text = snapshot;
      await Clipboard.setData(ClipboardData(text: snapshot));
      if (mounted) showTextOnSnackBar('已复制日志到剪贴板');
    } catch (_) {
      if (mounted) showTextOnSnackBar('日志获取失败');
    } finally {
      if (mounted) {
        setState(() => _isPreparingLog = false);
      }
    }
  }

  (String owner, String repo) _parseRepoSlug(String raw) {
    final trimmed = raw.trim();
    final parts = trimmed.split('/');
    if (parts.length == 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      return (parts[0], parts[1]);
    }
    return ('qingyueyin', 'Pure-music');
  }

  Future<void> _openIssueLink() async {
    if (!enableIssueReporting) {
      showTextOnSnackBar('未启用 Issue 上报');
      return;
    }
    final title = titleEditingController.text.trim();
    if (title.isEmpty) {
      showTextOnSnackBar('请先填写问题标题');
      return;
    }
    _ensureFieldsPrepared();
    final (owner, repo) = _parseRepoSlug(AppPreference.instance.updateRepoSlug);
    final body = [
      descEditingController.text,
      '',
      '（建议先点击“获取日志”，日志会复制到剪贴板，粘贴到 Issue 正文中）',
    ].join('\n');
    final uri = Uri.https(
      'github.com',
      '/$owner/$repo/issues/new',
      {
        'title': title,
        'body': body,
      },
    );
    final opened = await rust_utils.launchInBrowser(uri: uri.toString());
    if (!opened) {
      showTextOnSnackBar('打开链接失败');
    }
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    titleEditingController.dispose();
    descEditingController.dispose();
    logEditingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wideEnough =
                constraints.maxWidth.isFinite && constraints.maxWidth >= 760.0;
            return wideEnough
                ? _buildLandscape(scheme)
                : _buildPortrait(scheme);
          },
        ),
      ),
    );
  }

  Widget _buildTitleRow() {
    Widget titleField() {
      return Focus(
        onFocusChange: HotkeysHelper.onFocusChanges,
        child: TextField(
          controller: titleEditingController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '标题',
            border: OutlineInputBorder(),
          ),
        ),
      );
    }

    Widget submitButton({bool stretch = false}) {
      final button = ValueListenableBuilder<TextEditingValue>(
        valueListenable: titleEditingController,
        builder: (context, value, _) {
          final canSubmit =
              enableIssueReporting && value.text.trim().isNotEmpty;
          return FilledButton.icon(
            onPressed: canSubmit ? _openIssueLink : null,
            icon: const Icon(Symbols.open_in_new),
            label: const Text('提交问题'),
          );
        },
      );
      return stretch ? SizedBox(width: double.infinity, child: button) : button;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth.isFinite && constraints.maxWidth < 520.0;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              titleField(),
              const SizedBox(height: 8.0),
              submitButton(stretch: true),
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: titleField()),
            const SizedBox(width: 8.0),
            submitButton(),
          ],
        );
      },
    );
  }

  Widget _buildDescriptionField() {
    return Focus(
      onFocusChange: HotkeysHelper.onFocusChanges,
      child: TextField(
        controller: descEditingController,
        textAlignVertical: const TextAlignVertical(y: -1),
        expands: true,
        maxLines: null,
        decoration: const InputDecoration(
          hintText: '描述',
          border: OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildLogField() {
    return Focus(
      onFocusChange: HotkeysHelper.onFocusChanges,
      child: TextField(
        controller: logEditingController,
        readOnly: !canEditTextValue(isBusy: _isPreparingLog),
        textAlignVertical: const TextAlignVertical(y: -1),
        expands: true,
        maxLines: null,
        decoration: const InputDecoration(
          hintText: '日志',
          border: OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildLogHeader(ColorScheme scheme) {
    Widget titleView() {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              _logExpanded ? Symbols.expand_less : Symbols.expand_more,
            ),
            onPressed: () => setState(() => _logExpanded = !_logExpanded),
            visualDensity: VisualDensity.compact,
          ),
          Text(
            '日志（可选）',
            style: TextStyle(color: scheme.onSurface.withAlpha(191)),
          ),
        ],
      );
    }

    Widget actionsView() {
      return ValueListenableBuilder<TextEditingValue>(
        valueListenable: logEditingController,
        builder: (context, value, _) {
          return Wrap(
            spacing: 4.0,
            runSpacing: 4.0,
            alignment: WrapAlignment.end,
            children: [
              TextButton.icon(
                onPressed: !enableIssueReporting || _isPreparingLog
                    ? null
                    : _fillAndCopyLogSnapshot,
                icon: _isPreparingLog
                    ? const SizedBox(
                        width: 18.0,
                        height: 18.0,
                        child: CircularProgressIndicator(strokeWidth: 2.0),
                      )
                    : const Icon(Symbols.content_copy, size: 18.0),
                label: Text(_isPreparingLog ? '获取中' : '获取日志'),
              ),
              TextButton.icon(
                onPressed: !canClearTextValue(
                  text: value.text,
                  isBusy: _isPreparingLog,
                )
                    ? null
                    : () => logEditingController.clear(),
                icon: const Icon(Symbols.clear, size: 18.0),
                label: const Text('清空'),
              ),
            ],
          );
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth.isFinite && constraints.maxWidth < 460.0;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              titleView(),
              Align(
                alignment: Alignment.centerRight,
                child: actionsView(),
              ),
            ],
          );
        }

        return Row(
          children: [
            titleView(),
            const Spacer(),
            actionsView(),
          ],
        );
      },
    );
  }

  Widget _buildPortrait(ColorScheme scheme) {
    if (_logExpanded) {
      return Column(
        children: [
          _buildTitleRow(),
          const SizedBox(height: 8),
          Expanded(flex: 3, child: _buildDescriptionField()),
          const SizedBox(height: 8),
          _buildLogHeader(scheme),
          const SizedBox(height: 4),
          Expanded(flex: 2, child: _buildLogField()),
          const Padding(padding: EdgeInsets.only(bottom: 96.0)),
        ],
      );
    }
    return Column(
      children: [
        _buildTitleRow(),
        const SizedBox(height: 8),
        Expanded(child: _buildDescriptionField()),
        const SizedBox(height: 8),
        _buildLogHeader(scheme),
        const Padding(padding: EdgeInsets.only(bottom: 96.0)),
      ],
    );
  }

  Widget _buildLandscape(ColorScheme scheme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Column(
            children: [
              _buildTitleRow(),
              const SizedBox(height: 8),
              Expanded(child: _buildDescriptionField()),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildLogHeader(scheme),
              const SizedBox(height: 4),
              Expanded(child: _buildLogField()),
            ],
          ),
        ),
      ],
    );
  }
}
