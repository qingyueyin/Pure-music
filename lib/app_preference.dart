import 'dart:convert';
import 'dart:io';

import 'package:pure_music/app_settings.dart';
import 'package:pure_music/enums.dart';
import 'package:pure_music/utils.dart';

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
  int lyricFontWeight;
  bool enableLyricBlur;

  NowPlayingPagePreference(
    this.nowPlayingViewMode,
    this.lyricTextAlign,
    this.lyricFontSize,
    this.translationFontSize,
    this.showLyricTranslation,
    this.lyricFontWeight,
    this.enableLyricBlur,
  );

  Map toMap() => {
        "nowPlayingViewMode": nowPlayingViewMode.name,
        "lyricTextAlign": lyricTextAlign.name,
        "lyricFontSize": lyricFontSize,
        "translationFontSize": translationFontSize,
        "showLyricTranslation": showLyricTranslation,
        "lyricFontWeight": lyricFontWeight,
        "enableLyricBlur": enableLyricBlur,
      };

  factory NowPlayingPagePreference.fromMap(Map map) {
    return NowPlayingPagePreference(
      NowPlayingViewMode.fromString(map["nowPlayingViewMode"]) ??
          NowPlayingViewMode.withLyric,
      LyricTextAlign.fromString(map["lyricTextAlign"]) ?? LyricTextAlign.left,
      map["lyricFontSize"] ?? 22.0,
      map["translationFontSize"] ?? 18.0,
      map["showLyricTranslation"] ?? true,
      map["lyricFontWeight"] ?? 400,
      map["enableLyricBlur"] ?? false,
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

class PlaybackPreference {
  PlayMode playMode;
  double volumeDsp;
  List<double> eqGains;
  bool eqBypass;
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

  PlaybackPreference(
    this.playMode,
    this.volumeDsp,
    this.eqGains,
    this.eqPresets, {
    this.eqBypass = false,
    this.eqPreampDb = 0.0,
    this.eqAutoGainEnabled = true,
    this.eqAutoHeadroomDb = 1.0,
    this.lastAudioPath = '',
    this.lastPlaylistPaths = const [],
    this.lastPlaylistIndex = 0,
    this.wasapiBufferSec = 0.10,
    this.wasapiEventDriven = false,
    this.reinitOnSetSource = false,
  });

  Map toMap() => {
        "playMode": playMode.name,
        "volumeDsp": volumeDsp,
        "eqGains": eqGains,
        "eqBypass": eqBypass,
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
        eqBypass: map["eqBypass"] ?? false,
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
      false);

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
      LOGGER.e(err, stackTrace: trace);
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
      instance.customCpFeedbackKey = prefMap["customCpFeedbackKey"] ?? "";
      instance.updateRepoSlug =
          prefMap["updateRepoSlug"] ?? "qingyueyin/Pure-music";
    } catch (err, trace) {
      LOGGER.e(err, stackTrace: trace);
    }
  }

  static final AppPreference instance = AppPreference();
}
