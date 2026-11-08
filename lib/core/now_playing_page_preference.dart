part of 'preference.dart';

enum AudioReactiveFlowVersion { legacy, v2 }

class NowPlayingPagePreference {
  NowPlayingViewMode nowPlayingViewMode;
  LyricTextAlign lyricTextAlign;
  double lyricFontSize;
  double translationFontSize;
  bool showLyricTranslation;
  bool showLyricRoman;
  RubyPosition rubyPosition;
  int lyricFontWeight;
  bool enableLyricBlur;
  bool enableLyricGlow;
  LyricLiftStyle liftStyle;
  double liftPeak;
  int liftDurationMs;
  LyricStaggerStyle staggerStyle;
  bool durationFeather;
  NowPlayingBackgroundMode backgroundMode;
  bool dynamicFlowingLight;
  bool audioReactiveFlow;
  AudioReactiveFlowVersion audioReactiveFlowVersion;

  NowPlayingPagePreference(
    this.nowPlayingViewMode,
    this.lyricTextAlign,
    this.lyricFontSize,
    this.translationFontSize,
    this.showLyricTranslation,
    this.lyricFontWeight,
    this.enableLyricBlur, {
    this.showLyricRoman = true,
    this.rubyPosition = RubyPosition.below,
    this.enableLyricGlow = true,
    this.liftStyle = LyricLiftStyle.vertical,
    this.liftPeak = 2.0,
    this.liftDurationMs = lyricVerticalLiftDurationMs,
    this.staggerStyle = LyricStaggerStyle.smooth,
    this.durationFeather = false,
    this.backgroundMode = NowPlayingBackgroundMode.meshGradient,
    this.dynamicFlowingLight = true,
    this.audioReactiveFlow = false,
    this.audioReactiveFlowVersion = AudioReactiveFlowVersion.legacy,
  });

  LyricRenderConfig get lyricRenderConfig => LyricRenderConfig(
    textAlign: lyricTextAlign,
    baseFontSize: lyricFontSize,
    translationBaseFontSize: translationFontSize,
    showTranslation: showLyricTranslation,
    showRoman: showLyricRoman,
    lineOrder: rubyPosition.toLineOrder(),
    fontWeight: lyricFontWeight,
    enableBlur: enableLyricBlur,
    enableGlow: enableLyricGlow,
    liftStyle: liftStyle,
    liftPeak: liftPeak,
    liftDurationMs: lyricVerticalLiftDurationMs,
    staggerStyle: staggerStyle,
    durationFeather: durationFeather,
  );

  Map<String, dynamic> toMap() => {
    'nowPlayingViewMode': nowPlayingViewMode.name,
    'lyricTextAlign': lyricTextAlign.name,
    'lyricFontSize': lyricFontSize,
    'translationFontSize': translationFontSize,
    'showLyricTranslation': showLyricTranslation,
    'showLyricRoman': showLyricRoman,
    'rubyPosition': rubyPosition.name,
    'lyricFontWeight': lyricFontWeight,
    'enableLyricBlur': enableLyricBlur,
    'enableLyricGlow': enableLyricGlow,
    'liftStyle': liftStyle.name,
    'liftPeak': liftPeak,
    'liftDurationMs': lyricVerticalLiftDurationMs,
    'staggerStyle': staggerStyle.name,
    'durationFeather': durationFeather,
    'backgroundMode': backgroundMode.name,
    'dynamicFlowingLight': dynamicFlowingLight,
    'audioReactiveFlow': audioReactiveFlow,
    'audioReactiveFlowVersion': audioReactiveFlowVersion.name,
  };

  factory NowPlayingPagePreference.fromMap(Object? value) {
    final map = value is Map<String, dynamic>
        ? value
        : const <String, dynamic>{};
    final look = _lyricLookFromMap(map);
    final backgroundMode =
        _nowPlayingBackgroundModeFromStoredValue(map['backgroundMode']) ??
        NowPlayingBackgroundMode.meshGradient;
    return NowPlayingPagePreference(
      look.viewMode,
      look.textAlign,
      look.fontSize,
      look.translationFontSize,
      look.showTranslation,
      look.fontWeight,
      look.enableBlur,
      showLyricRoman: look.showRoman,
      rubyPosition: look.rubyPosition,
      enableLyricGlow: look.enableGlow,
      liftStyle: look.liftStyle,
      liftPeak: look.liftPeak,
      liftDurationMs: lyricVerticalLiftDurationMs,
      staggerStyle: look.staggerStyle,
      durationFeather: _normalizedBool(
        map['durationFeather'],
        defaultValue: false,
      ),
      backgroundMode: backgroundMode,
      dynamicFlowingLight: true,
      audioReactiveFlow: _normalizedBool(
        map['audioReactiveFlow'],
        defaultValue: false,
      ),
      audioReactiveFlowVersion: AudioReactiveFlowVersion.values.firstWhere(
        (version) => version.name == map['audioReactiveFlowVersion'],
        orElse: () => AudioReactiveFlowVersion.legacy,
      ),
    );
  }

  static ({
    NowPlayingViewMode viewMode,
    LyricTextAlign textAlign,
    double fontSize,
    double translationFontSize,
    bool showTranslation,
    int fontWeight,
    bool enableBlur,
    bool showRoman,
    RubyPosition rubyPosition,
    bool enableGlow,
    LyricLiftStyle liftStyle,
    double liftPeak,
    LyricStaggerStyle staggerStyle,
  })
  _lyricLookFromMap(Map<String, dynamic> map) {
    final type = _lyricTypeFromMap(map);
    final lift = _lyricLiftFromMap(map);
    return (
      viewMode: type.viewMode,
      textAlign: type.textAlign,
      fontSize: type.fontSize,
      translationFontSize: type.translationFontSize,
      showTranslation: type.showTranslation,
      fontWeight: type.fontWeight,
      enableBlur: type.enableBlur,
      showRoman: type.showRoman,
      rubyPosition: lift.rubyPosition,
      enableGlow: lift.enableGlow,
      liftStyle: lift.liftStyle,
      liftPeak: lift.liftPeak,
      staggerStyle: lift.staggerStyle,
    );
  }

  static ({
    NowPlayingViewMode viewMode,
    LyricTextAlign textAlign,
    double fontSize,
    double translationFontSize,
    bool showTranslation,
    int fontWeight,
    bool enableBlur,
    bool showRoman,
  })
  _lyricTypeFromMap(Map<String, dynamic> map) {
    return (
      viewMode:
          _nowPlayingViewModeFromStoredValue(map['nowPlayingViewMode']) ??
          NowPlayingViewMode.withLyric,
      textAlign:
          _lyricTextAlignFromStoredValue(map['lyricTextAlign']) ??
          LyricTextAlign.left,
      fontSize: _normalizedBoundedDouble(
        map['lyricFontSize'],
        defaultValue: 22.0,
        min: 16.0,
        max: 48.0,
      ),
      translationFontSize: _normalizedBoundedDouble(
        map['translationFontSize'],
        defaultValue: 18.0,
        min: 12.0,
        max: 44.0,
      ),
      showTranslation: _normalizedBool(
        map['showLyricTranslation'],
        defaultValue: true,
      ),
      fontWeight: _normalizedBoundedInt(
        map['lyricFontWeight'],
        defaultValue: 400,
        min: 100,
        max: 900,
      ),
      enableBlur: _normalizedBool(map['enableLyricBlur'], defaultValue: true),
      showRoman: _normalizedBool(map['showLyricRoman'], defaultValue: true),
    );
  }

  static ({
    RubyPosition rubyPosition,
    bool enableGlow,
    LyricLiftStyle liftStyle,
    double liftPeak,
    LyricStaggerStyle staggerStyle,
  })
  _lyricLiftFromMap(Map<String, dynamic> map) {
    return (
      rubyPosition:
          RubyPosition.fromString((map['rubyPosition'] as String?) ?? '') ??
          RubyPosition.below,
      enableGlow: _normalizedBool(map['enableLyricGlow'], defaultValue: true),
      liftStyle:
          LyricLiftStyle.fromString((map['liftStyle'] as String?) ?? '') ??
          LyricLiftStyle.vertical,
      liftPeak: _normalizedBoundedDouble(
        map['liftPeak'],
        defaultValue: 2.0,
        min: 0.5,
        max: 6.0,
      ),
      staggerStyle:
          LyricStaggerStyle.fromString(
            (map['staggerStyle'] as String?) ?? '',
          ) ??
          LyricStaggerStyle.smooth,
    );
  }
}

class NowPlayingPagePreferenceCodec {
  const NowPlayingPagePreferenceCodec._();

  static NowPlayingPagePreference decode(Object? value) =>
      NowPlayingPagePreference.fromMap(value);

  static Map<String, dynamic> encode(NowPlayingPagePreference value) =>
      value.toMap();
}
