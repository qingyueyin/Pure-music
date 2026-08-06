import 'dart:math';

import 'package:flutter/material.dart';

import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/settings.dart';
import 'package:flutter/foundation.dart';

@immutable
class LyricRenderConfig {
  final LyricTextAlign textAlign;
  final double baseFontSize;
  final double translationBaseFontSize;
  final bool showTranslation;
  final bool showRoman;
  final List<LyricLineTrack> lineOrder;
  final int fontWeight;
  final bool enableBlur;
  final bool enableStaggeredAnimation;
  final bool enableAudioReactive;
  final double audioReactiveStrength;
  final bool enableGlow;
  final LyricLiftStyle liftStyle;
  final double liftPeak;
  final int liftDurationMs;
  final LyricStaggerStyle staggerStyle;
  final bool hasMultipleAgents; // 多声部 TTML 时对齐由 agent 决定
  final LyricDisplayMode displayMode;

  /// true → CustomPaint (LyricsLineWidget), 零 GC 压力
  /// false → Widget 方案 (LyricViewTile), 逐字动画更丰富
  final bool useCustomPaint;
  final double viewportFadeExtent;
  final double mainLineScale;
  final double subLineScale;
  final double mainTranslationScale;
  final double subTranslationScale;
  final double activeLineScaleMultiplier;
  final double inactiveLineScaleMultiplier;
  final double blurSigmaStep;
  final double blurSigmaMax;
  final Duration implicitAnimationDuration;
  final int viewportLeadingLines;
  final int viewportTrailingLines;
  final double viewportOverscanScreens;
  final Duration userScrollHoldDuration;

  const LyricRenderConfig({
    required this.textAlign,
    required this.baseFontSize,
    required this.translationBaseFontSize,
    required this.showTranslation,
    required this.showRoman,
    required this.fontWeight,
    required this.enableBlur,
    this.lineOrder = defaultLyricLineOrder,
    this.enableStaggeredAnimation = true,
    this.enableAudioReactive = false,
    this.audioReactiveStrength = 0.5,
    this.enableGlow = false,
    this.liftStyle = LyricLiftStyle.vertical,
    this.liftPeak = 2.0,
    this.liftDurationMs = 300,
    this.staggerStyle = LyricStaggerStyle.smooth,
    this.hasMultipleAgents = false,
    this.displayMode = LyricDisplayMode.wordByWord,
    this.useCustomPaint = true,
    this.viewportFadeExtent = 0.04,
    this.mainLineScale = 1.0,
    this.subLineScale = 1.0,
    this.mainTranslationScale = 0.78,
    this.subTranslationScale = 0.70,
    this.activeLineScaleMultiplier = 1.0,
    this.inactiveLineScaleMultiplier = 0.90,
    this.blurSigmaStep = 0.6,
    this.blurSigmaMax = 2.5,
    this.implicitAnimationDuration = const Duration(milliseconds: 300),
    this.viewportLeadingLines = 2,
    this.viewportTrailingLines = 3,
    this.viewportOverscanScreens = 0.75,
    this.userScrollHoldDuration = const Duration(seconds: 2),
  });

  List<LyricLineTrack> get normalizedLineOrder =>
      normalizedLyricLineOrder(lineOrder);

  LyricRenderConfig copyWith({
    LyricTextAlign? textAlign,
    double? baseFontSize,
    double? translationBaseFontSize,
    bool? showTranslation,
    bool? showRoman,
    List<LyricLineTrack>? lineOrder,
    int? fontWeight,
    bool? enableBlur,
    bool? enableStaggeredAnimation,
    bool? enableAudioReactive,
    double? audioReactiveStrength,
    bool? enableGlow,
    LyricLiftStyle? liftStyle,
    double? liftPeak,
    int? liftDurationMs,
    LyricStaggerStyle? staggerStyle,
    bool? hasMultipleAgents,
    LyricDisplayMode? displayMode,
    bool? useCustomPaint,
    double? viewportFadeExtent,
    double? mainLineScale,
    double? subLineScale,
    double? mainTranslationScale,
    double? subTranslationScale,
    double? activeLineScaleMultiplier,
    double? inactiveLineScaleMultiplier,
    double? blurSigmaStep,
    double? blurSigmaMax,
    Duration? implicitAnimationDuration,
    int? viewportLeadingLines,
    int? viewportTrailingLines,
    double? viewportOverscanScreens,
    Duration? userScrollHoldDuration,
  }) {
    return LyricRenderConfig(
      textAlign: textAlign ?? this.textAlign,
      baseFontSize: baseFontSize ?? this.baseFontSize,
      translationBaseFontSize:
          translationBaseFontSize ?? this.translationBaseFontSize,
      showTranslation: showTranslation ?? this.showTranslation,
      showRoman: showRoman ?? this.showRoman,
      lineOrder: lineOrder ?? this.lineOrder,
      fontWeight: fontWeight ?? this.fontWeight,
      enableBlur: enableBlur ?? this.enableBlur,
      enableStaggeredAnimation:
          enableStaggeredAnimation ?? this.enableStaggeredAnimation,
      enableAudioReactive: enableAudioReactive ?? this.enableAudioReactive,
      audioReactiveStrength:
          audioReactiveStrength ?? this.audioReactiveStrength,
      enableGlow: enableGlow ?? this.enableGlow,
      liftStyle: liftStyle ?? this.liftStyle,
      liftPeak: liftPeak ?? this.liftPeak,
      liftDurationMs: liftDurationMs ?? this.liftDurationMs,
      staggerStyle: staggerStyle ?? this.staggerStyle,
      hasMultipleAgents: hasMultipleAgents ?? this.hasMultipleAgents,
      displayMode: displayMode ?? this.displayMode,
      useCustomPaint: useCustomPaint ?? this.useCustomPaint,
      viewportFadeExtent: viewportFadeExtent ?? this.viewportFadeExtent,
      mainLineScale: mainLineScale ?? this.mainLineScale,
      subLineScale: subLineScale ?? this.subLineScale,
      mainTranslationScale: mainTranslationScale ?? this.mainTranslationScale,
      subTranslationScale: subTranslationScale ?? this.subTranslationScale,
      activeLineScaleMultiplier:
          activeLineScaleMultiplier ?? this.activeLineScaleMultiplier,
      inactiveLineScaleMultiplier:
          inactiveLineScaleMultiplier ?? this.inactiveLineScaleMultiplier,
      blurSigmaStep: blurSigmaStep ?? this.blurSigmaStep,
      blurSigmaMax: blurSigmaMax ?? this.blurSigmaMax,
      implicitAnimationDuration:
          implicitAnimationDuration ?? this.implicitAnimationDuration,
      viewportLeadingLines: viewportLeadingLines ?? this.viewportLeadingLines,
      viewportTrailingLines:
          viewportTrailingLines ?? this.viewportTrailingLines,
      viewportOverscanScreens:
          viewportOverscanScreens ?? this.viewportOverscanScreens,
      userScrollHoldDuration:
          userScrollHoldDuration ?? this.userScrollHoldDuration,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LyricRenderConfig &&
        other.textAlign == textAlign &&
        other.baseFontSize == baseFontSize &&
        other.translationBaseFontSize == translationBaseFontSize &&
        other.showTranslation == showTranslation &&
        other.showRoman == showRoman &&
        listEquals(other.lineOrder, lineOrder) &&
        other.fontWeight == fontWeight &&
        other.enableBlur == enableBlur &&
        other.enableStaggeredAnimation == enableStaggeredAnimation &&
        other.enableAudioReactive == enableAudioReactive &&
        other.audioReactiveStrength == audioReactiveStrength &&
        other.enableGlow == enableGlow &&
        other.liftStyle == liftStyle &&
        other.liftPeak == liftPeak &&
        other.liftDurationMs == liftDurationMs &&
        other.staggerStyle == staggerStyle &&
        other.hasMultipleAgents == hasMultipleAgents &&
        other.displayMode == displayMode &&
        other.useCustomPaint == useCustomPaint &&
        other.viewportFadeExtent == viewportFadeExtent &&
        other.mainLineScale == mainLineScale &&
        other.subLineScale == subLineScale &&
        other.mainTranslationScale == mainTranslationScale &&
        other.subTranslationScale == subTranslationScale &&
        other.activeLineScaleMultiplier == activeLineScaleMultiplier &&
        other.inactiveLineScaleMultiplier == inactiveLineScaleMultiplier &&
        other.blurSigmaStep == blurSigmaStep &&
        other.blurSigmaMax == blurSigmaMax &&
        other.implicitAnimationDuration == implicitAnimationDuration &&
        other.viewportLeadingLines == viewportLeadingLines &&
        other.viewportTrailingLines == viewportTrailingLines &&
        other.viewportOverscanScreens == viewportOverscanScreens &&
        other.userScrollHoldDuration == userScrollHoldDuration;
  }

  @override
  int get hashCode => Object.hashAll([
    textAlign,
    baseFontSize,
    translationBaseFontSize,
    showTranslation,
    showRoman,
    Object.hashAll(lineOrder),
    fontWeight,
    enableBlur,
    enableStaggeredAnimation,
    enableAudioReactive,
    audioReactiveStrength,
    enableGlow,
    liftStyle,
    liftPeak,
    liftDurationMs,
    staggerStyle,
    hasMultipleAgents,
    displayMode,
    useCustomPaint,
    viewportFadeExtent,
    mainLineScale,
    subLineScale,
    mainTranslationScale,
    subTranslationScale,
    activeLineScaleMultiplier,
    inactiveLineScaleMultiplier,
    blurSigmaStep,
    blurSigmaMax,
    implicitAnimationDuration,
    viewportLeadingLines,
    viewportTrailingLines,
    viewportOverscanScreens,
    userScrollHoldDuration,
  ]);

  FontWeight discreteFontWeight([int? resolvedWeight]) {
    final weight = (resolvedWeight ?? fontWeight).clamp(100, 900);
    return FontWeight.values[((weight / 100).round() - 1).clamp(0, 8)];
  }

  double primaryLineHeight([int? _]) => 1.2;

  double translationLineHeight([int? _]) => 1.5;

  double letterSpacing({double? fontSize, int? weight}) => 0.3;

  double primaryFontSize({required bool isMainLine}) {
    return baseFontSize * (isMainLine ? mainLineScale : subLineScale);
  }

  double translationFontSize({required bool isMainLine}) {
    return translationBaseFontSize *
        (isMainLine ? mainTranslationScale : subTranslationScale);
  }

  double blurSigmaForDistance(int distance) {
    if (!enableBlur) return 0.0;
    return min(distance * blurSigmaStep, blurSigmaMax);
  }

  double gapBoost({required bool isMainLine}) {
    return ((fontWeight - 550).clamp(0, 350) / 350) * (isMainLine ? 2.0 : 1.5);
  }

  double syncVerticalPadding({required bool isMainLine}) {
    if (!isMainLine) return 12.0;
    final base =
        baseFontSize *
        0.35 *
        (1.0 + ((fontWeight - 600).clamp(0, 300) / 300) * 0.10);
    return base.clamp(10.0, 20.0).toDouble();
  }

  double lrcVerticalPadding() {
    final base =
        baseFontSize *
        0.32 *
        (1.0 + ((fontWeight - 600).clamp(0, 300) / 300) * 0.10);
    return base.clamp(10.0, 18.0).toDouble();
  }

  double syncTranslationGap({required bool isMainLine}) {
    return (isMainLine ? 8.0 : 4.0) + gapBoost(isMainLine: isMainLine);
  }

  double lrcTranslationGap({
    required bool isMainLine,
    required int translationIndex,
  }) {
    if (translationIndex > 0) return 2.0;
    return (isMainLine ? 6.0 : 4.0) + gapBoost(isMainLine: isMainLine);
  }

  List<double> viewportMaskStops() {
    return <double>[0.0, viewportFadeExtent, 1.0 - viewportFadeExtent, 1.0];
  }
}
