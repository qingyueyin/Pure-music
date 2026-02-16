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

class PreferenceChangedMessage extends Message {
  final int primary;
  final int surfaceContainer;
  final int onSurface;

  const PreferenceChangedMessage(this.primary, this.surfaceContainer, this.onSurface);

  factory PreferenceChangedMessage.fromJson(Map<String, dynamic> json) {
    return PreferenceChangedMessage(
      json['primary'] as int,
      json['surfaceContainer'] as int,
      json['onSurface'] as int,
    );
  }

  @override
  Map<String, dynamic> toMessageJson() => {
        'primary': primary,
        'surfaceContainer': surfaceContainer,
        'onSurface': onSurface,
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
  final Duration length;
  final List<LyricWord>? words;
  final int? progressMs;

  const LyricLineChangedMessage(
    this.content,
    this.length, [
    this.translation,
    this.words,
    this.progressMs,
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
    );
  }

  @override
  Map<String, dynamic> toMessageJson() => {
        'content': content,
        'translation': translation,
        'length': length.inMicroseconds,
        'words': words?.map((e) => e.toJson()).toList(growable: false),
        'progressMs': progressMs,
      };
}

class LyricWord {
  final int start;
  final int length;
  final String content;

  const LyricWord(this.start, this.length, this.content);

  factory LyricWord.fromJson(Map<String, dynamic> json) {
    return LyricWord(
      (json['start'] as num).toInt(),
      (json['length'] as num).toInt(),
      json['content'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
        'start': start,
        'length': length,
        'content': content,
      };
}

class ThemeModeChangedMessage extends Message {
  final bool darkMode;

  const ThemeModeChangedMessage(this.darkMode);

  factory ThemeModeChangedMessage.fromJson(Map<String, dynamic> json) {
    return ThemeModeChangedMessage(json['darkMode'] as bool);
  }

  @override
  Map<String, dynamic> toMessageJson() => {'darkMode': darkMode};
}

class ThemeChangedMessage extends Message {
  final int primary;
  final int surfaceContainer;
  final int onSurface;

  const ThemeChangedMessage(this.primary, this.surfaceContainer, this.onSurface);

  factory ThemeChangedMessage.fromJson(Map<String, dynamic> json) {
    return ThemeChangedMessage(
      json['primary'] as int,
      json['surfaceContainer'] as int,
      json['onSurface'] as int,
    );
  }

  @override
  Map<String, dynamic> toMessageJson() => {
        'primary': primary,
        'surfaceContainer': surfaceContainer,
        'onSurface': onSurface,
      };
}

class UnlockMessage extends Message {
  const UnlockMessage();

  factory UnlockMessage.fromJson(Map<String, dynamic> json) {
    return const UnlockMessage();
  }

  @override
  Map<String, dynamic> toMessageJson() => const {};
}
