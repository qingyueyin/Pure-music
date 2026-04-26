import 'dart:math';

import 'package:flutter/material.dart';

import 'package:pure_music/core/enums.dart';

@immutable
class LyricSpringDescription {
  final double stiffness;
  final double damping;
  final double mass;

  const LyricSpringDescription({
    required this.stiffness,
    required this.damping,
    required this.mass,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LyricSpringDescription &&
        other.stiffness == stiffness &&
        other.damping == damping &&
        other.mass == mass;
  }

  @override
  int get hashCode => Object.hash(stiffness, damping, mass);
}

@immutable
class LyricRenderConfig {
  final LyricTextAlign textAlign;
  final double baseFontSize;
  final double translationBaseFontSize;
  final bool showTranslation;
  final bool showRoman;
  final int fontWeight;
  final bool enableBlur;
  final bool enableWordEmphasis;
  final bool enableLineScale;
  final bool enableLineSpring;
  final bool enableStaggeredAnimation;
  final bool enableAudioReactive;
  final double audioReactiveStrength;
  final double viewportFadeExtent;
  final double emphasisLiftPx;
  final double emphasisScaleBoost;
  final double emphasisGlowIntensity;
  final double emphasisAttackRatio;
  final double emphasisReleaseRatio;
  final double mainLineScale;
  final double subLineScale;
  final double mainTranslationScale;
  final double subTranslationScale;
  final double activeLineScaleMultiplier;
  final double inactiveLineScaleMultiplier;
  final double blurSigmaStep;
  final double blurSigmaMax;
  final Duration implicitAnimationDuration;
  final LyricSpringDescription lineSpring;
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
    required this.enableWordEmphasis,
    this.enableLineScale = true,
    this.enableLineSpring = true,
    this.enableStaggeredAnimation = true,
    this.enableAudioReactive = false,
    this.audioReactiveStrength = 0.5,
    this.viewportFadeExtent = 0.04,
    this.emphasisLiftPx = 0.5,
    this.emphasisScaleBoost = 0.035,
    this.emphasisGlowIntensity = 0.2,
    this.emphasisAttackRatio = 0.3,
    this.emphasisReleaseRatio = 0.3,
    this.mainLineScale = 1.0,
    this.subLineScale = 1.0,
    this.mainTranslationScale = 0.78,
    this.subTranslationScale = 0.70,
    this.activeLineScaleMultiplier = 1.0,
    this.inactiveLineScaleMultiplier = 0.90,
    this.blurSigmaStep = 1.0,
    this.blurSigmaMax = 4.0,
    this.implicitAnimationDuration = const Duration(milliseconds: 300),
    this.lineSpring = const LyricSpringDescription(
      stiffness: 90.0,
      damping: 15.0,
      mass: 0.9,
    ),
    this.viewportLeadingLines = 2,
    this.viewportTrailingLines = 3,
    this.viewportOverscanScreens = 1.25,
    this.userScrollHoldDuration = const Duration(seconds: 2),
  });

  bool get shouldApplyWordEmphasis => enableWordEmphasis;

  LyricRenderConfig copyWith({
    LyricTextAlign? textAlign,
    double? baseFontSize,
    double? translationBaseFontSize,
    bool? showTranslation,
    bool? showRoman,
    int? fontWeight,
    bool? enableBlur,
    bool? enableWordEmphasis,
    bool? enableLineScale,
    bool? enableLineSpring,
    bool? enableStaggeredAnimation,
    bool? enableAudioReactive,
    double? audioReactiveStrength,
    double? viewportFadeExtent,
    double? emphasisLiftPx,
    double? emphasisScaleBoost,
    double? emphasisGlowIntensity,
    double? emphasisAttackRatio,
    double? emphasisReleaseRatio,
    double? mainLineScale,
    double? subLineScale,
    double? mainTranslationScale,
    double? subTranslationScale,
    double? activeLineScaleMultiplier,
    double? inactiveLineScaleMultiplier,
    double? blurSigmaStep,
    double? blurSigmaMax,
    Duration? implicitAnimationDuration,
    LyricSpringDescription? lineSpring,
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
      fontWeight: fontWeight ?? this.fontWeight,
      enableBlur: enableBlur ?? this.enableBlur,
      enableWordEmphasis: enableWordEmphasis ?? this.enableWordEmphasis,
      enableLineScale: enableLineScale ?? this.enableLineScale,
      enableLineSpring: enableLineSpring ?? this.enableLineSpring,
      enableStaggeredAnimation:
          enableStaggeredAnimation ?? this.enableStaggeredAnimation,
      enableAudioReactive: enableAudioReactive ?? this.enableAudioReactive,
      audioReactiveStrength:
          audioReactiveStrength ?? this.audioReactiveStrength,
      viewportFadeExtent: viewportFadeExtent ?? this.viewportFadeExtent,
      emphasisLiftPx: emphasisLiftPx ?? this.emphasisLiftPx,
      emphasisScaleBoost: emphasisScaleBoost ?? this.emphasisScaleBoost,
      emphasisGlowIntensity:
          emphasisGlowIntensity ?? this.emphasisGlowIntensity,
      emphasisAttackRatio: emphasisAttackRatio ?? this.emphasisAttackRatio,
      emphasisReleaseRatio: emphasisReleaseRatio ?? this.emphasisReleaseRatio,
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
      lineSpring: lineSpring ?? this.lineSpring,
      viewportLeadingLines: viewportLeadingLines ?? this.viewportLeadingLines,
      viewportTrailingLines:
          viewportTrailingLines ?? this.viewportTrailingLines,
      viewportOverscanScreens:
          viewportOverscanScreens ?? this.viewportOverscanScreens,
      userScrollHoldDuration:
          userScrollHoldDuration ?? this.userScrollHoldDuration,
    );
  }

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
    final base = baseFontSize *
        0.35 *
        (1.0 + ((fontWeight - 600).clamp(0, 300) / 300) * 0.10);
    return base.clamp(10.0, 20.0).toDouble();
  }

  double lrcVerticalPadding() {
    final base = baseFontSize *
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
    return <double>[
      0.0,
      viewportFadeExtent,
      1.0 - viewportFadeExtent,
      1.0,
    ];
  }
}
