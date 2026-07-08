bool canSaveChangedSetting<T>({
  required T current,
  required T next,
  required bool isSaving,
}) =>
    !isSaving && current != next;

bool canSaveChangedDoubleSetting({
  required double current,
  required double next,
  required bool isSaving,
  double tolerance = 0.000001,
}) =>
    !isSaving && (current - next).abs() > tolerance;

bool canClearTextValue({
  required String text,
  required bool isBusy,
}) =>
    !isBusy && text.trim().isNotEmpty;

bool canEditTextValue({required bool isBusy}) => !isBusy;

bool canChangeSetting({required bool isSaving}) => !isSaving;

bool canResetOptionalSetting<T>({
  required T? current,
  required bool isSaving,
}) =>
    !isSaving && current != null;

bool canSaveListSettingChanges({
  required bool isEditing,
  required bool isSaving,
  required bool hasChanges,
}) =>
    !isEditing && !isSaving && hasChanges;

bool canTogglePendingListItem({required bool isSaving}) => !isSaving;

String normalizedTextListItem(String value) => value.trim();

List<String> uniqueTextListItems(Iterable<String> values) {
  final result = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final item = normalizedTextListItem(value);
    if (item.isEmpty || !seen.add(item)) continue;
    result.add(item);
  }
  return result;
}

bool canAddUniqueTextListItem({
  required Iterable<String> existingItems,
  required String input,
  required bool isSaving,
}) {
  if (isSaving) return false;
  final item = normalizedTextListItem(input);
  if (item.isEmpty) return false;
  return !existingItems
      .any((existing) => normalizedTextListItem(existing) == item);
}

const defaultArtistSeparators = ['/', '、'];

List<String> normalizedArtistSeparators(Object? value) {
  if (value is String) {
    final separator = normalizedTextListItem(value);
    return separator.length == 1
        ? [separator]
        : List.of(defaultArtistSeparators);
  }
  if (value is! Iterable) return List.of(defaultArtistSeparators);
  final separators = uniqueTextListItems(value.whereType<String>());
  return separators.isEmpty ? List.of(defaultArtistSeparators) : separators;
}

int normalizedEnumIndex(
  Object? value, {
  required int length,
  int defaultIndex = 0,
}) {
  final index = _normalizedIntSettingNumber(value);
  if (index == null || index < 0 || index >= length) return defaultIndex;
  return index;
}

bool normalizedBoolSetting(Object? value, {required bool defaultValue}) {
  if (value is bool) return value;
  if (value is num) {
    if (value == 1) return true;
    if (value == 0) return false;
  }
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1' || normalized == 'yes' ||
        normalized == 'on') {
      return true;
    }
    if (normalized == 'false' || normalized == '0' || normalized == 'no' ||
        normalized == 'off') {
      return false;
    }
    final number = double.tryParse(normalized);
    if (number == 1.0) return true;
    if (number == 0.0) return false;
  }
  return defaultValue;
}

int normalizedBoundedIntSetting(
  Object? value, {
  required int defaultValue,
  required int min,
  required int max,
}) {
  final number = _normalizedIntSettingNumber(value);
  if (number == null) return defaultValue;
  return number.clamp(min, max);
}

int? _normalizedIntSettingNumber(Object? value) {
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

const defaultWindowSizeSetting = (width: 1280.0, height: 756.0);

({double width, double height}) normalizedWindowSizeSetting(Object? value) {
  final parts = switch (value) {
    String() => _normalizedWindowSizeString(value).split(','),
    Iterable() => value.toList(growable: false),
    Map() when value.containsKey('width') && value.containsKey('height') => [
        value['width'],
        value['height'],
      ],
    _ => null,
  };
  if (parts == null || parts.length != 2) return defaultWindowSizeSetting;
  final width = _normalizedWindowSizeNumber(parts[0]);
  final height = _normalizedWindowSizeNumber(parts[1]);
  if (width == null || height == null) return defaultWindowSizeSetting;
  if (width <= 0 || height <= 0) return defaultWindowSizeSetting;
  return (width: width, height: height);
}

String _normalizedWindowSizeString(String value) {
  final normalized = value.trim();
  if (normalized.startsWith('Size(') && normalized.endsWith(')')) {
    return normalized.substring(5, normalized.length - 1);
  }
  final sizePair = RegExp(
    r'^([+-]?(?:\d+\.?\d*|\.\d+))\s*[xX]\s*([+-]?(?:\d+\.?\d*|\.\d+))$',
  ).firstMatch(normalized);
  if (sizePair != null) {
    return '${sizePair.group(1)},${sizePair.group(2)}';
  }
  return normalized;
}

double? _normalizedWindowSizeNumber(Object? value) {
  final number = switch (value) {
    num() => value.toDouble(),
    String() => double.tryParse(value.trim()),
    _ => null,
  };
  if (number == null || !number.isFinite) return null;
  return number;
}

String? normalizedStringSetting(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

const maxColorSetting = 0xFFFFFFFF;

int? normalizedOptionalColorSetting(Object? value) {
  final color = switch (value) {
    int() => value,
    num() when value.isFinite && value == value.truncateToDouble() =>
      value.toInt(),
    String() => _parseColorSettingString(value),
    _ => null,
  };
  if (color == null || color < 0 || color > maxColorSetting) return null;
  return color;
}

int? _parseColorSettingString(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return null;
  final colorMatch = RegExp(
    r'^Color\(\s*(0x[0-9a-fA-F]{6,8})\s*\)$',
    caseSensitive: false,
  ).firstMatch(normalized);
  if (colorMatch != null) {
    return _parseColorSettingString(colorMatch.group(1)!);
  }

  String? hex;
  if (normalized.startsWith('#')) {
    hex = normalized.substring(1);
  } else if (normalized.toLowerCase().startsWith('0x')) {
    hex = normalized.substring(2);
  } else if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(normalized) ||
      RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(normalized)) {
    hex = normalized;
  }

  if (hex != null) {
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length != 8) return null;
    return int.tryParse(hex, radix: 16);
  }

  final integer = int.tryParse(normalized);
  if (integer != null) return integer;
  final number = double.tryParse(normalized);
  if (number == null || !number.isFinite) return null;
  if (number != number.truncateToDouble()) return null;
  return number.toInt();
}
