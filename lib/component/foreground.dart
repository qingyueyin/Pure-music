import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pure_player_lyric/component/action_row.dart';
import 'package:pure_player_lyric/component/lyric_line_view.dart';
import 'package:pure_player_lyric/component/now_playing_info.dart';
import 'package:pure_player_lyric/desktop_lyric_controller.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

final textDisplayController = TextDisplayController();

final ValueNotifier<double> backgroundOpacity = ValueNotifier(0);

List<Shadow> lyricTextShadows(Color color) {
  return [
    Shadow(
      color: Colors.black.withValues(alpha: 0.6),
      offset: const Offset(0, 1),
      blurRadius: 2,
    ),
  ];
}

Color lyricOutlineColor(bool useLightOutline) {
  return (useLightOutline ? Colors.white : Colors.black).withValues(
    alpha: useLightOutline ? 0.55 : 0.85,
  );
}

double lyricOutlineWidth(double fontSize) {
  return (fontSize * 0.08).clamp(1.5, 4.0).toDouble();
}

Widget outlinedText({
  Key? key,
  required String text,
  required TextStyle style,
  required Color outlineColor,
  required double outlineWidth,
  TextAlign? textAlign,
  int? maxLines,
  TextOverflow? overflow,
  bool? softWrap,
  bool applyShadow = true,
  bool enableOutline = true,
}) {
  if (!enableOutline) {
    return Text(
      text,
      key: key,
      style: style.copyWith(
        shadows: applyShadow
            ? lyricTextShadows(style.color ?? Colors.white)
            : null,
      ),
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
    );
  }

  final strokePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = outlineWidth
    ..color = outlineColor;

  final textShadows = applyShadow
      ? lyricTextShadows(style.color ?? Colors.white)
      : null;

  return Stack(
    key: key,
    alignment: Alignment.center,
    children: [
      Text(
        text,
        style: style.copyWith(foreground: strokePaint, shadows: textShadows),
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
        softWrap: softWrap,
      ),
      Text(
        text,
        style: style.copyWith(shadows: textShadows),
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
        softWrap: softWrap,
      ),
    ],
  );
}

FontWeight lyricFontWeightFromInt(int weight) {
  final clamped = weight.clamp(100, 900);
  return switch (clamped) {
    100 => FontWeight.w100,
    200 => FontWeight.w200,
    300 => FontWeight.w300,
    400 => FontWeight.w400,
    500 => FontWeight.w500,
    600 => FontWeight.w600,
    700 => FontWeight.w700,
    800 => FontWeight.w800,
    900 => FontWeight.w900,
    _ => FontWeight.values[((clamped / 100).round().clamp(1, 9)) - 1],
  };
}

enum LyricTextAlign { left, center, right }

enum LyricSwitchAnimation {
  slideUp,
  slideDown,
  fade,
  absorb,
  slideLeft,
  slideRight,
}

enum RomanPosition { aboveText, between, belowTranslation }

class TextDisplayController extends ChangeNotifier {
  double lyricFontSize = 22.0;
  double translationFontSize = 18.0;
  int lyricFontWeight = 700;
  bool showLyricTranslation = true;
  bool showRoman = true;
  RomanPosition romanPosition = RomanPosition.between;
  bool showNowPlayingInfo = true;
  LyricTextAlign lyricTextAlign = LyricTextAlign.center;
  LyricSwitchAnimation lyricAnimation = LyricSwitchAnimation.slideUp;
  bool enableStroke = true;
  bool enablePinTop = true;
  bool useLightOutline = false;

  static String get _settingsPath {
    final appData = Platform.environment['APPDATA'] ?? '.';
    return '$appData/pure-player-lyric/settings.json';
  }

  Timer? _saveDebounce;

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), save);
  }

  void save() {
    final data = {
      'lyricFontSize': lyricFontSize,
      'translationFontSize': translationFontSize,
      'lyricFontWeight': lyricFontWeight,
      'showLyricTranslation': showLyricTranslation,
      'showRoman': showRoman,
      'romanPosition': romanPosition.index,
      'showNowPlayingInfo': showNowPlayingInfo,
      'lyricTextAlign': lyricTextAlign.index,
      'lyricAnimation': lyricAnimation.index,
      'enableStroke': enableStroke,
      'enablePinTop': enablePinTop,
      'useLightOutline': useLightOutline,
      'hasSpecifiedColor': hasSpecifiedPlayedColor,
      'specifiedColor': playedColor.toARGB32(),
      'hasSpecifiedUnplayedColor': hasSpecifiedUnplayedColor,
      'unplayedColor': unplayedColor.toARGB32(),
      'backgroundOpacity': backgroundOpacity.value,
    };
    try {
      final dir = Directory(_settingsPath).parent;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File(_settingsPath).writeAsStringSync(jsonEncode(data));
    } catch (_) {}
  }

  void load() {
    try {
      final file = File(_settingsPath);
      if (!file.existsSync()) return;
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      lyricFontSize = (data['lyricFontSize'] as num?)?.toDouble() ?? 22.0;
      translationFontSize =
          (data['translationFontSize'] as num?)?.toDouble() ?? 18.0;
      lyricFontWeight = (data['lyricFontWeight'] as num?)?.toInt() ?? 700;
      showLyricTranslation = (data['showLyricTranslation'] as bool?) ?? true;
      showRoman = (data['showRoman'] as bool?) ?? true;
      romanPosition =
          RomanPosition.values[(data['romanPosition'] as num?)?.toInt() ?? 1];
      showNowPlayingInfo = (data['showNowPlayingInfo'] as bool?) ?? true;
      lyricTextAlign =
          LyricTextAlign.values[(data['lyricTextAlign'] as num?)?.toInt() ?? 1];
      final lyricAnimationIndex =
          (data['lyricAnimation'] as num?)?.toInt() ?? 0;
      lyricAnimation =
          LyricSwitchAnimation.values[lyricAnimationIndex
              .clamp(0, LyricSwitchAnimation.values.length - 1)
              .toInt()];
      enableStroke = (data['enableStroke'] as bool?) ?? true;
      enablePinTop = (data['enablePinTop'] as bool?) ?? true;
      useLightOutline = (data['useLightOutline'] as bool?) ?? false;
      hasSpecifiedPlayedColor = (data['hasSpecifiedColor'] as bool?) ?? false;
      if (data['specifiedColor'] != null) {
        playedColor = Color((data['specifiedColor'] as num).toInt());
      }
      hasSpecifiedUnplayedColor =
          (data['hasSpecifiedUnplayedColor'] as bool?) ?? false;
      if (data['unplayedColor'] != null) {
        unplayedColor = Color((data['unplayedColor'] as num).toInt());
      }
      if (data['backgroundOpacity'] != null) {
        backgroundOpacity.value = (data['backgroundOpacity'] as num).toDouble();
      }
      notifyListeners();
    } catch (_) {}
  }

  /// 瑕嗙洊 notifyListeners 鑷姩瑙﹀彂鎸佷箙鍖?
  @override
  void notifyListeners() {
    super.notifyListeners();
    _scheduleSave();
  }

  bool hasSpecifiedPlayedColor = false;
  Color playedColor = Color(
    DesktopLyricController.instance.theme.value.primary,
  );
  bool hasSpecifiedUnplayedColor = false;
  Color unplayedColor = Color(
    DesktopLyricController.instance.theme.value.primary,
  );

  void increaseLyricFontSize() {
    if (lyricFontSize >= 48) return;
    lyricFontSize += 2;
    translationFontSize = (lyricFontSize - 4).clamp(12, 44).toDouble();
    notifyListeners();
  }

  void decreaseLyricFontSize() {
    if (lyricFontSize <= 16) return;
    lyricFontSize -= 2;
    translationFontSize = (lyricFontSize - 4).clamp(12, 44).toDouble();
    notifyListeners();
  }

  void switchLyricTextAlign() {
    lyricTextAlign = switch (lyricTextAlign) {
      LyricTextAlign.left => LyricTextAlign.center,
      LyricTextAlign.center => LyricTextAlign.right,
      LyricTextAlign.right => LyricTextAlign.left,
    };
    notifyListeners();
  }

  void toggleLyricTranslation() {
    showLyricTranslation = !showLyricTranslation;
    notifyListeners();
  }

  void toggleRoman() {
    showRoman = !showRoman;
    notifyListeners();
  }

  void toggleNowPlayingInfo() {
    showNowPlayingInfo = !showNowPlayingInfo;
    notifyListeners();
  }

  void setFontWeight(int weight) {
    lyricFontWeight = weight.clamp(100, 900);
    notifyListeners();
  }

  void increaseFontWeight() {
    setFontWeight(lyricFontWeight + 100);
  }

  void decreaseFontWeight() {
    setFontWeight(lyricFontWeight - 100);
  }

  void specifyPlayedColor(Color color) {
    playedColor = color;
    hasSpecifiedPlayedColor = true;
    notifyListeners();
  }

  void usePlayerTheme() {
    hasSpecifiedPlayedColor = false;
    hasSpecifiedUnplayedColor = false;
    notifyListeners();
  }

  void specifyUnplayedColor(Color color) {
    unplayedColor = color;
    hasSpecifiedUnplayedColor = true;
    notifyListeners();
  }

  void toggleStroke() {
    enableStroke = !enableStroke;
    notifyListeners();
  }

  void setRomanPosition(RomanPosition pos) {
    romanPosition = pos;
    notifyListeners();
  }

  void cycleRomanPosition() {
    final values = RomanPosition.values;
    romanPosition = values[(romanPosition.index + 1) % values.length];
    notifyListeners();
  }

  void applyConfig(Map<String, dynamic> config) {
    bool changed = false;
    if (config['lyricFontSize'] != null) {
      lyricFontSize = (config['lyricFontSize'] as num).toDouble();
      changed = true;
    }
    if (config['translationFontSize'] != null) {
      translationFontSize = (config['translationFontSize'] as num).toDouble();
      changed = true;
    }
    if (config['lyricFontWeight'] != null) {
      lyricFontWeight = (config['lyricFontWeight'] as num).toInt();
      changed = true;
    }
    if (config['showLyricTranslation'] != null) {
      showLyricTranslation = config['showLyricTranslation'] as bool;
      changed = true;
    }
    if (config['showRoman'] != null) {
      showRoman = config['showRoman'] as bool;
      changed = true;
    }
    if (config['romanPosition'] != null) {
      romanPosition =
          RomanPosition.values[(config['romanPosition'] as num).toInt()];
      changed = true;
    }
    if (config['showNowPlayingInfo'] != null) {
      showNowPlayingInfo = config['showNowPlayingInfo'] as bool;
      changed = true;
    }
    if (config['lyricTextAlign'] != null) {
      lyricTextAlign =
          LyricTextAlign.values[(config['lyricTextAlign'] as num).toInt()];
      changed = true;
    }
    if (config['lyricAnimation'] != null) {
      final index = (config['lyricAnimation'] as num).toInt();
      lyricAnimation =
          LyricSwitchAnimation.values[index
              .clamp(0, LyricSwitchAnimation.values.length - 1)
              .toInt()];
      changed = true;
    }
    if (config['enableStroke'] != null) {
      enableStroke = config['enableStroke'] as bool;
      changed = true;
    }
    if (config['backgroundOpacity'] != null) {
      backgroundOpacity.value = (config['backgroundOpacity'] as num).toDouble();
      changed = true;
    }
    if (config['useLightOutline'] != null) {
      useLightOutline = config['useLightOutline'] as bool;
      changed = true;
    }
    if (config['playedColor'] != null) {
      playedColor = Color((config['playedColor'] as num).toInt());
      hasSpecifiedPlayedColor = true;
      changed = true;
    }
    if (config['unplayedColor'] != null) {
      unplayedColor = Color((config['unplayedColor'] as num).toInt());
      hasSpecifiedUnplayedColor = true;
      changed = true;
    }
    if (changed) notifyListeners();
  }
}

class DesktopLyricForeground extends StatelessWidget {
  final bool isHovering;
  const DesktopLyricForeground({super.key, required this.isHovering});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: ChangeNotifierProvider.value(
        value: textDisplayController,
        child: Consumer<TextDisplayController>(
          builder: (context, textDisplayController, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: isHovering
                    ? const RepaintBoundary(child: ActionRow())
                    : SizedBox(
                        height: 40,
                        width: double.infinity,
                        child: textDisplayController.showNowPlayingInfo
                            ? const RepaintBoundary(child: NowPlayingInfo())
                            : const SizedBox.shrink(),
                      ),
              ),
              const SizedBox(height: 8),
              const Expanded(child: LyricLineView()),
            ],
          ),
        ),
      ),
    );
  }
}
