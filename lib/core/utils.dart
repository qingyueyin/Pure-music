// ignore_for_file: unnecessary_this

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
void showTextOnSnackBar(String text) {
  showHotkeyToast(text: text);
}

OverlayEntry? _hotkeyToastEntry;
Timer? _hotkeyToastTimer;

void showHotkeyToast({
  required String text,
  IconData? icon,
}) {
  final context =
      scaffoldMessengerKey.currentContext ?? routerKey.currentContext;
  if (context == null) return;
  final overlay = Overlay.of(context, rootOverlay: true);

  _hotkeyToastTimer?.cancel();
  _hotkeyToastEntry?.remove();

  final scheme = Theme.of(context).colorScheme;
  final visible = ValueNotifier(false);
  _hotkeyToastEntry = OverlayEntry(
    builder: (context) => Positioned.fill(
      child: IgnorePointer(
        child: SafeArea(
          minimum: const EdgeInsets.all(16.0),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 84.0),
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
                child: Material(
                  type: MaterialType.transparency,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14.0,
                      vertical: 10.0,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer.withAlpha(235),
                      borderRadius: BorderRadius.circular(20.0),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(
                            icon,
                            size: 18,
                            color: scheme.onSecondaryContainer,
                          ),
                          const SizedBox(width: 8.0),
                        ],
                        Text(
                          text,
                          style: TextStyle(
                            color: scheme.onSecondaryContainer,
                            fontWeight: FontWeight.w600,
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

  overlay.insert(_hotkeyToastEntry!);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_hotkeyToastEntry == null) return;
    visible.value = true;
  });

  _hotkeyToastTimer?.cancel();
  _hotkeyToastEntry?.remove();

  _hotkeyToastTimer = Timer(const Duration(milliseconds: 1100), () {
    visible.value = false;
    Timer(const Duration(milliseconds: 160), () {
      _hotkeyToastEntry?.remove();
      _hotkeyToastEntry = null;
      _hotkeyToastTimer = null;
    });
  });
}

/// 显示网络歌词写入标签的提示（轻量级 SnackBar）
void showLyricWritePrompt({
  required String title,
  required VoidCallback onWrite,
  required VoidCallback onDismiss,
}) {
  scaffoldMessengerKey.currentState?.hideCurrentSnackBar();

  final ctx = scaffoldMessengerKey.currentContext;
  final scheme = ctx != null ? Theme.of(ctx).colorScheme : null;

  scaffoldMessengerKey.currentState?.showSnackBar(
    SnackBar(
      content: Text('写入标签？',
          style: TextStyle(fontSize: 14, color: scheme?.onSecondaryContainer)),
      backgroundColor: scheme?.secondaryContainer.withAlpha(240),
      duration: const Duration(seconds: 30),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.only(left: 16, right: 16, bottom: 96),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      action: SnackBarAction(
        label: '写入',
        textColor: scheme?.onSecondaryContainer,
        onPressed: onWrite,
      ),
      onVisible: () {
        // 3 秒后自动忽略（不写入标记，下次还可再提示）
        Future.delayed(const Duration(seconds: 8), () {
          scaffoldMessengerKey.currentState?.hideCurrentSnackBar();
        });
      },
    ),
  );
}

/// 自定义 MemoryOutput：限制最大条目数，防止无限膨胀
class _BoundedMemoryOutput extends LogOutput {
  _BoundedMemoryOutput({this.secondOutput});

  final LogOutput? secondOutput;

  static const _maxEvents = 500;
  final _buffer = <OutputEvent>[];

  List<OutputEvent> get buffer => List.unmodifiable(_buffer);

  @override
  void output(OutputEvent event) {
    _buffer.add(event);
    while (_buffer.length > _maxEvents) {
      _buffer.removeAt(0);
    }
    secondOutput?.output(event);
  }

  void clear() => _buffer.clear();
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
