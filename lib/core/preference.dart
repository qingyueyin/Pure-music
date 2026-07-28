import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pure_music/core/equalizer_action_state.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/setting_action_state.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/utils.dart';
import 'package:path/path.dart' as path;

class PagePreference {
  int sortMethod;
  SortOrder sortOrder;
  ContentView contentView;

  PagePreference(this.sortMethod, this.sortOrder, this.contentView);

  Map<String, dynamic> toMap() => {
        'sortMethod': sortMethod,
        'sortOrder': sortOrder.name,
        'contentView': contentView.name,
      };

  factory PagePreference.fromMap(Object? value) {
    final map = value is Map ? value : const <String, dynamic>{};
    return PagePreference(
      _normalizedNonNegativeInt(map['sortMethod']),
      _sortOrderFromStoredValue(map['sortOrder']) ?? SortOrder.ascending,
      _contentViewFromStoredValue(map['contentView']) ?? ContentView.list,
    );
  }
}

class NowPlayingPagePreference {
  NowPlayingViewMode nowPlayingViewMode;
  LyricTextAlign lyricTextAlign;
  double lyricFontSize;
  double translationFontSize;
  bool showLyricTranslation;
  bool showLyricRoman;
  RubyPosition rubyPosition;
  int lyricFontWeight;
  bool enableLyricBlur;
  bool enableLyricScale;
  bool enableLyricSpring;
  bool enableLyricGlow;
  LyricLiftStyle liftStyle;
  double liftPeak;
  int liftDurationMs;
  LyricStaggerStyle staggerStyle;
  double karaokeGradientWidthFraction;
  double unplayedAlpha;
  NowPlayingBackgroundMode backgroundMode;
  bool audioReactiveFlow;

  NowPlayingPagePreference(
    this.nowPlayingViewMode,
    this.lyricTextAlign,
    this.lyricFontSize,
    this.translationFontSize,
    this.showLyricTranslation,
    this.lyricFontWeight,
    this.enableLyricBlur, {
    this.showLyricRoman = true,
    this.rubyPosition = RubyPosition.below,
    this.enableLyricScale = true,
    this.enableLyricSpring = true,
    this.enableLyricGlow = false,
    this.liftStyle = LyricLiftStyle.vertical,
    this.liftPeak = 2.0,
    this.liftDurationMs = 300,
    this.staggerStyle = LyricStaggerStyle.smooth,
    this.karaokeGradientWidthFraction = 0.25,
    this.unplayedAlpha = 0.30,
    this.backgroundMode = NowPlayingBackgroundMode.coverBlurTest,
    this.audioReactiveFlow = false,
  });

  LyricRenderConfig get lyricRenderConfig => LyricRenderConfig(
        textAlign: lyricTextAlign,
        baseFontSize: lyricFontSize,
        translationBaseFontSize: translationFontSize,
        showTranslation: showLyricTranslation,
        showRoman: showLyricRoman,
        lineOrder: rubyPosition.toLineOrder(),
        fontWeight: lyricFontWeight,
        enableBlur: enableLyricBlur,
        enableLineScale: enableLyricScale,
        enableLineSpring: enableLyricSpring,
        enableGlow: enableLyricGlow,
        liftStyle: liftStyle,
        liftPeak: liftPeak,
        liftDurationMs: liftDurationMs,
        staggerStyle: staggerStyle,
        karaokeGradientWidthFraction: karaokeGradientWidthFraction,
        unplayedAlpha: unplayedAlpha,
      );

  Map<String, dynamic> toMap() => {
        'nowPlayingViewMode': nowPlayingViewMode.name,
        'lyricTextAlign': lyricTextAlign.name,
        'lyricFontSize': lyricFontSize,
        'translationFontSize': translationFontSize,
        'showLyricTranslation': showLyricTranslation,
        'showLyricRoman': showLyricRoman,
        'rubyPosition': rubyPosition.name,
        'lyricFontWeight': lyricFontWeight,
        'enableLyricBlur': enableLyricBlur,
        'enableLyricScale': enableLyricScale,
        'enableLyricSpring': enableLyricSpring,
        'enableLyricGlow': enableLyricGlow,
        'liftStyle': liftStyle.name,
        'liftPeak': liftPeak,
        'liftDurationMs': liftDurationMs,
        'staggerStyle': staggerStyle.name,
        'karaokeGradientWidthFraction': karaokeGradientWidthFraction,
        'unplayedAlpha': unplayedAlpha,
        'backgroundMode': backgroundMode.name,
        'audioReactiveFlow': audioReactiveFlow,
      };

  factory NowPlayingPagePreference.fromMap(Object? value) {
    final map = value is Map ? value : const <String, dynamic>{};
    final backgroundMode =
        _nowPlayingBackgroundModeFromStoredValue(map['backgroundMode']) ??
            NowPlayingBackgroundMode.coverBlurTest;
    return NowPlayingPagePreference(
      _nowPlayingViewModeFromStoredValue(map['nowPlayingViewMode']) ??
          NowPlayingViewMode.withLyric,
      _lyricTextAlignFromStoredValue(map['lyricTextAlign']) ??
          LyricTextAlign.left,
      _normalizedBoundedDouble(
        map['lyricFontSize'],
        defaultValue: 22.0,
        min: 16.0,
        max: 48.0,
      ),
      _normalizedBoundedDouble(
        map['translationFontSize'],
        defaultValue: 18.0,
        min: 12.0,
        max: 44.0,
      ),
      _normalizedBool(map['showLyricTranslation'], defaultValue: true),
      _normalizedBoundedInt(
        map['lyricFontWeight'],
        defaultValue: 400,
        min: 100,
        max: 900,
      ),
      _normalizedBool(map['enableLyricBlur'], defaultValue: true),
      showLyricRoman:
          _normalizedBool(map['showLyricRoman'], defaultValue: true),
      rubyPosition: RubyPosition.fromString(
            (map['rubyPosition'] as String?) ?? '',
          ) ??
          RubyPosition.below,
      enableLyricScale:
          _normalizedBool(map['enableLyricScale'], defaultValue: true),
      enableLyricSpring:
          _normalizedBool(map['enableLyricSpring'], defaultValue: true),
      enableLyricGlow:
          _normalizedBool(map['enableLyricGlow'], defaultValue: false),
      liftStyle: LyricLiftStyle.fromString(
            (map['liftStyle'] as String?) ?? '',
          ) ??
          LyricLiftStyle.vertical,
      liftPeak: _normalizedBoundedDouble(
        map['liftPeak'],
        defaultValue: 2.0,
        min: 0.5,
        max: 6.0,
      ),
      liftDurationMs: _normalizedBoundedInt(
        map['liftDurationMs'],
        defaultValue: 300,
        min: 50,
        max: 2000,
      ),
      staggerStyle: LyricStaggerStyle.fromString(
            (map['staggerStyle'] as String?) ?? '',
          ) ??
          LyricStaggerStyle.smooth,
      karaokeGradientWidthFraction: _normalizedBoundedDouble(
        map['karaokeGradientWidthFraction'],
        defaultValue: 0.25,
        min: 0.05,
        max: 0.8,
      ),
      unplayedAlpha: _normalizedBoundedDouble(
        map['unplayedAlpha'],
        defaultValue: 0.30,
        min: 0.0,
        max: 1.0,
      ),
      backgroundMode: backgroundMode,
      audioReactiveFlow:
          _normalizedBool(map['audioReactiveFlow'], defaultValue: false),
    );
  }
}

class EqPreset {
  String name;
  List<double> gains;

  EqPreset(this.name, this.gains);

  Map<String, dynamic> toMap() => {
        'name': name,
        'gains': gains,
      };

  factory EqPreset.fromMap(Map map) => EqPreset(
        _normalizedString(map['name']),
        normalizedEqGains(map['gains']),
      );
}

List<EqPreset> _eqPresetsFromStoredValue(Object? value) {
  if (value is! Iterable) return const [];
  return _uniqueEqPresets(
    value.map(_eqPresetFromStoredValue).whereType<EqPreset>(),
  );
}

EqPreset? _eqPresetFromStoredValue(Object? value) {
  if (value is! Map) return null;
  final name = value['name'];
  if (name is! String) return null;
  return EqPreset.fromMap(value);
}

List<EqPreset> _uniqueEqPresets(Iterable<EqPreset> presets) {
  final result = <EqPreset>[];
  final indexByKey = <String, int>{};
  for (final preset in presets) {
    final name = normalizedEqPresetName(preset.name);
    final key = eqPresetNameKey(name);
    if (key.isEmpty) continue;
    final gains = List<double>.from(preset.gains);
    final existingIndex = indexByKey[key];
    if (existingIndex == null) {
      indexByKey[key] = result.length;
      result.add(EqPreset(name, gains));
      continue;
    }
    final firstName = result[existingIndex].name;
    result[existingIndex] = EqPreset(firstName, gains);
  }
  return result;
}

double _normalizedBoundedDouble(
  Object? value, {
  required double defaultValue,
  required double min,
  required double max,
}) {
  final number = switch (value) {
    num() => value.toDouble(),
    String() => double.tryParse(value),
    _ => null,
  };
  if (number == null || !number.isFinite) return defaultValue;
  return number.clamp(min, max).toDouble();
}

double _normalizedVolumeDsp(Object? value) {
  if (value is String) {
    final normalized = value.trim();
    if (normalized.endsWith('%') || normalized.endsWith('％')) {
      final percent = double.tryParse(
        normalized.substring(0, normalized.length - 1).trim(),
      );
      if (percent == null || !percent.isFinite) return 1.0;
      return (percent / 100.0).clamp(0.0, 1.0).toDouble();
    }
  }
  return _normalizedBoundedDouble(
    value,
    defaultValue: 1.0,
    min: 0.0,
    max: 1.0,
  );
}

int _normalizedNonNegativeInt(Object? value) {
  final number = _normalizedInteger(value);
  if (number == null) return 0;
  return number < 0 ? 0 : number;
}

int _normalizedBoundedInt(
  Object? value, {
  required int defaultValue,
  required int min,
  required int max,
}) {
  final number = _normalizedInteger(value);
  if (number == null) return defaultValue;
  return number.clamp(min, max);
}

int? _normalizedInteger(Object? value) {
  if (value is int) return value;
  if (value is num) {
    if (!value.isFinite) return null;
    final number = value.toDouble();
    if (number != number.truncateToDouble()) return null;
    return value.toInt();
  }
  if (value is! String) return null;
  final normalized = value.trim();
  final integer = int.tryParse(normalized);
  if (integer != null) return integer;
  final number = double.tryParse(normalized);
  if (number == null || !number.isFinite) return null;
  if (number != number.truncateToDouble()) return null;
  return number.toInt();
}

bool _normalizedBool(Object? value, {required bool defaultValue}) {
  return normalizedBoolSetting(value, defaultValue: defaultValue);
}

SortOrder? _sortOrderFromStoredValue(Object? value) {
  final index = _normalizedEnumIndex(value, SortOrder.values.length);
  if (index != null) return SortOrder.values[index];
  final name = _normalizedEnumName(value);
  return name == null ? null : SortOrder.fromString(name);
}

ContentView? _contentViewFromStoredValue(Object? value) {
  final index = _normalizedEnumIndex(value, ContentView.values.length);
  if (index != null) return ContentView.values[index];
  final name = _normalizedEnumName(value);
  return name == null ? null : ContentView.fromString(name);
}

NowPlayingViewMode? _nowPlayingViewModeFromStoredValue(Object? value) {
  final index = _normalizedEnumIndex(value, NowPlayingViewMode.values.length);
  if (index != null) return NowPlayingViewMode.values[index];
  final name = _normalizedEnumName(value);
  return name == null ? null : NowPlayingViewMode.fromString(name);
}

LyricTextAlign? _lyricTextAlignFromStoredValue(Object? value) {
  final index = _normalizedEnumIndex(value, LyricTextAlign.values.length);
  if (index != null) return LyricTextAlign.values[index];
  final name = _normalizedEnumName(value);
  return name == null ? null : LyricTextAlign.fromString(name);
}

NowPlayingBackgroundMode? _nowPlayingBackgroundModeFromStoredValue(
  Object? value,
) {
  final index = _normalizedEnumIndex(
    value,
    NowPlayingBackgroundMode.values.length,
  );
  if (index != null) return NowPlayingBackgroundMode.values[index];
  final name = _normalizedEnumName(value);
  return name == null ? null : NowPlayingBackgroundMode.fromString(name);
}

PlayMode? _playModeFromStoredValue(Object? value) {
  final index = _normalizedEnumIndex(value, PlayMode.values.length);
  if (index != null) return PlayMode.values[index];
  final name = _normalizedEnumName(value);
  return name == null ? null : PlayMode.fromString(name);
}

int? _normalizedEnumIndex(Object? value, int length) {
  final index = _normalizedInteger(value);
  if (index == null || index < 0 || index >= length) return null;
  return index;
}

String? _normalizedEnumName(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  if (normalized.isEmpty) return null;
  final separator = normalized.lastIndexOf('.');
  return separator < 0 ? normalized : normalized.substring(separator + 1);
}

String _normalizedString(Object? value) {
  return value is String ? value.trim() : '';
}

String _normalizedPathString(Object? value) {
  return value is String ? _normalizedFolderPath(value) : '';
}

List<String> _normalizedPathStringList(Object? value) {
  if (value is String && _looksLikeFolderPath(value)) {
    final path = _normalizedFolderPath(value);
    return path.isEmpty ? const [] : [path];
  }
  return _normalizedStringList(value)
      .map(_normalizedFolderPath)
      .where((item) => item.isNotEmpty)
      .toList();
}

List<String> _normalizedStringList(Object? value) {
  if (value is! Iterable) return const [];
  return value
      .whereType<String>()
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}

List<String> _normalizedUpdateCheckUrls(Object? value) {
  final values = value is String ? [value] : _normalizedStringList(value);
  final result = <String>[];
  final seen = <String>{};
  for (final raw in values) {
    final item = raw.trim();
    final lowerItem = item.toLowerCase();
    if (!lowerItem.startsWith('http://') && !lowerItem.startsWith('https://')) {
      continue;
    }
    final uri = Uri.tryParse(item);
    if (uri == null || uri.host.isEmpty) continue;
    if (seen.add(_updateUrlKey(item))) result.add(item);
  }
  return result;
}

String _updateUrlKey(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty) {
    final schemeEnd = value.indexOf('://');
    if (schemeEnd <= 0) return value;
    return value.substring(0, schemeEnd).toLowerCase() +
        value.substring(schemeEnd);
  }
  return uri
      .replace(
        scheme: uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
        fragment: '',
      )
      .toString();
}

List<String> _normalizedFolderPathList(Object? value) {
  final incoming = value is String && _looksLikeFolderPath(value)
      ? [_normalizedFolderPath(value)]
      : _normalizedStringList(value).map(_normalizedFolderPath);
  return appendUniquePendingFolders(
    current: const [],
    incoming: incoming,
  );
}

bool _looksLikeFolderPath(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return false;
  return normalized.contains(r'\') ||
      normalized.contains('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized);
}

String _normalizedFolderPath(String value) {
  final normalized = value.trim();
  final uri = Uri.tryParse(normalized);
  if (uri != null && uri.scheme.toLowerCase() == 'file') {
    final host = uri.host.toLowerCase();
    if ((host.isEmpty || host == 'localhost') && uri.path == '/') {
      return '';
    }
    if (host == 'localhost') {
      return uri.replace(host: '').toFilePath(windows: true);
    }
    return uri.toFilePath(windows: true);
  }
  return normalized;
}

String _normalizedNonEmptyString(
  Object? value, {
  required String defaultValue,
}) {
  if (value is! String) return defaultValue;
  final normalized = value.trim();
  return normalized.isEmpty ? defaultValue : normalized;
}

String? _normalizedNullableString(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

enum PlaybackOutputBackend {
  system,
  asio;

  static PlaybackOutputBackend fromStoredValue(Object? value) {
    final index =
        _normalizedEnumIndex(value, PlaybackOutputBackend.values.length);
    if (index != null) return PlaybackOutputBackend.values[index];
    final name = _normalizedEnumName(value);
    if (name != null) {
      for (final backend in PlaybackOutputBackend.values) {
        if (backend.name.toLowerCase() == name.toLowerCase()) return backend;
      }
    }
    return PlaybackOutputBackend.system;
  }
}

class PlaybackPreference {
  PlayMode playMode;
  double volumeDsp;
  List<double> eqGains;
  double eqPreampDb;
  bool eqAutoGainEnabled;
  double eqAutoHeadroomDb;
  List<EqPreset> eqPresets;
  String lastAudioPath;
  List<String> lastPlaylistPaths;
  int lastPlaylistIndex;
  bool lastShuffleActive;
  List<String> lastOriginalPlaylistPaths;
  double wasapiBufferSec;
  bool wasapiEventDriven;
  bool reinitOnSetSource;
  bool replayGainEnabled;
  PlaybackOutputBackend outputBackend;
  int asioDeviceIndex;

  PlaybackPreference(
    this.playMode,
    this.volumeDsp,
    this.eqGains,
    this.eqPresets, {
    this.replayGainEnabled = false,
    this.eqPreampDb = 0.0,
    this.eqAutoGainEnabled = true,
    this.eqAutoHeadroomDb = 1.0,
    this.lastAudioPath = '',
    this.lastPlaylistPaths = const [],
    this.lastPlaylistIndex = 0,
    this.lastShuffleActive = false,
    this.lastOriginalPlaylistPaths = const [],
    this.wasapiBufferSec = 0.10,
    this.wasapiEventDriven = false,
    this.reinitOnSetSource = false,
    this.outputBackend = PlaybackOutputBackend.system,
    this.asioDeviceIndex = 0,
  });

  Map<String, dynamic> toMap() => {
        'playMode': playMode.name,
        'volumeDsp': volumeDsp,
        'eqGains': eqGains,
        'eqPreampDb': eqPreampDb,
        'eqAutoGainEnabled': eqAutoGainEnabled,
        'eqAutoHeadroomDb': eqAutoHeadroomDb,
        'eqPresets': eqPresets.map((e) => e.toMap()).toList(),
        'lastAudioPath': lastAudioPath,
        'lastPlaylistPaths': lastPlaylistPaths,
        'lastPlaylistIndex': lastPlaylistIndex,
        'lastShuffleActive': lastShuffleActive,
        'lastOriginalPlaylistPaths': lastOriginalPlaylistPaths,
        'wasapiBufferSec': wasapiBufferSec,
        'wasapiEventDriven': wasapiEventDriven,
        'reinitOnSetSource': reinitOnSetSource,
        'outputBackend': outputBackend.name,
        'asioDeviceIndex': asioDeviceIndex,
        'replayGainEnabled': replayGainEnabled,
      };

  factory PlaybackPreference.fromMap(Object? value) {
    final map = value is Map ? value : const <String, dynamic>{};
    final lastPlaylistPaths = _normalizedPathStringList(
      map['lastPlaylistPaths'],
    );
    final lastPlaylistIndex = _normalizedBoundedInt(
      map['lastPlaylistIndex'],
      defaultValue: 0,
      min: 0,
      max: lastPlaylistPaths.isEmpty ? 0 : lastPlaylistPaths.length - 1,
    );
    final lastOriginalPlaylistPaths = _normalizedPathStringList(
      map['lastOriginalPlaylistPaths'],
    );
    return PlaybackPreference(
      _playModeFromStoredValue(map['playMode']) ?? PlayMode.forward,
      _normalizedVolumeDsp(map['volumeDsp']),
      map['eqGains'] != null
          ? normalizedEqGains(map['eqGains'])
          : normalizedEqGains(null),
      _eqPresetsFromStoredValue(map['eqPresets']),
      eqPreampDb: normalizedEqPreampDb(map['eqPreampDb']),
      eqAutoGainEnabled:
          _normalizedBool(map['eqAutoGainEnabled'], defaultValue: true),
      eqAutoHeadroomDb: _normalizedBoundedDouble(
        map['eqAutoHeadroomDb'],
        defaultValue: 1.0,
        min: 0.0,
        max: 24.0,
      ),
      lastAudioPath: _normalizedPathString(map['lastAudioPath']),
      lastPlaylistPaths: lastPlaylistPaths,
      lastPlaylistIndex: lastPlaylistIndex,
      lastShuffleActive:
          _normalizedBool(map['lastShuffleActive'], defaultValue: false),
      lastOriginalPlaylistPaths: lastOriginalPlaylistPaths,
      wasapiBufferSec: _normalizedBoundedDouble(
        map['wasapiBufferSec'],
        defaultValue: 0.10,
        min: 0.05,
        max: 0.30,
      ),
      wasapiEventDriven:
          _normalizedBool(map['wasapiEventDriven'], defaultValue: false),
      reinitOnSetSource:
          _normalizedBool(map['reinitOnSetSource'], defaultValue: false),
      outputBackend: PlaybackOutputBackend.fromStoredValue(
        map['outputBackend'],
      ),
      asioDeviceIndex: _normalizedNonNegativeInt(map['asioDeviceIndex']),
      replayGainEnabled:
          _normalizedBool(map['replayGainEnabled'], defaultValue: false),
    );
  }
}

class AppPreference {
  static const defaultUpdateRepoSlug = 'qingyueyin/Pure-music';
  static const defaultUpdateCheckUrls = [
    'https://raw.githubusercontent.com/qingyueyin/Pure-music/main/update/version.json',
    'https://gitee.com/qingyueyin/Pure-music/raw/main/update/version.json',
  ];

  var audiosPagePref = PagePreference(0, SortOrder.ascending, ContentView.list);

  var artistsPagePref =
      PagePreference(0, SortOrder.ascending, ContentView.table);

  var artistDetailPagePref =
      PagePreference(0, SortOrder.ascending, ContentView.list);

  var albumsPagePref =
      PagePreference(0, SortOrder.ascending, ContentView.table);

  var albumDetailPagePref =
      PagePreference(2, SortOrder.ascending, ContentView.list);

  var foldersPagePref =
      PagePreference(0, SortOrder.ascending, ContentView.list);

  var folderDetailPagePref =
      PagePreference(0, SortOrder.ascending, ContentView.list);

  var playlistsPagePref =
      PagePreference(0, SortOrder.ascending, ContentView.list);

  var playlistDetailPagePref =
      PagePreference(0, SortOrder.ascending, ContentView.list);

  int startPage = 0;

  bool sidebarExpanded = true;

  var playbackPref =
      PlaybackPreference(PlayMode.forward, 1.0, List.filled(10, 0.0), []);

  var nowPlayingPagePref = NowPlayingPagePreference(
      NowPlayingViewMode.withLyric,
      LyricTextAlign.left,
      22.0,
      18.0,
      true,
      400,
      false);

  String customCpFeedbackKey = '';
  String updateRepoSlug = defaultUpdateRepoSlug;
  bool autoCheckUpdate = true;
  String? lastUpdateCheckTime;
  String? lastSeenUpdateTag;
  List<String> updateCheckUrls = List.of(defaultUpdateCheckUrls);

  /// 用户手动添加的文件夹路径列表（不包括自动发现的子文件夹）
  List<String> userFolders = [];

  List<String> excludedFolderPaths = [];

  /// 上次读取的原始 JSON，保存时保留未知字段
  Map? _rawPrefMap;

  void applyStoredMap(Map prefMap) {
    _rawPrefMap = prefMap;

    audiosPagePref = PagePreference.fromMap(prefMap['audiosPagePref']);
    artistsPagePref = PagePreference.fromMap(prefMap['artistsPagePref']);
    artistDetailPagePref = PagePreference.fromMap(
      prefMap['artistDetailPagePref'],
    );
    albumsPagePref = PagePreference.fromMap(prefMap['albumsPagePref']);
    albumDetailPagePref = PagePreference.fromMap(
      prefMap['albumDetailPagePref'],
    );
    foldersPagePref = PagePreference.fromMap(prefMap['foldersPagePref']);
    folderDetailPagePref = PagePreference.fromMap(
      prefMap['folderDetailPagePref'],
    );
    playlistsPagePref = PagePreference.fromMap(prefMap['playlistsPagePref']);
    playlistDetailPagePref = PagePreference.fromMap(
      prefMap['playlistDetailPagePref'],
    );
    startPage = _normalizedBoundedInt(
      prefMap['startPage'],
      defaultValue: 0,
      min: 0,
      max: app_paths.START_PAGES.length - 1,
    );
    sidebarExpanded = _normalizedBool(
      prefMap['sidebarExpanded'],
      defaultValue: true,
    );
    playbackPref = PlaybackPreference.fromMap(prefMap['playbackPref']);
    nowPlayingPagePref = NowPlayingPagePreference.fromMap(
      prefMap['nowPlayingPagePref'],
    );
    _nowPlayingBackgroundModeNotifier?.value =
        nowPlayingPagePref.backgroundMode;
    customCpFeedbackKey = _normalizedString(prefMap['customCpFeedbackKey']);
    updateRepoSlug = _normalizedNonEmptyString(
      prefMap['updateRepoSlug'],
      defaultValue: defaultUpdateRepoSlug,
    );
    autoCheckUpdate = _normalizedBool(
      prefMap['autoCheckUpdate'],
      defaultValue: true,
    );
    lastUpdateCheckTime = _normalizedNullableString(
      prefMap['lastUpdateCheckTime'],
    );
    lastSeenUpdateTag = _normalizedNullableString(prefMap['lastSeenUpdateTag']);
    final storedUpdateUrls = _normalizedUpdateCheckUrls(
      prefMap['updateCheckUrls'],
    );
    updateCheckUrls = storedUpdateUrls.isEmpty
        ? List.of(defaultUpdateCheckUrls)
        : storedUpdateUrls;
    userFolders = _normalizedFolderPathList(prefMap['userFolders']);
    excludedFolderPaths = _normalizedFolderPathList(
      prefMap['excludedFolderPaths'],
    );
  }

  Future<bool> save() async {
    try {
      final settingsDir = await getSettingsDir();
      final appPreferencePath =
          path.join(settingsDir.path, 'app_preference.json');

      final prefMap = _rawPrefMap != null
          ? Map<String, dynamic>.from(_rawPrefMap!)
          : <String, dynamic>{};
      prefMap['version'] = AppSettings.version;
      prefMap.addAll({
        'audiosPagePref': audiosPagePref.toMap(),
        'artistsPagePref': artistsPagePref.toMap(),
        'artistDetailPagePref': artistDetailPagePref.toMap(),
        'albumsPagePref': albumsPagePref.toMap(),
        'albumDetailPagePref': albumDetailPagePref.toMap(),
        'foldersPagePref': foldersPagePref.toMap(),
        'folderDetailPagePref': folderDetailPagePref.toMap(),
        'playlistsPagePref': playlistsPagePref.toMap(),
        'playlistDetailPagePref': playlistDetailPagePref.toMap(),
        'startPage': startPage,
        'sidebarExpanded': sidebarExpanded,
        'playbackPref': playbackPref.toMap(),
        'nowPlayingPagePref': nowPlayingPagePref.toMap(),
        'customCpFeedbackKey': customCpFeedbackKey,
        'updateRepoSlug': updateRepoSlug,
        'autoCheckUpdate': autoCheckUpdate,
        'lastUpdateCheckTime': lastUpdateCheckTime,
        'lastSeenUpdateTag': lastSeenUpdateTag,
        'updateCheckUrls': updateCheckUrls,
        'userFolders': userFolders,
        'excludedFolderPaths': excludedFolderPaths,
      });

      final prefJson = json.encode(prefMap);
      await writeTextFileAtomically(appPreferencePath, prefJson);
      return true;
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
      return false;
    }
  }

  Future<bool> savePlaybackOnly() async {
    try {
      final settingsDir = await getSettingsDir();
      final playbackPrefPath =
          path.join(settingsDir.path, 'playback_pref.json');

      final prefJson = json.encode(playbackPref.toMap());
      await writeTextFileAtomically(playbackPrefPath, prefJson);
      return true;
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
      return false;
    }
  }

  Future<void> loadPlaybackOnly() async {
    try {
      final settingsDir = await getSettingsDir();
      final playbackPrefPath =
          path.join(settingsDir.path, 'playback_pref.json');

      if (File(playbackPrefPath).existsSync()) {
        final prefJson = await File(playbackPrefPath).readAsString();
        final prefMap = json.decode(prefJson);
        instance.playbackPref = PlaybackPreference.fromMap(prefMap);
      }
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
    }
  }

  static Future<void> read() async {
    try {
      final settingsDir = await getSettingsDir();
      final appPreferencePath =
          path.join(settingsDir.path, 'app_preference.json');

      final prefJson = await File(appPreferencePath).readAsString();
      final Map prefMap = json.decode(prefJson);
      instance.applyStoredMap(prefMap);
      // 用独立保存的 playback_pref.json 覆盖最新播放状态
      // （_persistLastSession 写入的是 playback_pref.json 而非 app_preference.json）
      await instance.loadPlaybackOnly();

      if (instance.userFolders.isEmpty) {
        logger.i('userFolders is empty, will be set after first folder scan');
      }
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
    }
  }

  static final AppPreference instance = AppPreference();
}

ValueNotifier<NowPlayingBackgroundMode>? _nowPlayingBackgroundModeNotifier;

ValueNotifier<NowPlayingBackgroundMode> get nowPlayingBackgroundModeNotifier {
  return _nowPlayingBackgroundModeNotifier ??= ValueNotifier(
    AppPreference.instance.nowPlayingPagePref.backgroundMode,
  );
}
