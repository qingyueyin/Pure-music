import 'dart:convert';

String getMessageTypeName<T extends Message>() => T.toString();

abstract class Message {
  const Message();

  Map<String, dynamic> toMessageJson();

  String buildMessageJson() => json.encode({
        'type': runtimeType.toString(),
        'message': toMessageJson(),
      });
}

class InitArgsMessage {
  final bool isPlaying;
  final String title;
  final String artist;
  final String album;
  final bool darkMode;
  final int primary;
  final int surfaceContainer;
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

  Map<String, dynamic> toJson() => {
        'isPlaying': isPlaying,
        'title': title,
        'artist': artist,
        'album': album,
        'darkMode': darkMode,
        'primary': primary,
        'surfaceContainer': surfaceContainer,
        'onSurface': onSurface,
      };
}

enum ControlEvent {
  pause(0),
  start(1),
  previousAudio(2),
  nextAudio(3),
  lock(4),
  close(5);

  const ControlEvent(this.code);
  final int code;

  static ControlEvent fromJson(Object? raw) {
    if (raw is String) {
      return ControlEvent.values.byName(raw);
    }
    if (raw is int) {
      return ControlEvent.values.firstWhere((e) => e.code == raw);
    }
    throw FormatException('Invalid event: $raw');
  }
}

class ControlEventMessage extends Message {
  final ControlEvent event;

  const ControlEventMessage(this.event);

  factory ControlEventMessage.fromJson(Map<String, dynamic> json) {
    return ControlEventMessage(ControlEvent.fromJson(json['event']));
  }

  @override
  Map<String, dynamic> toMessageJson() => {
        'event': event.code,
      };
}

class PlayerStateChangedMessage extends Message {
  final bool playing;

  const PlayerStateChangedMessage(this.playing);

  factory PlayerStateChangedMessage.fromJson(Map<String, dynamic> json) {
    return PlayerStateChangedMessage(json['playing'] as bool);
  }

  @override
  Map<String, dynamic> toMessageJson() => {'playing': playing};
}

class NowPlayingChangedMessage extends Message {
  final String title;
  final String artist;
  final String album;

  const NowPlayingChangedMessage(this.title, this.artist, this.album);

  factory NowPlayingChangedMessage.fromJson(Map<String, dynamic> json) {
    return NowPlayingChangedMessage(
      json['title'] as String,
      json['artist'] as String,
      json['album'] as String,
    );
  }

  @override
  Map<String, dynamic> toMessageJson() => {
        'title': title,
        'artist': artist,
        'album': album,
      };
}

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
  ]);

  factory LyricLineChangedMessage.fromJson(Map<String, dynamic> json) {
    return LyricLineChangedMessage(
      json['content'] as String,
      Duration(microseconds: (json['length'] as num).toInt()),
      json['translation'] as String?,
      (json['words'] as List?)
          ?.map((e) => LyricWord.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      (json['progressMs'] as num?)?.toInt(),
      json['nextContent'] as String?,
      json['nextTranslation'] as String?,
      (json['nextWords'] as List?)
          ?.map((e) => LyricWord.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      json['romanLyric'] as String?,
      json['nextRomanLyric'] as String?,
    );
  }

  @override
  Map<String, dynamic> toMessageJson() => {
        'content': content,
        'translation': translation,
        'romanLyric': romanLyric,
        'length': length.inMicroseconds,
        'words': words?.map((e) => e.toJson()).toList(growable: false),
        'progressMs': progressMs,
        'nextContent': nextContent,
        'nextTranslation': nextTranslation,
        'nextRomanLyric': nextRomanLyric,
        'nextWords': nextWords?.map((e) => e.toJson()).toList(growable: false),
      };
}

class LyricWord {
  final int startMs;
  final int lengthMs;
  final String content;

  const LyricWord(this.startMs, this.lengthMs, this.content);

  factory LyricWord.fromJson(Map<String, dynamic> json) {
    return LyricWord(
      (json['startMs'] as num).toInt(),
      (json['lengthMs'] as num).toInt(),
      json['content'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
        'startMs': startMs,
        'lengthMs': lengthMs,
        'content': content,
      };
}

class ThemeChangedMessage extends Message {
  final bool darkMode;
  final int primary;
  final int surfaceContainer;
  final int onSurface;

  const ThemeChangedMessage(this.darkMode, this.primary, this.surfaceContainer, this.onSurface);

  factory ThemeChangedMessage.fromJson(Map<String, dynamic> json) {
    return ThemeChangedMessage(
      json['darkMode'] as bool,
      json['primary'] as int,
      json['surfaceContainer'] as int,
      json['onSurface'] as int,
    );
  }

  @override
  Map<String, dynamic> toMessageJson() => {
        'darkMode': darkMode,
        'primary': primary,
        'surfaceContainer': surfaceContainer,
        'onSurface': onSurface,
      };
}

class UnlockMessage extends Message {
  const UnlockMessage();

  @override
  Map<String, dynamic> toMessageJson() => {};
}

class DesktopLyricConfigMessage extends Message {
  final double? lyricFontSize;
  final double? translationFontSize;
  final int? lyricFontWeight;
  final bool? showLyricTranslation;
  final bool? showRoman;
  final int? romanPosition;
  final bool? showNowPlayingInfo;
  final int? lyricTextAlign;
  final bool? enableStroke;
  final double? backgroundOpacity;
  final int? playedColor;
  final int? unplayedColor;
  final bool? followThemeColor;

  const DesktopLyricConfigMessage({
    this.lyricFontSize,
    this.translationFontSize,
    this.lyricFontWeight,
    this.showLyricTranslation,
    this.showRoman,
    this.romanPosition,
    this.showNowPlayingInfo,
    this.lyricTextAlign,
    this.enableStroke,
    this.backgroundOpacity,
    this.playedColor,
    this.unplayedColor,
    this.followThemeColor,
  });

  @override
  Map<String, dynamic> toMessageJson() => {
        if (lyricFontSize != null) 'lyricFontSize': lyricFontSize,
        if (translationFontSize != null) 'translationFontSize': translationFontSize,
        if (lyricFontWeight != null) 'lyricFontWeight': lyricFontWeight,
        if (showLyricTranslation != null) 'showLyricTranslation': showLyricTranslation,
        if (showRoman != null) 'showRoman': showRoman,
        if (romanPosition != null) 'romanPosition': romanPosition,
        if (showNowPlayingInfo != null) 'showNowPlayingInfo': showNowPlayingInfo,
        if (lyricTextAlign != null) 'lyricTextAlign': lyricTextAlign,
        if (enableStroke != null) 'enableStroke': enableStroke,
        if (backgroundOpacity != null) 'backgroundOpacity': backgroundOpacity,
        if (playedColor != null) 'playedColor': playedColor,
        if (unplayedColor != null) 'unplayedColor': unplayedColor,
        if (followThemeColor != null) 'followThemeColor': followThemeColor,
      };
}
