final _eqPresetNameWhitespacePattern = RegExp(r'\s+');
const int eqBandCount = 10;
const double eqGainMinDb = -15.0;
const double eqGainMaxDb = 15.0;
const double eqPreampMinDb = -24.0;
const double eqPreampMaxDb = 24.0;

String normalizedEqPresetName(String value) {
  return value.trim().replaceAll(_eqPresetNameWhitespacePattern, ' ');
}

String eqPresetNameKey(String value) =>
    normalizedEqPresetName(value).toLowerCase();

String? findEquivalentEqPresetName({
  required Iterable<String> existingNames,
  required String input,
}) {
  final inputKey = eqPresetNameKey(input);
  if (inputKey.isEmpty) return null;
  for (final name in existingNames) {
    if (eqPresetNameKey(name) == inputKey) {
      return normalizedEqPresetName(name);
    }
  }
  return null;
}

bool canSubmitEqPresetName({
  required String input,
  required bool isSaving,
}) {
  if (isSaving) return false;
  return normalizedEqPresetName(input).isNotEmpty;
}

bool shouldRemoveEqPresetName({
  required String storedName,
  required String targetName,
}) {
  final targetKey = eqPresetNameKey(targetName);
  if (targetKey.isEmpty) return false;
  return eqPresetNameKey(storedName) == targetKey;
}

List<double> normalizedEqGains(Object? value) {
  final result = <double>[];
  if (value is Iterable) {
    for (final item in value) {
      final gain = _normalizedEqNumber(item);
      result.add(
        gain == null || !gain.isFinite
            ? 0.0
            : gain.clamp(eqGainMinDb, eqGainMaxDb).toDouble(),
      );
      if (result.length == eqBandCount) break;
    }
  }
  while (result.length < eqBandCount) {
    result.add(0.0);
  }
  return result;
}

double normalizedEqPreampDb(Object? value) {
  final preamp = _normalizedEqNumber(value);
  if (preamp == null) return 0.0;
  if (!preamp.isFinite) return 0.0;
  return preamp.clamp(eqPreampMinDb, eqPreampMaxDb).toDouble();
}

double? _normalizedEqNumber(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}
