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

class MessageFrameDecoder {
  MessageFrameDecoder({this.maxBufferLength = 65536, this.onOverflow});

  final int maxBufferLength;
  final void Function()? onOverflow;
  String _buffer = '';

  void add(String chunk, void Function(String line) onLine) {
    if (chunk.isEmpty) return;
    _buffer += chunk;
    if (_buffer.length > maxBufferLength) {
      _buffer = _buffer.substring(_buffer.length ~/ 2);
      onOverflow?.call();
    }
    while (true) {
      final index = _buffer.indexOf('\n');
      if (index < 0) return;
      final line = _buffer.substring(0, index).trimRight();
      _buffer = _buffer.substring(index + 1);
      if (line.isNotEmpty) onLine(line);
    }
  }

  void clear() => _buffer = '';
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
  Map<String, dynamic> toMessageJson() => {
        'progressMs': progressMs,
        'sampledAtMs': sampledAtMs,
        'playbackRate': playbackRate,
        'playing': playing,
        if (lineId != null) 'lineId': lineId,
      };
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
      json['isWordByWord'] as bool?,
      (json['lineId'] as num?)?.toInt(),
      (json['highlightDeadlineMs'] as num?)?.toInt(),
      (json['highlightCatchUpDurationMs'] as num?)?.toInt(),
      (json['highlightFinishLeadMs'] as num?)?.toInt(),
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
        'isWordByWord': wordByWord,
        if (lineId != null) 'lineId': lineId,
        if (highlightDeadlineMs != null)
          'highlightDeadlineMs': highlightDeadlineMs,
        if (highlightCatchUpDurationMs != null)
          'highlightCatchUpDurationMs': highlightCatchUpDurationMs,
        if (highlightFinishLeadMs != null)
          'highlightFinishLeadMs': highlightFinishLeadMs,
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

class FullLyricLine {
  final int lineId;
  final String? content;
  final String? translation;
  final String? romanLyric;
  final int startMs;
  final int lengthMs;
  final List<LyricWord>? words;
  final int? highlightDeadlineMs;
  final int? switchStartMs;

  const FullLyricLine(
    this.lineId,
    this.content,
    this.translation,
    this.romanLyric,
    this.startMs,
    this.lengthMs,
    this.words, [
    this.highlightDeadlineMs,
    this.switchStartMs,
  ]);

  factory FullLyricLine.fromJson(Map<String, dynamic> json) => FullLyricLine(
        (json['lineId'] as num).toInt(),
        json['content'] as String?,
        json['translation'] as String?,
        json['romanLyric'] as String?,
        (json['startMs'] as num).toInt(),
        (json['lengthMs'] as num).toInt(),
        (json['words'] as List?)
            ?.map((e) => LyricWord.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        (json['highlightDeadlineMs'] as num?)?.toInt(),
        (json['switchStartMs'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'lineId': lineId,
        'content': content,
        'translation': translation,
        'romanLyric': romanLyric,
        'startMs': startMs,
        'lengthMs': lengthMs,
        'words': words?.map((word) => word.toJson()).toList(growable: false),
        if (highlightDeadlineMs != null)
          'highlightDeadlineMs': highlightDeadlineMs,
        if (switchStartMs != null) 'switchStartMs': switchStartMs,
      };
}

class FullLyricChangedMessage extends Message {
  final List<FullLyricLine> lines;

  const FullLyricChangedMessage(this.lines);

  factory FullLyricChangedMessage.fromJson(Map<String, dynamic> json) =>
      FullLyricChangedMessage(
        (json['lines'] as List)
            .map((e) => FullLyricLine.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
      );

  @override
  Map<String, dynamic> toMessageJson() => {
        'lines': lines.map((line) => line.toJson()).toList(growable: false),
      };
}

class ThemeChangedMessage extends Message {
  final bool darkMode;
  final int primary;
  final int surfaceContainer;
  final int onSurface;

  const ThemeChangedMessage(
      this.darkMode, this.primary, this.surfaceContainer, this.onSurface);

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
  final int? translationPosition;
  final bool? showNowPlayingInfo;
  final bool? hideOnPause;
  final int? lyricTextAlign;
  final int? lyricAnimation;
  final bool? enableStroke;
  final double? backgroundOpacity;
  final int? playedColor;
  final int? unplayedColor;
  final bool? followThemeColor;
  final bool? useLightOutline;
  final bool? useVerticalDisplayMode;
  final bool? showDoubleLine;
  final bool? hoverHide;
  final bool? fullscreenHide;
  final double? lineGap;
  final bool? enablePinTop;
  final bool? useMultiLineMode;
  final int? multiLineAnimation;
  final bool? hidePlayedLines;
  final double? fontOpacity;

  const DesktopLyricConfigMessage({
    this.lyricFontSize,
    this.translationFontSize,
    this.lyricFontWeight,
    this.showLyricTranslation,
    this.showRoman,
    this.romanPosition,
    this.translationPosition,
    this.showNowPlayingInfo,
    this.hideOnPause,
    this.lyricTextAlign,
    this.lyricAnimation,
    this.enableStroke,
    this.backgroundOpacity,
    this.playedColor,
    this.unplayedColor,
    this.followThemeColor,
    this.useLightOutline,
    this.useVerticalDisplayMode,
    this.showDoubleLine,
    this.hoverHide,
    this.fullscreenHide,
    this.lineGap,
    this.enablePinTop,
    this.useMultiLineMode,
    this.multiLineAnimation,
    this.hidePlayedLines,
    this.fontOpacity,
  });

  factory DesktopLyricConfigMessage.fromJson(Map<String, dynamic> json) {
    return DesktopLyricConfigMessage(
      lyricFontSize: (json['lyricFontSize'] as num?)?.toDouble(),
      translationFontSize: (json['translationFontSize'] as num?)?.toDouble(),
      lyricFontWeight: (json['lyricFontWeight'] as num?)?.toInt(),
      showLyricTranslation: json['showLyricTranslation'] as bool?,
      showRoman: json['showRoman'] as bool?,
      romanPosition: (json['romanPosition'] as num?)?.toInt(),
      translationPosition: (json['translationPosition'] as num?)?.toInt(),
      showNowPlayingInfo: json['showNowPlayingInfo'] as bool?,
      hideOnPause: json['hideOnPause'] as bool?,
      lyricTextAlign: (json['lyricTextAlign'] as num?)?.toInt(),
      lyricAnimation: (json['lyricAnimation'] as num?)?.toInt(),
      enableStroke: json['enableStroke'] as bool?,
      backgroundOpacity: (json['backgroundOpacity'] as num?)?.toDouble(),
      playedColor: (json['playedColor'] as num?)?.toInt(),
      unplayedColor: (json['unplayedColor'] as num?)?.toInt(),
      followThemeColor: json['followThemeColor'] as bool?,
      useLightOutline: json['useLightOutline'] as bool?,
      useVerticalDisplayMode: json['useVerticalDisplayMode'] as bool?,
      showDoubleLine: json['showDoubleLine'] as bool?,
      hoverHide: json['hoverHide'] as bool?,
      fullscreenHide: json['fullscreenHide'] as bool?,
      lineGap: (json['lineGap'] as num?)?.toDouble(),
      enablePinTop: json['enablePinTop'] as bool?,
      useMultiLineMode: json['useMultiLineMode'] as bool?,
      multiLineAnimation: (json['multiLineAnimation'] as num?)?.toInt(),
      hidePlayedLines: json['hidePlayedLines'] as bool?,
      fontOpacity: (json['fontOpacity'] as num?)?.toDouble(),
    );
  }

  @override
  Map<String, dynamic> toMessageJson() => {
        if (lyricFontSize != null) 'lyricFontSize': lyricFontSize,
        if (translationFontSize != null)
          'translationFontSize': translationFontSize,
        if (lyricFontWeight != null) 'lyricFontWeight': lyricFontWeight,
        if (showLyricTranslation != null)
          'showLyricTranslation': showLyricTranslation,
        if (showRoman != null) 'showRoman': showRoman,
        if (romanPosition != null) 'romanPosition': romanPosition,
        if (translationPosition != null)
          'translationPosition': translationPosition,
        if (showNowPlayingInfo != null)
          'showNowPlayingInfo': showNowPlayingInfo,
        if (hideOnPause != null) 'hideOnPause': hideOnPause,
        if (lyricTextAlign != null) 'lyricTextAlign': lyricTextAlign,
        if (lyricAnimation != null) 'lyricAnimation': lyricAnimation,
        if (enableStroke != null) 'enableStroke': enableStroke,
        if (backgroundOpacity != null) 'backgroundOpacity': backgroundOpacity,
        if (playedColor != null) 'playedColor': playedColor,
        if (unplayedColor != null) 'unplayedColor': unplayedColor,
        if (followThemeColor != null) 'followThemeColor': followThemeColor,
        if (useLightOutline != null) 'useLightOutline': useLightOutline,
        if (useVerticalDisplayMode != null)
          'useVerticalDisplayMode': useVerticalDisplayMode,
        if (showDoubleLine != null) 'showDoubleLine': showDoubleLine,
        if (hoverHide != null) 'hoverHide': hoverHide,
        if (fullscreenHide != null) 'fullscreenHide': fullscreenHide,
        if (lineGap != null) 'lineGap': lineGap,
        if (enablePinTop != null) 'enablePinTop': enablePinTop,
        if (useMultiLineMode != null) 'useMultiLineMode': useMultiLineMode,
        if (multiLineAnimation != null)
          'multiLineAnimation': multiLineAnimation,
        if (hidePlayedLines != null) 'hidePlayedLines': hidePlayedLines,
        if (fontOpacity != null) 'fontOpacity': fontOpacity,
      };
}
