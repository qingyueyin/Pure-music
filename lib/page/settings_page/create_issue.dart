import 'dart:convert';
import 'dart:io';

import 'package:pure_music/app_preference.dart';
import 'package:pure_music/app_settings.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/hotkeys_helper.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/src/rust/api/utils.dart' as rust_utils;
import 'package:pure_music/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_music/app_paths.dart' as app_paths;
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
      description: "报告问题",
      action: FilledButton.icon(
        onPressed: () => context.push(app_paths.SETTINGS_ISSUE_PAGE),
        label: const Text("创建问题"),
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

  String _sanitizePaths(String text) {
    var t = text;
    t = t.replaceAll(
      RegExp(r'([A-Za-z]:\\Users\\)([^\\]+)\\', caseSensitive: false),
      r'$1***\\',
    );
    t = t.replaceAll(
      RegExp(r'(/Users/)([^/]+)/', caseSensitive: false),
      r'$1***/',
    );
    t = t.replaceAll(
      RegExp(r'(/home/)([^/]+)/', caseSensitive: false),
      r'$1***/',
    );
    return t;
  }

  String _buildEnvironmentInfo() {
    final locale = WidgetsBinding.instance.platformDispatcher.locale;
    return [
      "OS: ${Platform.operatingSystem}",
      "OS Version: ${Platform.operatingSystemVersion}",
      "Runtime: ${Platform.version}",
      "Locale: ${locale.toLanguageTag()}",
    ].join("\n");
  }

  String _buildAppInfo() {
    final mode = kReleaseMode
        ? "release"
        : kProfileMode
            ? "profile"
            : "debug";
    return [
      "App Version: ${AppSettings.version}",
      "Build Mode: $mode",
    ].join("\n");
  }

  String _buildPreferenceSnapshot() {
    final pref = AppPreference.instance;
    final pb = pref.playbackPref;
    final np = pref.nowPlayingPagePref;
    final map = <String, Object?>{
      "playback": {
        "playMode": pb.playMode.name,
        "volumeDsp": pb.volumeDsp,
        "eqBypass": pb.eqBypass,
        "eqPreampDb": pb.eqPreampDb,
        "eqAutoGainEnabled": pb.eqAutoGainEnabled,
        "eqAutoHeadroomDb": pb.eqAutoHeadroomDb,
        "wasapiBufferSec": pb.wasapiBufferSec,
        "wasapiEventDriven": pb.wasapiEventDriven,
        "reinitOnSetSource": pb.reinitOnSetSource,
      },
      "nowPlaying": {
        "nowPlayingViewMode": np.nowPlayingViewMode.name,
        "lyricTextAlign": np.lyricTextAlign.name,
        "lyricFontSize": np.lyricFontSize,
        "translationFontSize": np.translationFontSize,
        "showLyricTranslation": np.showLyricTranslation,
        "lyricFontWeight": np.lyricFontWeight,
        "enableLyricBlur": np.enableLyricBlur,
      }
    };
    return const JsonEncoder.withIndent("  ").convert(map);
  }

  String _buildNowPlayingSnapshot() {
    final pb = PlayService.instance.playbackService;
    final now = pb.nowPlaying;
    final base = <String, Object?>{
      "playerState": pb.playerState.name,
      "position": pb.position,
      "length": pb.length,
      "exclusive": pb.wasapiExclusive.value,
      "pitch": pb.pitch.value,
      "rate": pb.rate.value,
      "shuffle": pb.shuffle.value,
      "playlistIndex": pb.playlistIndex,
      "playlistLen": pb.playlist.value.length,
      "bass": pb.bassDebugStateLine,
    };
    if (now == null) {
      base["nowPlaying"] = null;
      return const JsonEncoder.withIndent("  ").convert(base);
    }
    base["nowPlaying"] = {
      "title": now.title,
      "artist": now.artist,
      "album": now.album,
      "track": now.track,
      "duration": now.duration,
      "bitrate": now.bitrate,
      "sampleRate": now.sampleRate,
      "path": _sanitizePaths(now.path),
    };
    return const JsonEncoder.withIndent("  ").convert(base);
  }

  String _buildDescTemplate() {
    final pb = PlayService.instance.playbackService;
    final now = pb.nowPlaying;
    final hint =
        now == null ? "" : "当前歌曲：${now.title} - ${now.artist} (${now.album})";
    return [
      "### 复现步骤",
      "1. ",
      "2. ",
      "",
      "### 期望结果",
      "",
      "### 实际结果",
      "",
      "### 发生频率",
      "",
      "### 其他补充（可选）",
      hint.isEmpty ? "" : hint,
    ].where((e) => e.isNotEmpty).join("\n");
  }

  String _buildLogSnapshot() {
    final logStrBuf = StringBuffer();
    for (final event in LOGGER_MEMORY.buffer) {
      for (var line in event.lines) {
        logStrBuf.writeln(line);
      }
    }
    var text = logStrBuf.toString();
    return _sanitizePaths(text);
  }

  String _buildLogSnapshotFull() {
    final parts = <String>[];
    parts.add("== APP ==");
    parts.add(_buildAppInfo());
    parts.add("");
    parts.add("== ENV ==");
    parts.add(_buildEnvironmentInfo());
    parts.add("");
    final echoPath = AudioEchoLogRecorder.instance.currentLogPath;
    parts.add("== AUDIO_ECHO_LOG ==");
    parts.add("path: ${echoPath == null ? "-" : _sanitizePaths(echoPath)}");
    parts.add("");
    parts.add("== PREF ==");
    parts.add(_buildPreferenceSnapshot());
    parts.add("");
    parts.add("== NOW_PLAYING ==");
    parts.add(_buildNowPlayingSnapshot());
    parts.add("");
    parts.add("== LOGGER_MEMORY ==");
    parts.add(_buildLogSnapshot());
    return parts.join("\n");
  }

  void _ensureFieldsPrepared() {
    if (descEditingController.text.trim().isEmpty) {
      descEditingController.text = _buildDescTemplate();
    }
    if (titleEditingController.text.trim().isEmpty) {
      final now = PlayService.instance.playbackService.nowPlaying;
      titleEditingController.text = now == null ? "Bug: " : "Bug: ${now.title}";
    }
  }

  Future<void> _fillAndCopyLogSnapshot() async {
    if (!enableIssueReporting) {
      showTextOnSnackBar("未启用 Issue 上报");
      return;
    }
    _ensureFieldsPrepared();
    final snapshot = _buildLogSnapshotFull();
    logEditingController.text = snapshot;
    await Clipboard.setData(ClipboardData(text: snapshot));
    if (mounted) showTextOnSnackBar("已复制日志到剪贴板");
  }

  (String owner, String repo) _parseRepoSlug(String raw) {
    final trimmed = raw.trim();
    final parts = trimmed.split("/");
    if (parts.length == 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      return (parts[0], parts[1]);
    }
    return ("qingyueyin", "Pure-music");
  }

  void _openIssueLink() {
    if (!enableIssueReporting) {
      showTextOnSnackBar("未启用 Issue 上报");
      return;
    }
    _ensureFieldsPrepared();
    final (owner, repo) = _parseRepoSlug(AppPreference.instance.updateRepoSlug);
    final title = titleEditingController.text;
    final body = [
      descEditingController.text,
      "",
      "（建议先点击“获取日志”，日志会复制到剪贴板，粘贴到 Issue 正文中）",
    ].join("\n");
    final uri = Uri.https(
      "github.com",
      "/$owner/$repo/issues/new",
      {
        "title": title,
        "body": body,
      },
    );
    rust_utils.launchInBrowser(uri: uri.toString());
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Focus(
                    onFocusChange: HotkeysHelper.onFocusChanges,
                    child: TextField(
                      controller: titleEditingController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: "标题",
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 8.0),
                  child: FilledButton(
                    onPressed: _openIssueLink,
                    child: const Text("提交问题"),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    "日志（可选）",
                    style: TextStyle(color: scheme.onSurface.withOpacity(0.75)),
                  ),
                ),
                TextButton(
                  onPressed: _fillAndCopyLogSnapshot,
                  child: const Text("获取日志"),
                ),
                TextButton(
                  onPressed: () => logEditingController.clear(),
                  child: const Text("清空"),
                ),
              ],
            ),
            Expanded(
              child: Focus(
                onFocusChange: HotkeysHelper.onFocusChanges,
                child: TextField(
                  controller: descEditingController,
                  textAlignVertical: const TextAlignVertical(y: -1),
                  expands: true,
                  maxLines: null,
                  decoration: const InputDecoration(
                    hintText: "描述",
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Focus(
                onFocusChange: HotkeysHelper.onFocusChanges,
                child: TextField(
                  controller: logEditingController,
                  textAlignVertical: const TextAlignVertical(y: -1),
                  expands: true,
                  maxLines: null,
                  decoration: const InputDecoration(
                    hintText: "日志",
                    helperText: "你可以随意修改日志内容。",
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ),
            const Padding(padding: EdgeInsets.only(bottom: 96.0))
          ],
        ),
      ),
    );
  }
}
