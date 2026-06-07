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

/// desktop lyric -> player
@JsonSerializable()
class PreferenceChangedMessage extends Message {
  final int primary;
  final int surfaceContainer;
  final int onSurface;

  const PreferenceChangedMessage(
    this.primary,
    this.surfaceContainer,
    this.onSurface,
  );

  factory PreferenceChangedMessage.fromJson(Map<String, dynamic> json) =>
      _$PreferenceChangedMessageFromJson(json);

  @override
  Map<String, dynamic> _toJson() => _$PreferenceChangedMessageToJson(this);
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
  final Duration length;
  final List<LyricWord>? words;
  final int? progressMs;
  final String? nextContent;
  final String? nextTranslation;
  final List<LyricWord>? nextWords;

  const LyricLineChangedMessage(
    this.content,
    this.length, [
    this.translation,
    this.words,
    this.progressMs,
    this.nextContent,
    this.nextTranslation,
    this.nextWords,
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

@JsonSerializable()
class PositionMessage {
  final int wordIndex;
  final double progress;

  const PositionMessage(this.wordIndex, this.progress);

  factory PositionMessage.fromJson(Map<String, dynamic> json) =>
      _$PositionMessageFromJson(json);

  Map<String, dynamic> toJson() => _$PositionMessageToJson(this);
}

/// player -> desktop lyric
@JsonSerializable()
class ThemeModeChangedMessage extends Message {
  final bool darkMode;

  const ThemeModeChangedMessage(this.darkMode);

  factory ThemeModeChangedMessage.fromJson(Map<String, dynamic> json) =>
      _$ThemeModeChangedMessageFromJson(json);

  @override
  Map<String, dynamic> _toJson() => _$ThemeModeChangedMessageToJson(this);
}

/// player -> desktop lyric
@JsonSerializable()
class ThemeChangedMessage extends Message {
  final int primary;
  final int surfaceContainer;
  final int onSurface;

  const ThemeChangedMessage(
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

/// 心跳消息——主程序定期发送给桌面歌词，用于检测子进程是否存活
@JsonSerializable()
class HeartbeatMessage extends Message {
  const HeartbeatMessage();

  factory HeartbeatMessage.fromJson(Map<String, dynamic> json) =>
      _$HeartbeatMessageFromJson(json);

  @override
  Map<String, dynamic> _toJson() => _$HeartbeatMessageToJson(this);
}
