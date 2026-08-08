// ignore_for_file: constant_identifier_names

import 'dart:convert';

import 'package:json_annotation/json_annotation.dart';

part 'message.g.dart';

String getMessageTypeName<T extends Message>() => T.toString();

abstract class Message {
  const Message();

  Map<String, dynamic> _toJson();

  String buildMessageJson() =>
      json.encode({"type": runtimeType.toString(), "message": _toJson()});
}

@JsonEnum(valueField: "code")
enum ControlEvent {
  pause(0),
  start(1),
  previousAudio(2),
  nextAudio(3),
  lock(4),
  close(5);

  const ControlEvent(this.code);
  final int code;
}

@JsonSerializable()
class InitArgsMessage {
  final bool isPlaying;

  /// now playing
  final String title;

  /// now playing
  final String artist;

  /// now playing
  final String album;

  final bool darkMode;

  /// theme
  final int primary;

  /// theme
  final int surfaceContainer;

  /// theme
  final int onSurface;

  const InitArgsMessage(
    this.isPlaying,
    this.title,
    this.artist,
    this.album,
    this.darkMode,
    this.primary,
    this.surfaceContainer,
    this.onSurface,
  );

  factory InitArgsMessage.fromJson(Map<String, dynamic> json) =>
      _$InitArgsMessageFromJson(json);

  Map<String, dynamic> toJson() => _$InitArgsMessageToJson(this);
}

/// desktop lyric -> player
@JsonSerializable()
class ControlEventMessage extends Message {
  final ControlEvent event;

  const ControlEventMessage(this.event);

  factory ControlEventMessage.fromJson(Map<String, dynamic> json) =>
      _$ControlEventMessageFromJson(json);

  @override
  Map<String, dynamic> _toJson() => _$ControlEventMessageToJson(this);
}

/// player -> desktop lyric
@JsonSerializable()
class PlayerStateChangedMessage extends Message {
  final bool playing;

  const PlayerStateChangedMessage(this.playing);

  factory PlayerStateChangedMessage.fromJson(Map<String, dynamic> json) =>
      _$PlayerStateChangedMessageFromJson(json);

  @override
  Map<String, dynamic> _toJson() => _$PlayerStateChangedMessageToJson(this);
}

class LyricProgressChangedMessage extends Message {
  final int progressMs;
  final int sampledAtMs;
  final double playbackRate;
  final bool playing;
  final int? lineId;

  const LyricProgressChangedMessage(
    this.progressMs,
    this.sampledAtMs,
    this.playbackRate,
    this.playing, [
    this.lineId,
  ]);

  factory LyricProgressChangedMessage.fromJson(Map<String, dynamic> json) {
    return LyricProgressChangedMessage(
      (json['progressMs'] as num).toInt(),
      (json['sampledAtMs'] as num).toInt(),
      (json['playbackRate'] as num).toDouble(),
      json['playing'] as bool,
      (json['lineId'] as num?)?.toInt(),
    );
  }

  @override
  Map<String, dynamic> _toJson() => {
    'progressMs': progressMs,
    'sampledAtMs': sampledAtMs,
    'playbackRate': playbackRate,
    'playing': playing,
    if (lineId != null) 'lineId': lineId,
  };
}

/// player -> desktop lyric
@JsonSerializable()
class NowPlayingChangedMessage extends Message {
  final String title;
  final String artist;
  final String album;

  const NowPlayingChangedMessage(this.title, this.artist, this.album);

  factory NowPlayingChangedMessage.fromJson(Map<String, dynamic> json) =>
      _$NowPlayingChangedMessageFromJson(json);

  @override
  Map<String, dynamic> _toJson() => _$NowPlayingChangedMessageToJson(this);
}

/// player -> desktop lyric
@JsonSerializable()
class LyricLineChangedMessage extends Message {
  final String content;
  final String? translation;
  final String? romanLyric;
  final Duration length;
  final List<LyricWord>? words;
  final int? progressMs;
  final String? nextContent;
  final String? nextTranslation;
  final String? nextRomanLyric;
  final List<LyricWord>? nextWords;
  @JsonKey(name: 'isWordByWord')
  final bool? wordByWord;
  final int? lineId;
  final int? highlightDeadlineMs;
  final int? highlightCatchUpDurationMs;
  final int? highlightFinishLeadMs;

  bool get isWordByWord => wordByWord ?? (words?.isNotEmpty ?? false);

  const LyricLineChangedMessage(
    this.content,
    this.length, [
    this.translation,
    this.words,
    this.progressMs,
    this.nextContent,
    this.nextTranslation,
    this.nextWords,
    this.romanLyric,
    this.nextRomanLyric,
    this.wordByWord,
    this.lineId,
    this.highlightDeadlineMs,
    this.highlightCatchUpDurationMs,
    this.highlightFinishLeadMs,
  ]);

  factory LyricLineChangedMessage.fromJson(Map<String, dynamic> json) =>
      _$LyricLineChangedMessageFromJson(json);

  @override
  Map<String, dynamic> _toJson() => _$LyricLineChangedMessageToJson(this);
}

@JsonSerializable()
class LyricWord {
  final int startMs;
  final int lengthMs;
  final String content;

  const LyricWord(this.startMs, this.lengthMs, this.content);

  factory LyricWord.fromJson(Map<String, dynamic> json) =>
      _$LyricWordFromJson(json);

  Map<String, dynamic> toJson() => _$LyricWordToJson(this);
}

/// player -> desktop lyric
@JsonSerializable()
class ThemeChangedMessage extends Message {
  final bool darkMode;
  final int primary;
  final int surfaceContainer;
  final int onSurface;

  const ThemeChangedMessage(
    this.darkMode,
    this.primary,
    this.surfaceContainer,
    this.onSurface,
  );

  factory ThemeChangedMessage.fromJson(Map<String, dynamic> json) =>
      _$ThemeChangedMessageFromJson(json);

  @override
  Map<String, dynamic> _toJson() => _$ThemeChangedMessageToJson(this);
}

/// player -> desktop lyric
@JsonSerializable()
class UnlockMessage extends Message {
  const UnlockMessage();

  factory UnlockMessage.fromJson(Map<String, dynamic> json) =>
      _$UnlockMessageFromJson(json);

  @override
  Map<String, dynamic> _toJson() => _$UnlockMessageToJson(this);
}

/// player -> desktop lyric
class DesktopLyricConfigMessage extends Message {
  final double? lyricFontSize;
  final double? translationFontSize;
  final int? lyricFontWeight;
  final bool? showLyricTranslation;
  final bool? showRoman;
  final int? romanPosition;
  final bool? showNowPlayingInfo;
  final int? lyricTextAlign;
  final int? lyricAnimation;
  final bool? enableStroke;
  final double? backgroundOpacity;
  final int? playedColor;
  final int? unplayedColor;
  final bool? followThemeColor;
  final bool? useLightOutline;

  const DesktopLyricConfigMessage({
    this.lyricFontSize,
    this.translationFontSize,
    this.lyricFontWeight,
    this.showLyricTranslation,
    this.showRoman,
    this.romanPosition,
    this.showNowPlayingInfo,
    this.lyricTextAlign,
    this.lyricAnimation,
    this.enableStroke,
    this.backgroundOpacity,
    this.playedColor,
    this.unplayedColor,
    this.followThemeColor,
    this.useLightOutline,
  });

  factory DesktopLyricConfigMessage.fromJson(Map<String, dynamic> json) =>
      DesktopLyricConfigMessage(
        lyricFontSize: (json['lyricFontSize'] as num?)?.toDouble(),
        translationFontSize: (json['translationFontSize'] as num?)?.toDouble(),
        lyricFontWeight: (json['lyricFontWeight'] as num?)?.toInt(),
        showLyricTranslation: json['showLyricTranslation'] as bool?,
        showRoman: json['showRoman'] as bool?,
        romanPosition: (json['romanPosition'] as num?)?.toInt(),
        showNowPlayingInfo: json['showNowPlayingInfo'] as bool?,
        lyricTextAlign: (json['lyricTextAlign'] as num?)?.toInt(),
        lyricAnimation: (json['lyricAnimation'] as num?)?.toInt(),
        enableStroke: json['enableStroke'] as bool?,
        backgroundOpacity: (json['backgroundOpacity'] as num?)?.toDouble(),
        playedColor: (json['playedColor'] as num?)?.toInt(),
        unplayedColor: (json['unplayedColor'] as num?)?.toInt(),
        followThemeColor: json['followThemeColor'] as bool?,
        useLightOutline: json['useLightOutline'] as bool?,
      );

  Map<String, dynamic> toJson() => _toJson();

  @override
  Map<String, dynamic> _toJson() => {
    if (lyricFontSize != null) 'lyricFontSize': lyricFontSize,
    if (translationFontSize != null) 'translationFontSize': translationFontSize,
    if (lyricFontWeight != null) 'lyricFontWeight': lyricFontWeight,
    if (showLyricTranslation != null)
      'showLyricTranslation': showLyricTranslation,
    if (showRoman != null) 'showRoman': showRoman,
    if (romanPosition != null) 'romanPosition': romanPosition,
    if (showNowPlayingInfo != null) 'showNowPlayingInfo': showNowPlayingInfo,
    if (lyricTextAlign != null) 'lyricTextAlign': lyricTextAlign,
    if (lyricAnimation != null) 'lyricAnimation': lyricAnimation,
    if (enableStroke != null) 'enableStroke': enableStroke,
    if (backgroundOpacity != null) 'backgroundOpacity': backgroundOpacity,
    if (playedColor != null) 'playedColor': playedColor,
    if (unplayedColor != null) 'unplayedColor': unplayedColor,
    if (followThemeColor != null) 'followThemeColor': followThemeColor,
    if (useLightOutline != null) 'useLightOutline': useLightOutline,
  };
}
