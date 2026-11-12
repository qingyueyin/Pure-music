import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pure_music/core/equalizer_action_state.dart';
import 'package:pure_music/core/audio_dsp_settings.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/page_preference.dart';
import 'package:pure_music/core/setting_action_state.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/log/app_log.dart';
import 'package:path/path.dart' as path;

export 'page_preference.dart';

part 'preference_app.dart';
part 'now_playing_page_preference.dart';
part 'playback_preference.dart';

class EqPreset {
  String name;
  List<double> gains;
  final int bandModelVersion;
  final bool hasAudioState;
  final bool eqEnabled;
  final double preampDb;
  final bool eqAutoGainEnabled;
  final double eqAutoHeadroomDb;
  final AudioDspSettings audioDspSettings;

  EqPreset(
    this.name,
    this.gains, {
    this.bandModelVersion = currentEqBandModelVersion,
    this.hasAudioState = true,
    this.eqEnabled = true,
    this.preampDb = 0.0,
    this.eqAutoGainEnabled = true,
    this.eqAutoHeadroomDb = 1.0,
    this.audioDspSettings = const AudioDspSettings(),
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'name': name,
      'gains': gains,
      'eqBandModelVersion': currentEqBandModelVersion,
    };
    if (hasAudioState) {
      map.addAll({
        'eqEnabled': eqEnabled,
        'preampDb': preampDb,
        'eqAutoGainEnabled': eqAutoGainEnabled,
        'eqAutoHeadroomDb': eqAutoHeadroomDb,
        'audioDspSettings': audioDspSettings.toMap(),
      });
    }
    return map;
  }

  factory EqPreset.fromMap(Map<String, dynamic> map) {
    final storedVersion = _normalizedBoundedInt(
      map['eqBandModelVersion'],
      defaultValue: legacyEqBandModelVersion,
      min: legacyEqBandModelVersion,
      max: currentEqBandModelVersion,
    );
    final hasAudioState =
        map.containsKey('eqEnabled') ||
        map.containsKey('preampDb') ||
        map.containsKey('eqAutoGainEnabled') ||
        map.containsKey('eqAutoHeadroomDb') ||
        map.containsKey('audioDspSettings');
    return EqPreset(
      _normalizedString(map['name']),
      migrateEqGains(map['gains'], fromVersion: storedVersion),
      bandModelVersion: currentEqBandModelVersion,
      hasAudioState: hasAudioState,
      eqEnabled: _normalizedBool(map['eqEnabled'], defaultValue: true),
      preampDb: normalizedEqPreampDb(map['preampDb']),
      eqAutoGainEnabled: _normalizedBool(
        map['eqAutoGainEnabled'],
        defaultValue: true,
      ),
      eqAutoHeadroomDb: _normalizedBoundedDouble(
        map['eqAutoHeadroomDb'],
        defaultValue: 1.0,
        min: 0.0,
        max: 24.0,
      ),
      audioDspSettings: AudioDspSettings.fromMap(map['audioDspSettings']),
    );
  }
}

List<EqPreset> _eqPresetsFromStoredValue(Object? value) {
  if (value is! Iterable) return const [];
  return _uniqueEqPresets(
    value.map(_eqPresetFromStoredValue).whereType<EqPreset>(),
  );
}

EqPreset? _eqPresetFromStoredValue(Object? value) {
  if (value is! Map<String, dynamic>) return null;
  final name = value['name'];
  if (name is! String) return null;
  return EqPreset.fromMap(value);
}

List<EqPreset> _uniqueEqPresets(Iterable<EqPreset> presets) {
  final result = <EqPreset>[];
  final indexByKey = <String, int>{};
  for (final preset in presets) {
    final name = normalizedEqPresetName(preset.name);
    final key = eqPresetNameKey(name);
    if (key.isEmpty) continue;
    final gains = List<double>.from(preset.gains);
    final existingIndex = indexByKey[key];
    if (existingIndex == null) {
      indexByKey[key] = result.length;
      result.add(
        EqPreset(
          name,
          gains,
          bandModelVersion: preset.bandModelVersion,
          hasAudioState: preset.hasAudioState,
          eqEnabled: preset.eqEnabled,
          preampDb: preset.preampDb,
          eqAutoGainEnabled: preset.eqAutoGainEnabled,
          eqAutoHeadroomDb: preset.eqAutoHeadroomDb,
          audioDspSettings: preset.audioDspSettings,
        ),
      );
      continue;
    }
    final firstName = result[existingIndex].name;
    result[existingIndex] = EqPreset(
      firstName,
      gains,
      bandModelVersion: preset.bandModelVersion,
      hasAudioState: preset.hasAudioState,
      eqEnabled: preset.eqEnabled,
      preampDb: preset.preampDb,
      eqAutoGainEnabled: preset.eqAutoGainEnabled,
      eqAutoHeadroomDb: preset.eqAutoHeadroomDb,
      audioDspSettings: preset.audioDspSettings,
    );
  }
  return result;
}

double _normalizedBoundedDouble(
  Object? value, {
  required double defaultValue,
  required double min,
  required double max,
}) {
  final number = switch (value) {
    num() => value.toDouble(),
    String() => double.tryParse(value),
    _ => null,
  };
  if (number == null || !number.isFinite) return defaultValue;
  return number.clamp(min, max).toDouble();
}

double _normalizedVolumeDsp(Object? value) {
  if (value is String) {
    final normalized = value.trim();
    if (normalized.endsWith('%') || normalized.endsWith('％')) {
      final percent = double.tryParse(
        normalized.substring(0, normalized.length - 1).trim(),
      );
      if (percent == null || !percent.isFinite) return 1.0;
      return (percent / 100.0).clamp(0.0, 1.0).toDouble();
    }
  }
  return _normalizedBoundedDouble(value, defaultValue: 1.0, min: 0.0, max: 1.0);
}

int _normalizedBoundedInt(
  Object? value, {
  required int defaultValue,
  required int min,
  required int max,
}) {
  final number = _normalizedInteger(value);
  if (number == null) return defaultValue;
  return number.clamp(min, max);
}

int? _normalizedInteger(Object? value) {
  if (value is int) return value;
  if (value is num) {
    if (!value.isFinite) return null;
    final number = value.toDouble();
    if (number != number.truncateToDouble()) return null;
    return value.toInt();
  }
  if (value is! String) return null;
  final normalized = value.trim();
  final integer = int.tryParse(normalized);
  if (integer != null) return integer;
  final number = double.tryParse(normalized);
  if (number == null || !number.isFinite) return null;
  if (number != number.truncateToDouble()) return null;
  return number.toInt();
}

bool _normalizedBool(Object? value, {required bool defaultValue}) {
  return normalizedBoolSetting(value, defaultValue: defaultValue);
}

NowPlayingViewMode? _nowPlayingViewModeFromStoredValue(Object? value) {
  final index = _normalizedEnumIndex(value, NowPlayingViewMode.values.length);
  if (index != null) return NowPlayingViewMode.values[index];
  final name = _normalizedEnumName(value);
  return name == null ? null : NowPlayingViewMode.fromString(name);
}

NowPlayingBackgroundMode? _nowPlayingBackgroundModeFromStoredValue(
  Object? value,
) {
  final index = _normalizedEnumIndex(
    value,
    NowPlayingBackgroundMode.values.length,
  );
  if (index != null) return NowPlayingBackgroundMode.values[index];
  final name = _normalizedEnumName(value);
  return name == null ? null : NowPlayingBackgroundMode.fromString(name);
}

LyricTextAlign? _lyricTextAlignFromStoredValue(Object? value) {
  final index = _normalizedEnumIndex(value, LyricTextAlign.values.length);
  if (index != null) return LyricTextAlign.values[index];
  final name = _normalizedEnumName(value);
  return name == null ? null : LyricTextAlign.fromString(name);
}

PlayMode? _playModeFromStoredValue(Object? value) {
  final index = _normalizedEnumIndex(value, PlayMode.values.length);
  if (index != null) return PlayMode.values[index];
  final name = _normalizedEnumName(value);
  return name == null ? null : PlayMode.fromString(name);
}

TransitionMode _transitionModeFromStored(Map<String, dynamic> map) {
  final stored = map['transitionMode'];
  if (stored is String) {
    final parsed = TransitionMode.fromString(stored);
    if (parsed != null) return parsed;
  }
  final oldCrossfade = map['crossfadeMs'];
  if (oldCrossfade is num && oldCrossfade > 0) {
    return TransitionMode.crossfade;
  }
  final oldFadeOut = map['fadeOutMs'];
  final oldFadeIn = map['fadeInMs'];
  if (oldFadeOut is num && oldFadeOut > 0 ||
      oldFadeIn is num && oldFadeIn > 0) {
    return TransitionMode.fade;
  }
  return TransitionMode.seamless;
}

ReplayGainMode _replayGainModeFromStored(Object? value) {
  final name = _normalizedEnumName(value);
  if (name == null) return ReplayGainMode.track;
  return ReplayGainMode.fromString(name) ?? ReplayGainMode.track;
}

int? _normalizedEnumIndex(Object? value, int length) {
  final index = _normalizedInteger(value);
  if (index == null || index < 0 || index >= length) return null;
  return index;
}

String? _normalizedEnumName(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  if (normalized.isEmpty) return null;
  final separator = normalized.lastIndexOf('.');
  return separator < 0 ? normalized : normalized.substring(separator + 1);
}

String _normalizedString(Object? value) {
  return value is String ? value.trim() : '';
}

String _normalizedPathString(Object? value) {
  return value is String ? _normalizedFolderPath(value) : '';
}

List<String> _normalizedPathStringList(Object? value) {
  if (value is String && _looksLikeFolderPath(value)) {
    final path = _normalizedFolderPath(value);
    return path.isEmpty ? const [] : [path];
  }
  return _normalizedStringList(
    value,
  ).map(_normalizedFolderPath).where((item) => item.isNotEmpty).toList();
}

List<String> _normalizedStringList(Object? value) {
  if (value is! Iterable) return const [];
  return value
      .whereType<String>()
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}

List<String> _normalizedUpdateCheckUrls(Object? value) {
  final values = value is String ? [value] : _normalizedStringList(value);
  final result = <String>[];
  final seen = <String>{};
  for (final raw in values) {
    final item = raw.trim();
    final lowerItem = item.toLowerCase();
    if (!lowerItem.startsWith('http://') && !lowerItem.startsWith('https://')) {
      continue;
    }
    final uri = Uri.tryParse(item);
    if (uri == null || uri.host.isEmpty) continue;
    if (seen.add(_updateUrlKey(item))) result.add(item);
  }
  return result;
}

String _updateUrlKey(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty) {
    final schemeEnd = value.indexOf('://');
    if (schemeEnd <= 0) return value;
    return value.substring(0, schemeEnd).toLowerCase() +
        value.substring(schemeEnd);
  }
  return uri
      .replace(
        scheme: uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
        fragment: '',
      )
      .toString();
}

List<String> _normalizedFolderPathList(Object? value) {
  final incoming = value is String && _looksLikeFolderPath(value)
      ? [_normalizedFolderPath(value)]
      : _normalizedStringList(value).map(_normalizedFolderPath);
  return appendUniquePendingFolders(current: const [], incoming: incoming);
}

Map<String, String> _folderAliasesFromStoredValue(Object? value) {
  if (value is! Map) return {};
  final result = <String, String>{};
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! String) continue;
    final key = pendingFolderKey(entry.key as String);
    final alias = (entry.value as String).trim();
    if (key.isEmpty || alias.isEmpty) continue;
    result[key] = alias;
  }
  return result;
}

bool _looksLikeFolderPath(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return false;
  return normalized.contains(r'\') ||
      normalized.contains('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized);
}

String _normalizedFolderPath(String value) {
  final normalized = value.trim();
  final uri = Uri.tryParse(normalized);
  if (uri != null && uri.scheme.toLowerCase() == 'file') {
    final host = uri.host.toLowerCase();
    if ((host.isEmpty || host == 'localhost') && uri.path == '/') {
      return '';
    }
    if (host == 'localhost') {
      return uri.replace(host: '').toFilePath(windows: true);
    }
    return uri.toFilePath(windows: true);
  }
  return normalized;
}

String _normalizedNonEmptyString(
  Object? value, {
  required String defaultValue,
}) {
  if (value is! String) return defaultValue;
  final normalized = value.trim();
  return normalized.isEmpty ? defaultValue : normalized;
}

String? _normalizedNullableString(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

ValueNotifier<NowPlayingBackgroundMode>? _nowPlayingBackgroundModeNotifier;
ValueNotifier<bool>? _nowPlayingDynamicFlowingLightNotifier;
ValueNotifier<bool>? _nowPlayingAudioReactiveFlowNotifier;

ValueNotifier<NowPlayingBackgroundMode> get nowPlayingBackgroundModeNotifier {
  return _nowPlayingBackgroundModeNotifier ??= ValueNotifier(
    AppPreference.instance.nowPlayingPagePref.backgroundMode,
  );
}

ValueNotifier<bool> get nowPlayingDynamicFlowingLightNotifier {
  return _nowPlayingDynamicFlowingLightNotifier ??= ValueNotifier(
    AppPreference.instance.nowPlayingPagePref.dynamicFlowingLight,
  );
}

ValueNotifier<bool> get nowPlayingAudioReactiveFlowNotifier {
  return _nowPlayingAudioReactiveFlowNotifier ??= ValueNotifier(
    AppPreference.instance.nowPlayingPagePref.audioReactiveFlow,
  );
}
