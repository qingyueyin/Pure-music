import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

enum HotkeyAction {
  playPause,
  previous,
  next,
  volumeUp,
  volumeDown,
  immersive,
  fullscreen,
  escape;

  String get title => switch (this) {
    playPause => '播放 / 暂停',
    previous => '上一首',
    next => '下一首',
    volumeUp => '音量加大',
    volumeDown => '音量减小',
    immersive => '沉浸模式',
    fullscreen => '全屏',
    escape => '关闭 / 返回',
  };
}

const inAppHotkeyActions = <HotkeyAction>[
  HotkeyAction.playPause,
  HotkeyAction.previous,
  HotkeyAction.next,
  HotkeyAction.volumeUp,
  HotkeyAction.volumeDown,
  HotkeyAction.immersive,
  HotkeyAction.fullscreen,
  HotkeyAction.escape,
];

const globalHotkeyActions = <HotkeyAction>[
  HotkeyAction.playPause,
  HotkeyAction.previous,
  HotkeyAction.next,
];

class HotkeyBinding {
  const HotkeyBinding._(this.keyHid, this.modifierHids);

  factory HotkeyBinding({int? keyHid, List<int> modifierHids = const []}) {
    if (keyHid == null) return unbound;
    final sorted = [...modifierHids]..sort();
    return HotkeyBinding._(keyHid, List<int>.unmodifiable(sorted));
  }

  static const unbound = HotkeyBinding._(null, <int>[]);

  final int? keyHid;
  final List<int> modifierHids;

  bool get isUnbound => keyHid == null;

  factory HotkeyBinding.decode(String? raw) {
    if (raw == null) return unbound;
    final text = raw.trim();
    if (text.isEmpty) return unbound;
    final values = <int>[];
    for (final part in text.split('_')) {
      final value = int.tryParse(part);
      if (value == null) return unbound;
      values.add(value);
    }
    if (values.isEmpty) return unbound;
    return HotkeyBinding(
      keyHid: values.last,
      modifierHids: values.sublist(0, values.length - 1),
    );
  }

  factory HotkeyBinding.fromHotKey(HotKey hotKey) {
    return HotkeyBinding(
      keyHid: hotKey.physicalKey.usbHidUsage,
      modifierHids: [
        for (final modifier in hotKey.modifiers ?? const <HotKeyModifier>[])
          modifier.physicalKeys.first.usbHidUsage,
      ],
    );
  }

  String encode() {
    if (keyHid == null) return '';
    if (modifierHids.isEmpty) return '$keyHid';
    return '${modifierHids.join('_')}_$keyHid';
  }

  String get signature {
    if (keyHid == null) return '';
    if (modifierHids.isEmpty) return '$keyHid';
    return '${modifierHids.join('_')}_$keyHid';
  }

  String get label {
    if (keyHid == null) return '未设置';
    final parts = [
      for (final hid in modifierHids) _modifierLabel(hid),
      _mainKeyLabel(keyHid!),
    ];
    return parts.join(' + ');
  }

  bool conflictsWith(HotkeyBinding other) {
    if (isUnbound || other.isUnbound) return false;
    return signature == other.signature;
  }

  HotKey? toHotKey({required HotKeyScope scope, required String identifier}) {
    if (keyHid == null) return null;
    final modifiers = <HotKeyModifier>[];
    for (final hid in modifierHids) {
      final modifier = _modifierFromHid(hid);
      if (modifier != null) modifiers.add(modifier);
    }
    return HotKey(
      identifier: identifier,
      key: PhysicalKeyboardKey(keyHid!),
      modifiers: modifiers.isEmpty ? null : modifiers,
      scope: scope,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is HotkeyBinding &&
        other.keyHid == keyHid &&
        _listEquals(other.modifierHids, modifierHids);
  }

  @override
  int get hashCode => Object.hash(keyHid, Object.hashAll(modifierHids));
}

enum HotkeyConflictKind { none, sameScope, globalVsInApp }

class HotkeyConflict {
  const HotkeyConflict({required this.kind, this.otherAction});

  const HotkeyConflict.none() : this(kind: HotkeyConflictKind.none);

  final HotkeyConflictKind kind;
  final HotkeyAction? otherAction;
}

HotkeyBinding defaultInAppBinding(HotkeyAction action) {
  final control = PhysicalKeyboardKey.controlLeft.usbHidUsage;
  switch (action) {
    case HotkeyAction.playPause:
      return HotkeyBinding(keyHid: PhysicalKeyboardKey.space.usbHidUsage);
    case HotkeyAction.previous:
      return HotkeyBinding(
        keyHid: PhysicalKeyboardKey.arrowLeft.usbHidUsage,
        modifierHids: [control],
      );
    case HotkeyAction.next:
      return HotkeyBinding(
        keyHid: PhysicalKeyboardKey.arrowRight.usbHidUsage,
        modifierHids: [control],
      );
    case HotkeyAction.volumeUp:
      return HotkeyBinding(
        keyHid: PhysicalKeyboardKey.arrowUp.usbHidUsage,
        modifierHids: [control],
      );
    case HotkeyAction.volumeDown:
      return HotkeyBinding(
        keyHid: PhysicalKeyboardKey.arrowDown.usbHidUsage,
        modifierHids: [control],
      );
    case HotkeyAction.immersive:
      return HotkeyBinding(keyHid: PhysicalKeyboardKey.f1.usbHidUsage);
    case HotkeyAction.fullscreen:
      return HotkeyBinding(keyHid: PhysicalKeyboardKey.f11.usbHidUsage);
    case HotkeyAction.escape:
      return HotkeyBinding(keyHid: PhysicalKeyboardKey.escape.usbHidUsage);
  }
}

Map<HotkeyAction, HotkeyBinding> defaultInAppHotkeys() => {
  for (final action in inAppHotkeyActions) action: defaultInAppBinding(action),
};

Map<HotkeyAction, HotkeyBinding> defaultGlobalHotkeys() => {
  for (final action in globalHotkeyActions) action: HotkeyBinding.unbound,
};

HotkeyConflict findHotkeyConflict({
  required HotkeyBinding candidate,
  required HotkeyAction action,
  required bool isGlobal,
  required Map<HotkeyAction, HotkeyBinding> inApp,
  required Map<HotkeyAction, HotkeyBinding> global,
  required bool globalEnabled,
}) {
  if (candidate.isUnbound) return const HotkeyConflict.none();

  final sameScope = isGlobal ? global : inApp;
  for (final entry in sameScope.entries) {
    if (entry.key == action) continue;
    if (candidate.conflictsWith(entry.value)) {
      return HotkeyConflict(
        kind: HotkeyConflictKind.sameScope,
        otherAction: entry.key,
      );
    }
  }

  if (globalEnabled) {
    final otherScope = isGlobal ? inApp : global;
    for (final entry in otherScope.entries) {
      if (candidate.conflictsWith(entry.value)) {
        return HotkeyConflict(
          kind: HotkeyConflictKind.globalVsInApp,
          otherAction: entry.key,
        );
      }
    }
  }

  return const HotkeyConflict.none();
}

Map<HotkeyAction, HotkeyBinding> decodeInAppHotkeys(Object? raw) {
  final result = defaultInAppHotkeys();
  if (raw is! Map) return result;
  for (final action in inAppHotkeyActions) {
    final value = raw[action.name];
    if (value == null) continue;
    final decoded = HotkeyBinding.decode(value.toString());
    if (!decoded.isUnbound) result[action] = decoded;
  }
  return result;
}

Map<HotkeyAction, HotkeyBinding> decodeGlobalHotkeys(Object? raw) {
  final result = defaultGlobalHotkeys();
  if (raw is! Map) return result;
  for (final action in globalHotkeyActions) {
    if (!raw.containsKey(action.name)) continue;
    result[action] = HotkeyBinding.decode(raw[action.name]?.toString());
  }
  return result;
}

Map<String, Object> encodeHotkeySettings({
  required bool globalEnabled,
  required Map<HotkeyAction, HotkeyBinding> inApp,
  required Map<HotkeyAction, HotkeyBinding> global,
}) {
  return {
    'GlobalHotkeysEnabled': globalEnabled,
    'InAppHotkeys': {
      for (final entry in inApp.entries) entry.key.name: entry.value.encode(),
    },
    'GlobalHotkeys': {
      for (final entry in global.entries) entry.key.name: entry.value.encode(),
    },
  };
}

String _modifierLabel(int hid) {
  final modifier = _modifierFromHid(hid);
  return switch (modifier) {
    HotKeyModifier.control => 'Ctrl',
    HotKeyModifier.alt => 'Alt',
    HotKeyModifier.shift => 'Shift',
    HotKeyModifier.meta => 'Win',
    HotKeyModifier.fn => 'Fn',
    HotKeyModifier.capsLock => 'Caps',
    null => 'Mod',
  };
}

String _mainKeyLabel(int hid) {
  final key = PhysicalKeyboardKey(hid);
  if (key == PhysicalKeyboardKey.space) return 'Space';
  if (key == PhysicalKeyboardKey.escape) return 'Esc';
  if (key == PhysicalKeyboardKey.arrowLeft) return '←';
  if (key == PhysicalKeyboardKey.arrowRight) return '→';
  if (key == PhysicalKeyboardKey.arrowUp) return '↑';
  if (key == PhysicalKeyboardKey.arrowDown) return '↓';
  final debugName = key.debugName;
  if (debugName != null &&
      debugName.startsWith('Key ') &&
      debugName.length == 5) {
    return debugName.substring(4);
  }
  if (debugName != null && debugName.isNotEmpty) return debugName;
  final label = key.keyLabel.trim();
  if (label.isNotEmpty) return label;
  return 'Key';
}

HotKeyModifier? _modifierFromHid(int hid) {
  for (final modifier in HotKeyModifier.values) {
    if (modifier.physicalKeys.any((key) => key.usbHidUsage == hid)) {
      return modifier;
    }
  }
  return null;
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
