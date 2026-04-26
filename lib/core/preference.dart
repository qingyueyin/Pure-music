import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/utils.dart';

class PagePreference {
  int sortMethod;
  SortOrder sortOrder;
  ContentView contentView;

  PagePreference(this.sortMethod, this.sortOrder, this.contentView);

  Map toMap() => {
        "sortMethod": sortMethod,
        "sortOrder": sortOrder.name,
        "contentView": contentView.name,
      };

  factory PagePreference.fromMap(Map map) => PagePreference(
        map["sortMethod"] ?? 0,
        SortOrder.fromString(map["sortOrder"]) ?? SortOrder.ascending,
        ContentView.fromString(map["contentView"]) ?? ContentView.list,
      );
}

class NowPlayingPagePreference {
  NowPlayingViewMode nowPlayingViewMode;
  LyricTextAlign lyricTextAlign;
  double lyricFontSize;
  double translationFontSize;
  bool showLyricTranslation;
  bool showLyricRoman;
  int lyricFontWeight;
  bool enableLyricBlur;
  bool enableLyricScale;
  bool enableLyricSpring;
  NowPlayingBackgroundMode backgroundMode;

  NowPlayingPagePreference(
    this.nowPlayingViewMode,
    this.lyricTextAlign,
    this.lyricFontSize,
    this.translationFontSize,
    this.showLyricTranslation,
    this.lyricFontWeight,
    this.enableLyricBlur, {
    this.showLyricRoman = false,
    this.enableLyricScale = true,
    this.enableLyricSpring = true,
    this.backgroundMode = NowPlayingBackgroundMode.hybrid,
  });

  LyricRenderConfig get lyricRenderConfig => LyricRenderConfig(
        textAlign: lyricTextAlign,
        baseFontSize: lyricFontSize,
        translationBaseFontSize: translationFontSize,
        showTranslation: showLyricTranslation,
        showRoman: showLyricRoman,
        fontWeight: lyricFontWeight,
        enableBlur: enableLyricBlur,
        enableWordEmphasis: true,
        enableLineScale: enableLyricScale,
        enableLineSpring: enableLyricSpring,
      );

  Map toMap() => {
        "nowPlayingViewMode": nowPlayingViewMode.name,
        "lyricTextAlign": lyricTextAlign.name,
        "lyricFontSize": lyricFontSize,
        "translationFontSize": translationFontSize,
        "showLyricTranslation": showLyricTranslation,
        "showLyricRoman": showLyricRoman,
        "lyricFontWeight": lyricFontWeight,
        "enableLyricBlur": enableLyricBlur,
        "enableLyricScale": enableLyricScale,
        "enableLyricSpring": enableLyricSpring,
        "backgroundMode": backgroundMode.name,
      };

  factory NowPlayingPagePreference.fromMap(Map map) {
    final backgroundMode =
        NowPlayingBackgroundMode.fromString(map["backgroundMode"]) ??
            NowPlayingBackgroundMode.meshGradient;
    return NowPlayingPagePreference(
      NowPlayingViewMode.fromString(map["nowPlayingViewMode"]) ??
          NowPlayingViewMode.withLyric,
      LyricTextAlign.fromString(map["lyricTextAlign"]) ?? LyricTextAlign.left,
      map["lyricFontSize"] ?? 22.0,
      map["translationFontSize"] ?? 18.0,
      map["showLyricTranslation"] ?? true,
      map["lyricFontWeight"] ?? 400,
      map["enableLyricBlur"] ?? true,
      showLyricRoman: map["showLyricRoman"] ?? false,
      enableLyricScale: map["enableLyricScale"] ?? true,
      enableLyricSpring: map["enableLyricSpring"] ?? true,
      backgroundMode: backgroundMode,
    );
  }
}

class EqPreset {
  String name;
  List<double> gains;

  EqPreset(this.name, this.gains);

  Map toMap() => {
        "name": name,
        "gains": gains,
      };

  factory EqPreset.fromMap(Map map) => EqPreset(
        map["name"],
        List<double>.from(map["gains"]),
      );
}

enum PlaybackOutputBackend {
  system,
  asio;

  static PlaybackOutputBackend fromStoredValue(Object? value) {
    if (value is String) {
      for (final backend in PlaybackOutputBackend.values) {
        if (backend.name == value) return backend;
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
  double wasapiBufferSec;
  bool wasapiEventDriven;
  bool reinitOnSetSource;
  PlaybackOutputBackend outputBackend;
  int asioDeviceIndex;

  PlaybackPreference(
    this.playMode,
    this.volumeDsp,
    this.eqGains,
    this.eqPresets, {
    this.eqPreampDb = 0.0,
    this.eqAutoGainEnabled = true,
    this.eqAutoHeadroomDb = 1.0,
    this.lastAudioPath = '',
    this.lastPlaylistPaths = const [],
    this.lastPlaylistIndex = 0,
    this.wasapiBufferSec = 0.10,
    this.wasapiEventDriven = false,
    this.reinitOnSetSource = false,
    this.outputBackend = PlaybackOutputBackend.system,
    this.asioDeviceIndex = 0,
  });

  Map toMap() => {
        "playMode": playMode.name,
        "volumeDsp": volumeDsp,
        "eqGains": eqGains,
        "eqPreampDb": eqPreampDb,
        "eqAutoGainEnabled": eqAutoGainEnabled,
        "eqAutoHeadroomDb": eqAutoHeadroomDb,
        "eqPresets": eqPresets.map((e) => e.toMap()).toList(),
        "lastAudioPath": lastAudioPath,
        "lastPlaylistPaths": lastPlaylistPaths,
        "lastPlaylistIndex": lastPlaylistIndex,
        "wasapiBufferSec": wasapiBufferSec,
        "wasapiEventDriven": wasapiEventDriven,
        "reinitOnSetSource": reinitOnSetSource,
        "outputBackend": outputBackend.name,
        "asioDeviceIndex": asioDeviceIndex,
      };

  factory PlaybackPreference.fromMap(Map map) => PlaybackPreference(
        PlayMode.fromString(map["playMode"]) ?? PlayMode.forward,
        map["volumeDsp"] ?? 1.0,
        map["eqGains"] != null
            ? List<double>.from(map["eqGains"])
            : List.filled(10, 0.0),
        map["eqPresets"] != null
            ? (map["eqPresets"] as List)
                .map((e) => EqPreset.fromMap(e))
                .toList()
            : [],
        eqPreampDb: (map["eqPreampDb"] ?? 0.0).toDouble(),
        eqAutoGainEnabled: map["eqAutoGainEnabled"] ?? true,
        eqAutoHeadroomDb: (map["eqAutoHeadroomDb"] ?? 1.0).toDouble(),
        lastAudioPath: map["lastAudioPath"] ?? '',
        lastPlaylistPaths: map["lastPlaylistPaths"] != null
            ? List<String>.from(map["lastPlaylistPaths"])
            : const [],
        lastPlaylistIndex: map["lastPlaylistIndex"] ?? 0,
        wasapiBufferSec: (map["wasapiBufferSec"] ?? 0.10).toDouble(),
        wasapiEventDriven: map["wasapiEventDriven"] ?? false,
        reinitOnSetSource: map["reinitOnSetSource"] ?? false,
        outputBackend:
            PlaybackOutputBackend.fromStoredValue(map["outputBackend"]),
        asioDeviceIndex: (map["asioDeviceIndex"] ?? 0) is int
            ? map["asioDeviceIndex"] ?? 0
            : int.tryParse("${map["asioDeviceIndex"]}") ?? 0,
      );
}

class AppPreference {
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
      false,
      backgroundMode: NowPlayingBackgroundMode.hybrid);

  String customCpFeedbackKey = "";
  String updateRepoSlug = "qingyueyin/Pure-music";

  Future<void> save() async {
    try {
      final settingsDir = await getSettingsDir();
      final appPreferencePath = "${settingsDir.path}\\app_preference.json";

      Map prefMap = {
        "audiosPagePref": audiosPagePref.toMap(),
        "artistsPagePref": artistsPagePref.toMap(),
        "artistDetailPagePref": artistDetailPagePref.toMap(),
        "albumsPagePref": albumsPagePref.toMap(),
        "albumDetailPagePref": albumDetailPagePref.toMap(),
        "foldersPagePref": foldersPagePref.toMap(),
        "folderDetailPagePref": folderDetailPagePref.toMap(),
        "playlistsPagePref": playlistsPagePref.toMap(),
        "playlistDetailPagePref": playlistDetailPagePref.toMap(),
        "startPage": startPage,
        "sidebarExpanded": sidebarExpanded,
        "playbackPref": playbackPref.toMap(),
        "nowPlayingPagePref": nowPlayingPagePref.toMap(),
        "customCpFeedbackKey": customCpFeedbackKey,
        "updateRepoSlug": updateRepoSlug,
      };

      final prefJson = json.encode(prefMap);
      final output = await File(appPreferencePath).create(recursive: true);
      await output.writeAsString(prefJson);
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
    }
  }

  Future<void> savePlaybackOnly() async {
    try {
      final settingsDir = await getSettingsDir();
      final playbackPrefPath = "${settingsDir.path}\\playback_pref.json";

      final prefJson = json.encode(playbackPref.toMap());
      final output = await File(playbackPrefPath).create(recursive: true);
      await output.writeAsString(prefJson);
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
    }
  }

  Future<void> loadPlaybackOnly() async {
    try {
      final settingsDir = await getSettingsDir();
      final playbackPrefPath = "${settingsDir.path}\\playback_pref.json";

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
      final appPreferencePath = "${settingsDir.path}\\app_preference.json";

      final prefJson = await File(appPreferencePath).readAsString();
      final Map prefMap = json.decode(prefJson);

      instance.audiosPagePref =
          PagePreference.fromMap(prefMap["audiosPagePref"]);
      instance.artistsPagePref =
          PagePreference.fromMap(prefMap["artistsPagePref"]);
      instance.artistDetailPagePref = PagePreference.fromMap(
        prefMap["artistDetailPagePref"],
      );
      instance.albumsPagePref =
          PagePreference.fromMap(prefMap["albumsPagePref"]);
      instance.albumDetailPagePref = PagePreference.fromMap(
        prefMap["albumDetailPagePref"],
      );
      instance.foldersPagePref =
          PagePreference.fromMap(prefMap["foldersPagePref"]);
      instance.folderDetailPagePref = PagePreference.fromMap(
        prefMap["folderDetailPagePref"],
      );
      instance.playlistsPagePref = PagePreference.fromMap(
        prefMap["playlistsPagePref"],
      );
      instance.playlistDetailPagePref = PagePreference.fromMap(
        prefMap["playlistDetailPagePref"],
      );
      instance.startPage = prefMap["startPage"];
      instance.sidebarExpanded = prefMap["sidebarExpanded"] ?? true;
      instance.playbackPref =
          PlaybackPreference.fromMap(prefMap["playbackPref"]);
      instance.nowPlayingPagePref =
          NowPlayingPagePreference.fromMap(prefMap["nowPlayingPagePref"]);
      _nowPlayingBackgroundModeNotifier?.value =
          instance.nowPlayingPagePref.backgroundMode;
      instance.customCpFeedbackKey = prefMap["customCpFeedbackKey"] ?? "";
      instance.updateRepoSlug =
          prefMap["updateRepoSlug"] ?? "qingyueyin/Pure-music";
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
