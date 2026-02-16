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
    return toString().split(".").first;
  }

  String toStringMSS() {
    final totalSeconds = inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

/// 把 dec 表示成两位 hex
String _toHexString(int dec) {
  assert(dec >= 0 && dec <= 0xff);

  var hex = dec.toRadixString(16);
  if (hex.length == 1) hex = "0$hex";
  return hex;
}

extension RGBHexString on Color {
  String toRGBHexString() {
    final redHex = _toHexString(red);
    final greenHex = _toHexString(green);
    final blueHex = _toHexString(blue);

    return "#$redHex$greenHex$blueHex";
  }
}

/// [rgbHexStr] 必须是 #RRGGBB
Color? fromRGBHexString(String rgbHexStr) {
  if (rgbHexStr.startsWith("#") && rgbHexStr.length == 7) {
    return Color(0xff000000 + int.parse(rgbHexStr.substring(1), radix: 16));
  }

  return null;
}

Map<String, String> _pinyinCache = {};

extension PinyinCompare on String {
  /// convert str to pinyin, cache it when it hasn't been converted;
  String _getPinyin() {
    final cachedPinyin = _pinyinCache[this];
    if (cachedPinyin != null) return cachedPinyin;

    final splited = this.split("");
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

final GlobalKey<NavigatorState> ROUTER_KEY = GlobalKey();

final SCAFFOLD_MESSAGER = GlobalKey<ScaffoldMessengerState>();
void showTextOnSnackBar(String text) {
  SCAFFOLD_MESSAGER.currentState?.showSnackBar(SnackBar(content: Text(text)));
}

OverlayEntry? _hotkeyToastEntry;
Timer? _hotkeyToastTimer;

void showHotkeyToast({
  required String text,
  IconData? icon,
}) {
  final context = SCAFFOLD_MESSAGER.currentContext ?? ROUTER_KEY.currentContext;
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
                      color: scheme.secondaryContainer.withOpacity(0.92),
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

  _hotkeyToastTimer = Timer(const Duration(milliseconds: 1100), () {
    visible.value = false;
    Timer(const Duration(milliseconds: 160), () {
      _hotkeyToastEntry?.remove();
      _hotkeyToastEntry = null;
    });
  });
}

final LOGGER_MEMORY = MemoryOutput(
  secondOutput: kDebugMode ? ConsoleOutput() : null,
);
final LOGGER = Logger(
  filter: ProductionFilter(),
  printer: SimplePrinter(colors: false),
  output: LOGGER_MEMORY,
  level: Level.all,
);
