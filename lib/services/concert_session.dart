import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/play_service/play_service.dart';

/// 演出节目单的一幕：半开区间 [start, end)。
class ConcertSection {
  const ConcertSection({
    required this.name,
    required this.start,
    required this.end,
  });

  final String name;
  final int start;
  final int end;

  int get count => end - start;
}

const double kConcertActHeaderExtent = 40;
const double kConcertSongExtent = 64;

/// 按编排曲线关键帧切幕；短歌单合并段数，避免碎幕。
List<ConcertSection> concertSectionsFor({
  required int count,
  required double climaxPosition,
}) {
  if (count < 3) return const [];
  final climax = climaxPosition.clamp(0.55, 0.95);
  final List<(String, double, double)> bounds;
  if (count < 8) {
    bounds = [('开场', 0.0, 0.35), ('压轴', 0.35, climax), ('尾声', climax, 1.0)];
  } else if (count < 20) {
    bounds = [('开场', 0.0, 0.3), ('主轴', 0.3, climax), ('压轴 · 尾声', climax, 1.0)];
  } else {
    final climaxEnd = climax + 0.07 < 1.0 ? climax + 0.07 : 1.0;
    bounds = [
      ('开场', 0.0, 0.12),
      ('升温', 0.12, 0.26),
      ('回落', 0.26, 0.48),
      ('冲刺', 0.48, climax),
      ('压轴', climax, climaxEnd),
      ('尾声', climaxEnd, 1.0),
    ];
  }
  final sections = <ConcertSection>[];
  var cursor = 0;
  for (var index = 0; index < bounds.length; index++) {
    final (name, startRatio, endRatio) = bounds[index];
    final isLast = index == bounds.length - 1;
    final end = isLast
        ? count
        : ((endRatio * count).round()).clamp(cursor, count);
    final start = cursor;
    if (end <= start) continue;
    sections.add(ConcertSection(name: name, start: start, end: end));
    cursor = end;
  }
  return sections;
}

List<int> concertQueueLayout(int songCount, List<ConcertSection> sections) {
  if (sections.isEmpty) {
    return [for (var song = 0; song < songCount; song++) song];
  }
  final layout = <int>[];
  for (var sectionIndex = 0; sectionIndex < sections.length; sectionIndex++) {
    final section = sections[sectionIndex];
    layout.add(-(sectionIndex + 1));
    for (var song = section.start; song < section.end; song++) {
      layout.add(song);
    }
  }
  return layout;
}

String? concertActAt(
  List<ConcertSection> sections,
  int index, {
  required int length,
}) {
  if (index < 0 || index >= length) return null;
  for (final section in sections) {
    if (index >= section.start && index < section.end) return section.name;
  }
  if (sections.isEmpty && length >= 2) return '演出';
  return null;
}

bool concertPlaylistMatches(List<String> expected, List<String> actual) {
  if (expected.length != actual.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (expected[i] != actual[i]) return false;
  }
  return true;
}

double concertSongScrollOffset(int songIndex, List<ConcertSection> sections) {
  if (sections.isEmpty) return songIndex * kConcertSongExtent;
  var offset = 0.0;
  for (final section in sections) {
    offset += kConcertActHeaderExtent;
    if (songIndex < section.end) {
      final local = songIndex - section.start;
      if (local < 0) return offset;
      return offset + local * kConcertSongExtent;
    }
    offset += section.count * kConcertSongExtent;
  }
  return songIndex * kConcertSongExtent;
}

/// 开演后绑定当前队列；队列被替换、打乱或清空时结束。
class ConcertSession extends ChangeNotifier {
  ConcertSession._();

  static final ConcertSession instance = ConcertSession._();

  bool _active = false;
  bool _attached = false;
  String _name = '';
  List<String> _paths = const [];
  List<ConcertSection> _sections = const [];
  double _climaxPosition = 0.82;
  String? _lastAnnouncedAct;

  /// 演出会话的本地存档：appData/concert_session.json，退出重进后接着开演。
  static const String _sessionFileName = 'concert_session.json';

  bool get isActive => _active;
  String get name => _name;
  int get length => _paths.length;
  List<ConcertSection> get sections => _sections;

  String? actAt(int index) =>
      concertActAt(_sections, index, length: _paths.length);

  String? consumeActAnnouncement(int index) {
    final act = actAt(index);
    if (act == null || act == _lastAnnouncedAct) return null;
    _lastAnnouncedAct = act;
    return act;
  }

  void begin({
    required String name,
    required List<String> paths,
    required double climaxPosition,
  }) {
    if (paths.length < 2) {
      end();
      return;
    }
    _name = name;
    _paths = List<String>.of(paths);
    _sections = concertSectionsFor(
      count: paths.length,
      climaxPosition: climaxPosition,
    );
    _climaxPosition = climaxPosition;
    _lastAnnouncedAct = null;
    _active = true;
    _ensureAttached();
    unawaited(_persistSession());
    notifyListeners();
  }

  void end() {
    if (!_active) return;
    _active = false;
    _name = '';
    _paths = const [];
    _sections = const [];
    _lastAnnouncedAct = null;
    unawaited(_clearSessionFile());
    notifyListeners();
  }

  /// 启动时在播放队列恢复完成后调用：存档跟当前队列对得上就接着开演，对不上就丢弃。
  Future<void> restoreAfterStartup() async {
    if (_active) return;
    String name;
    double climaxPosition;
    List<String> paths;
    try {
      final file = await _sessionFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      name = decoded['name']?.toString() ?? '';
      climaxPosition =
          (decoded['climaxPosition'] as num?)?.toDouble() ?? 0.82;
      paths = [
        for (final path in decoded['paths'] ?? const [])
          if (path is String) path,
      ];
    } catch (error, trace) {
      log.app.warn(
        'legacy',
        '[concert] session restore failed',
        error: error,
        stackTrace: trace,
      );
      return;
    }
    final playback = PlayService.instance.playbackService;
    final playlist = playback.playlistNotifier.value;
    final matches =
        name.isNotEmpty &&
        paths.length >= 2 &&
        !playback.shuffle.value &&
        concertPlaylistMatches(paths, [
          for (final audio in playlist) audio.path,
        ]);
    if (!matches) {
      await _clearSessionFile();
      return;
    }
    _name = name;
    _paths = List<String>.of(paths);
    _sections = concertSectionsFor(
      count: paths.length,
      climaxPosition: climaxPosition,
    );
    _climaxPosition = climaxPosition;
    _lastAnnouncedAct = null;
    _active = true;
    _ensureAttached();
    notifyListeners();
  }

  Future<File> _sessionFile() async {
    final dir = await getAppDataDir();
    return File('${dir.path}${Platform.pathSeparator}$_sessionFileName');
  }

  Future<void> _persistSession() async {
    try {
      final file = await _sessionFile();
      await file.writeAsString(
        jsonEncode({
          'name': _name,
          'climaxPosition': _climaxPosition,
          'paths': _paths,
        }),
        flush: true,
      );
    } catch (error, trace) {
      log.app.warn(
        'legacy',
        '[concert] session save failed',
        error: error,
        stackTrace: trace,
      );
    }
  }

  Future<void> _clearSessionFile() async {
    try {
      final file = await _sessionFile();
      if (!await file.exists()) return;
      await file.delete();
    } catch (error, trace) {
      log.app.warn(
        'legacy',
        '[concert] session clear failed',
        error: error,
        stackTrace: trace,
      );
    }
  }

  void _ensureAttached() {
    if (_attached) return;
    _attached = true;
    final playback = PlayService.instance.playbackService;
    playback.playlistNotifier.addListener(_syncWithPlayback);
    playback.shuffle.addListener(_syncWithPlayback);
  }

  void _syncWithPlayback() {
    if (!_active) return;
    final playback = PlayService.instance.playbackService;
    if (playback.shuffle.value) {
      end();
      return;
    }
    final playlist = playback.playlistNotifier.value;
    if (!concertPlaylistMatches(_paths, [
      for (final audio in playlist) audio.path,
    ])) {
      end();
    }
  }
}
