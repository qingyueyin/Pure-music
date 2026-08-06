// ignore_for_file: unnecessary_this

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:logger/logger.dart';
import 'package:pinyin/pinyin.dart';

extension StringHMMSS on Duration {
  /// Returns a string with hours, minutes, seconds,
  /// in the following format: H:MM:SS
  String toStringHMMSS() {
    return toString().split('.').first;
  }

  String toStringMSS() {
    final totalSeconds = inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// LRC/增强 LRC 时间标签格式 [mm:ss.xx] 或 <mm:ss.xx>
  String toStringLrc({String open = '[', String close = ']'}) {
    final totalMs = inMilliseconds < 0 ? 0 : inMilliseconds;
    final m = totalMs ~/ 60000;
    final s = (totalMs % 60000) / 1000.0;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toStringAsFixed(2).padLeft(5, '0');
    return '$open$mm:$ss$close';
  }
}

const int _pinyinCacheMaxSize = 2000;
Map<String, String> _pinyinCache = {};
List<String> _pinyinCacheAccessOrder = [];

extension PinyinCompare on String {
  /// convert str to pinyin, cache it when it hasn't been converted;
  String _getPinyin() {
    final cachedPinyin = _pinyinCache[this];
    if (cachedPinyin != null) {
      _pinyinCacheAccessOrder.remove(this);
      _pinyinCacheAccessOrder.add(this);
      return cachedPinyin;
    }

    final splited = this.split('');
    final pinyinBuilder = StringBuffer();

    for (var c in splited) {
      if (ChineseHelper.isChinese(c)) {
        final pinyin = PinyinHelper.convertToPinyinArray(
          c,
          PinyinFormat.WITHOUT_TONE,
        ).firstOrNull;

        pinyinBuilder.write(pinyin ?? c);
      } else {
        pinyinBuilder.write(c);
      }
    }

    final pinyin = pinyinBuilder.toString();

    _pinyinCache[this] = pinyin;
    _pinyinCacheAccessOrder.add(this);

    while (_pinyinCache.length > _pinyinCacheMaxSize) {
      final oldestKey = _pinyinCacheAccessOrder.removeAt(0);
      _pinyinCache.remove(oldestKey);
    }

    return pinyin;
  }

  /// Compares this string to [other] with pinyin first, else use the ordering of the code units.
  ///
  /// Returns a negative value if `this` is ordered before `other`,
  /// a positive value if `this` is ordered after `other`,
  /// or zero if `this` and `other` are equivalent.
  int localeCompareTo(String other) {
    final thisContainsChinese = ChineseHelper.containsChinese(this);
    final otherContainsChinese = ChineseHelper.containsChinese(other);

    final thisCmpStr = thisContainsChinese ? this._getPinyin() : this;
    final otherCmpStr = otherContainsChinese ? other._getPinyin() : other;

    return thisCmpStr.compareTo(otherCmpStr);
  }

  int naturalCompareTo(String other) {
    final a = this;
    final b = other;
    final aTokens = _tokenizeForNaturalCompare(a);
    final bTokens = _tokenizeForNaturalCompare(b);

    final len =
        aTokens.length < bTokens.length ? aTokens.length : bTokens.length;
    for (int i = 0; i < len; i++) {
      final ta = aTokens[i];
      final tb = bTokens[i];
      if (ta.isNumber && tb.isNumber) {
        final cmp = ta.number!.compareTo(tb.number!);
        if (cmp != 0) return cmp;
        final lenCmp = ta.text.length.compareTo(tb.text.length);
        if (lenCmp != 0) return lenCmp;
        continue;
      }
      final cmp = ta.text.toLowerCase().localeCompareTo(tb.text.toLowerCase());
      if (cmp != 0) return cmp;
    }
    return aTokens.length.compareTo(bTokens.length);
  }
}

class _NaturalToken {
  final bool isNumber;
  final String text;
  final BigInt? number;
  const _NaturalToken._(this.isNumber, this.text, this.number);
  factory _NaturalToken.text(String text) => _NaturalToken._(false, text, null);
  factory _NaturalToken.number(String text) =>
      _NaturalToken._(true, text, BigInt.tryParse(text) ?? BigInt.zero);
}

List<_NaturalToken> _tokenizeForNaturalCompare(String input) {
  if (input.isEmpty) return const [];
  final tokens = <_NaturalToken>[];
  final buffer = StringBuffer();
  bool? inNumber;

  for (int i = 0; i < input.length; i++) {
    final c = input.codeUnitAt(i);
    final isDigit = c >= 0x30 && c <= 0x39;
    if (inNumber == null) {
      inNumber = isDigit;
      buffer.writeCharCode(c);
      continue;
    }

    if (isDigit == inNumber) {
      buffer.writeCharCode(c);
      continue;
    }

    final text = buffer.toString();
    tokens
        .add(inNumber ? _NaturalToken.number(text) : _NaturalToken.text(text));
    buffer.clear();
    inNumber = isDigit;
    buffer.writeCharCode(c);
  }

  final text = buffer.toString();
  tokens.add(
      inNumber == true ? _NaturalToken.number(text) : _NaturalToken.text(text));
  return tokens;
}

final GlobalKey<NavigatorState> routerKey = GlobalKey();

final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

enum ToastVariant { info, success, error }

void showTextOnSnackBar(
  String text, {
  IconData? icon,
  ToastVariant variant = ToastVariant.info,
}) {
  final context =
      scaffoldMessengerKey.currentContext ?? routerKey.currentContext;
  final overlay = routerKey.currentState?.overlay;
  if (context == null || overlay == null) return;

  _toastEntry?.remove();
  _toastTimer?.cancel();

  final scheme = Theme.of(context).colorScheme;
  final txtColor = scheme.onInverseSurface;
  final textTheme = Theme.of(context).textTheme;
  final IconData effectiveIcon;
  switch (variant) {
    case ToastVariant.success:
      effectiveIcon = icon ?? Icons.check_circle_outline;
    case ToastVariant.error:
      effectiveIcon = icon ?? Icons.error_outline;
    case ToastVariant.info:
      effectiveIcon = icon ?? Icons.info_outline;
  }

  final visible = ValueNotifier(false);
  final entry = OverlayEntry(
    builder: (context) => Positioned.fill(
      child: IgnorePointer(
        child: SafeArea(
          minimum: const EdgeInsets.all(16.0),
          child: Padding(
            padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ValueListenableBuilder(
                valueListenable: visible,
                builder: (context, v, child) => AnimatedOpacity(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.fastOutSlowIn,
                  opacity: v ? 1.0 : 0.0,
                  child: AnimatedScale(
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.fastOutSlowIn,
                    scale: v ? 1.0 : 0.96,
                    child: child,
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.inverseSurface,
                    borderRadius: const BorderRadius.all(Radius.circular(4)),
                    boxShadow: [
                      BoxShadow(
                        color: scheme.shadow.withAlpha(40),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Spacing.md,
                      vertical: Spacing.sm,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(effectiveIcon, size: 16, color: txtColor),
                        const SizedBox(width: Spacing.sm),
                        Text(
                          text,
                          style: textTheme.labelLarge?.copyWith(
                            color: txtColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  _toastEntry = entry;
  overlay.insert(entry);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!identical(_toastEntry, entry)) return;
    visible.value = true;
  });

  _toastTimer = Timer(const Duration(seconds: 2), () {
    visible.value = false;
    Timer(const Duration(milliseconds: 160), () {
      entry.remove();
      if (identical(_toastEntry, entry)) {
        _toastEntry = null;
        _toastTimer = null;
      }
    });
  });
}

OverlayEntry? _toastEntry;
Timer? _toastTimer;

OverlayEntry? _lyricWriteEntry;
Timer? _lyricWriteTimer;

OverlayEntry? _hotkeyToastEntry;
Timer? _hotkeyToastTimer;

void showHotkeyToast({
  required String text,
  IconData? icon,
}) {
  final context =
      scaffoldMessengerKey.currentContext ?? routerKey.currentContext;
  final overlay = routerKey.currentState?.overlay;
  if (context == null || overlay == null) return;

  _hotkeyToastTimer?.cancel();
  _hotkeyToastEntry?.remove();

  final scheme = Theme.of(context).colorScheme;
  final textTheme = Theme.of(context).textTheme;
  final visible = ValueNotifier(false);
  final entry = OverlayEntry(
    builder: (context) => Positioned.fill(
      child: IgnorePointer(
        child: SafeArea(
          minimum: const EdgeInsets.all(16.0),
          child: Padding(
            padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ValueListenableBuilder(
                valueListenable: visible,
                builder: (context, v, child) => AnimatedOpacity(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.fastOutSlowIn,
                  opacity: v ? 1.0 : 0.0,
                  child: AnimatedScale(
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.fastOutSlowIn,
                    scale: v ? 1.0 : 0.96,
                    child: child,
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.inverseSurface,
                    borderRadius: const BorderRadius.all(Radius.circular(4)),
                    boxShadow: [
                      BoxShadow(
                        color: scheme.shadow.withAlpha(40),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Spacing.md,
                      vertical: Spacing.sm,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, size: 16, color: scheme.onInverseSurface),
                          const SizedBox(width: Spacing.sm),
                        ],
                        Text(
                          text,
                          style: textTheme.labelLarge?.copyWith(
                            color: scheme.onInverseSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  _hotkeyToastEntry = entry;
  overlay.insert(entry);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!identical(_hotkeyToastEntry, entry)) return;
    visible.value = true;
  });

  _hotkeyToastTimer = Timer(const Duration(milliseconds: 1100), () {
    visible.value = false;
    Timer(const Duration(milliseconds: 160), () {
      entry.remove();
      if (identical(_hotkeyToastEntry, entry)) {
        _hotkeyToastEntry = null;
        _hotkeyToastTimer = null;
      }
    });
  });
}

/// 显示网络歌词写入标签的提示（Overlay bubble）
bool showLyricWritePrompt({
  required String title,
  required VoidCallback onWrite,
  required VoidCallback onDismiss,
}) {
  final context =
      scaffoldMessengerKey.currentContext ?? routerKey.currentContext;
  final overlay = routerKey.currentState?.overlay;
  if (context == null || overlay == null) return false;

  hideLyricWritePrompt();

  final scheme = Theme.of(context).colorScheme;
  final textTheme = Theme.of(context).textTheme;

  final visible = ValueNotifier(false);
  OverlayEntry? entry;
  entry = OverlayEntry(
    builder: (context) => Positioned.fill(
      child: SafeArea(
        minimum: const EdgeInsets.all(16.0),
        child: Padding(
          padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ValueListenableBuilder(
              valueListenable: visible,
              builder: (context, v, child) => AnimatedOpacity(
                duration: const Duration(milliseconds: 140),
                curve: Curves.fastOutSlowIn,
                opacity: v ? 1.0 : 0.0,
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.fastOutSlowIn,
                  scale: v ? 1.0 : 0.96,
                  child: child,
                ),
              ),
              child: GestureDetector(
                onTap: () {
                  hideLyricWritePrompt();
                  onWrite();
                },
                child: Material(
                  type: MaterialType.transparency,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Spacing.md,
                      vertical: Spacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.inverseSurface,
                      borderRadius: const BorderRadius.all(Radius.circular(4)),
                      boxShadow: [
                        BoxShadow(
                          color: scheme.shadow.withAlpha(40),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.lyrics_outlined,
                          size: 16,
                          color: scheme.onInverseSurface,
                        ),
                        const SizedBox(width: Spacing.sm),
                        Text(
                          '写入标签？',
                          style: textTheme.labelLarge?.copyWith(
                            color: scheme.onInverseSurface,
                          ),
                        ),
                        const SizedBox(width: Spacing.sm),
                        Text(
                          '写入',
                          style: textTheme.labelLarge?.copyWith(
                            color: scheme.onInverseSurface,
                            fontWeight: AppType.weightBold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  _lyricWriteEntry = entry;
  overlay.insert(entry);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!identical(_lyricWriteEntry, entry)) return;
    visible.value = true;
  });

  _lyricWriteTimer = Timer(const Duration(seconds: 8), () {
    visible.value = false;
    Timer(const Duration(milliseconds: 160), () {
      entry?.remove();
      if (identical(_lyricWriteEntry, entry)) {
        _lyricWriteEntry = null;
        _lyricWriteTimer = null;
      }
    });
  });
  return true;
}

void hideLyricWritePrompt() {
  _lyricWriteTimer?.cancel();
  _lyricWriteTimer = null;
  _lyricWriteEntry?.remove();
  _lyricWriteEntry = null;
}

final _diagnosticWindowsPathPattern = RegExp(
  r'(?:[A-Za-z]:\\|\\\\)[^|"\r\n]*?(?=\s+\((?:error|code)\b|[|"\r\n]|$)',
  caseSensitive: false,
);
final _diagnosticUnixPathPattern = RegExp(
  r'/(?:Users|home)/[^|"\r\n]*?(?=\s+\((?:error|code)\b|[|"\r\n]|$)',
  caseSensitive: false,
);
final _diagnosticUrlQueryPattern = RegExp(
  r'(https?://[^\s?|]+)\?[^\s|]+',
  caseSensitive: false,
);
final _diagnosticSecretFieldPattern = RegExp(
  r'\b(access[_-]?key|auth[_-]?token|token|device[_-]?id|session[_-]?id)\s*[:=]\s*[^&\s|]+',
  caseSensitive: false,
);

String redactDiagnosticData(String text) {
  return text
      .replaceAll(_diagnosticWindowsPathPattern, '[local path]')
      .replaceAll(_diagnosticUnixPathPattern, '[local path]')
      .replaceAllMapped(
        _diagnosticUrlQueryPattern,
        (match) => '${match.group(1)}?[redacted]',
      )
      .replaceAllMapped(
        _diagnosticSecretFieldPattern,
        (match) => '${match.group(1)}=[redacted]',
      );
}

/// 自定义 MemoryOutput：限制最大条目数，防止无限膨胀
class _BoundedMemoryOutput extends LogOutput {
  _BoundedMemoryOutput({this.secondOutput});

  final LogOutput? secondOutput;

  static const _maxEvents = 500;
  final _buffer = <OutputEvent>[];
  int _firstEventIndex = 0;
  int _nextEventIndex = 0;

  List<OutputEvent> get buffer => List.unmodifiable(_buffer);
  int get firstEventIndex => _firstEventIndex;
  int get nextEventIndex => _nextEventIndex;

  OutputEvent? eventAt(int index) {
    final localIndex = index - _firstEventIndex;
    if (localIndex < 0 || localIndex >= _buffer.length) return null;
    return _buffer[localIndex];
  }

  @override
  void output(OutputEvent event) {
    _buffer.add(event);
    _nextEventIndex++;
    while (_buffer.length > _maxEvents) {
      _buffer.removeAt(0);
      _firstEventIndex++;
    }
    secondOutput?.output(event);
  }

  void clear() {
    _buffer.clear();
    _firstEventIndex = _nextEventIndex;
  }
}

final loggerMemoryOutput = _BoundedMemoryOutput(
  secondOutput: kDebugMode ? ConsoleOutput() : null,
);
final logger = Logger(
  filter: ProductionFilter(),
  printer: SimplePrinter(colors: false),
  output: loggerMemoryOutput,
  level: Level.all,
);
