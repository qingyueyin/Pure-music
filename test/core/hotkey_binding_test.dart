import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:pure_music/core/hotkey_binding.dart';
import 'package:pure_music/core/settings.dart';

void main() {
  group('HotkeyBinding', () {
    test('encodes sorted modifiers then the main key', () {
      final binding = HotkeyBinding(
        keyHid: PhysicalKeyboardKey.space.usbHidUsage,
        modifierHids: [
          PhysicalKeyboardKey.altLeft.usbHidUsage,
          PhysicalKeyboardKey.controlLeft.usbHidUsage,
        ],
      );

      expect(
        binding.encode(),
        '${PhysicalKeyboardKey.controlLeft.usbHidUsage}_'
        '${PhysicalKeyboardKey.altLeft.usbHidUsage}_'
        '${PhysicalKeyboardKey.space.usbHidUsage}',
      );
      expect(binding.label, 'Ctrl + Alt + Space');
      expect(HotkeyBinding.decode(binding.encode()), binding);
    });

    test('treats empty and invalid payloads as unbound', () {
      expect(HotkeyBinding.decode('').isUnbound, isTrue);
      expect(HotkeyBinding.decode(null).isUnbound, isTrue);
      expect(HotkeyBinding.decode('nope').isUnbound, isTrue);
      expect(HotkeyBinding.unbound.encode(), '');
      expect(HotkeyBinding.unbound.label, '未设置');
    });

    test('signature ignores modifier order', () {
      final left = HotkeyBinding(
        keyHid: PhysicalKeyboardKey.keyA.usbHidUsage,
        modifierHids: [
          PhysicalKeyboardKey.altLeft.usbHidUsage,
          PhysicalKeyboardKey.controlLeft.usbHidUsage,
        ],
      );
      final right = HotkeyBinding(
        keyHid: PhysicalKeyboardKey.keyA.usbHidUsage,
        modifierHids: [
          PhysicalKeyboardKey.controlLeft.usbHidUsage,
          PhysicalKeyboardKey.altLeft.usbHidUsage,
        ],
      );

      expect(left.signature, right.signature);
      expect(left.conflictsWith(right), isTrue);
    });

    test('unbound bindings never conflict', () {
      expect(
        HotkeyBinding.unbound.conflictsWith(HotkeyBinding.unbound),
        isFalse,
      );
      expect(
        HotkeyBinding.unbound.conflictsWith(
          HotkeyBinding(keyHid: PhysicalKeyboardKey.space.usbHidUsage),
        ),
        isFalse,
      );
    });

    test('roundtrips through HotKey', () {
      final original = defaultInAppBinding(HotkeyAction.previous);
      final hotKey = original.toHotKey(
        scope: HotKeyScope.inapp,
        identifier: 'inapp.previous',
      );

      expect(hotKey, isNotNull);
      expect(hotKey!.scope, HotKeyScope.inapp);
      expect(HotkeyBinding.fromHotKey(hotKey), original);
    });
  });

  group('default in-app bindings', () {
    test('match the current fixed shortcuts', () {
      expect(defaultInAppBinding(HotkeyAction.playPause).label, 'Space');
      expect(defaultInAppBinding(HotkeyAction.previous).label, 'Ctrl + ←');
      expect(defaultInAppBinding(HotkeyAction.next).label, 'Ctrl + →');
      expect(defaultInAppBinding(HotkeyAction.volumeUp).label, 'Ctrl + ↑');
      expect(defaultInAppBinding(HotkeyAction.volumeDown).label, 'Ctrl + ↓');
      expect(defaultInAppBinding(HotkeyAction.immersive).label, 'F1');
      expect(defaultInAppBinding(HotkeyAction.fullscreen).label, 'F11');
      expect(defaultInAppBinding(HotkeyAction.escape).label, 'Esc');
    });
  });

  group('findHotkeyConflict', () {
    late Map<HotkeyAction, HotkeyBinding> inApp;
    late Map<HotkeyAction, HotkeyBinding> global;

    setUp(() {
      inApp = {
        for (final action in inAppHotkeyActions)
          action: defaultInAppBinding(action),
      };
      global = {
        for (final action in globalHotkeyActions) action: HotkeyBinding.unbound,
      };
    });

    test('detects a duplicate in the same scope', () {
      final conflict = findHotkeyConflict(
        candidate: defaultInAppBinding(HotkeyAction.playPause),
        action: HotkeyAction.next,
        isGlobal: false,
        inApp: inApp,
        global: global,
        globalEnabled: false,
      );

      expect(conflict.kind, HotkeyConflictKind.sameScope);
      expect(conflict.otherAction, HotkeyAction.playPause);
    });

    test('ignores the same action in the same scope', () {
      final conflict = findHotkeyConflict(
        candidate: defaultInAppBinding(HotkeyAction.playPause),
        action: HotkeyAction.playPause,
        isGlobal: false,
        inApp: inApp,
        global: global,
        globalEnabled: false,
      );

      expect(conflict.kind, HotkeyConflictKind.none);
    });

    test('allows the same combo across scopes while global is off', () {
      final space = defaultInAppBinding(HotkeyAction.playPause);
      final conflict = findHotkeyConflict(
        candidate: space,
        action: HotkeyAction.playPause,
        isGlobal: true,
        inApp: inApp,
        global: global,
        globalEnabled: false,
      );

      expect(conflict.kind, HotkeyConflictKind.none);
    });

    test('blocks the same combo across scopes when global is on', () {
      final space = defaultInAppBinding(HotkeyAction.playPause);
      final conflict = findHotkeyConflict(
        candidate: space,
        action: HotkeyAction.playPause,
        isGlobal: true,
        inApp: inApp,
        global: global,
        globalEnabled: true,
      );

      expect(conflict.kind, HotkeyConflictKind.globalVsInApp);
      expect(conflict.otherAction, HotkeyAction.playPause);
    });
  });

  group('hotkey settings persistence', () {
    tearDown(() async {
      await AppSettings.readFromSettingsMapForTest({
        'Version': 'test',
        'EnableStackedScrollEffect': true,
      });
    });

    test('missing keys keep the current in-app defaults', () async {
      await AppSettings.readFromSettingsMapForTest({'Version': 'test'});

      expect(AppSettings.instance.globalHotkeysEnabled, isFalse);
      expect(
        AppSettings.instance.inAppHotkeys[HotkeyAction.playPause]?.label,
        'Space',
      );
      expect(
        AppSettings.instance.globalHotkeys[HotkeyAction.playPause]?.isUnbound,
        isTrue,
      );
    });

    test('loads custom in-app and global bindings', () async {
      final custom = HotkeyBinding(
        keyHid: PhysicalKeyboardKey.keyP.usbHidUsage,
        modifierHids: [PhysicalKeyboardKey.controlLeft.usbHidUsage],
      );
      await AppSettings.readFromSettingsMapForTest({
        'Version': 'test',
        'GlobalHotkeysEnabled': true,
        'InAppHotkeys': {'playPause': custom.encode()},
        'GlobalHotkeys': {
          'next': HotkeyBinding(
            keyHid: PhysicalKeyboardKey.arrowRight.usbHidUsage,
            modifierHids: [
              PhysicalKeyboardKey.controlLeft.usbHidUsage,
              PhysicalKeyboardKey.altLeft.usbHidUsage,
            ],
          ).encode(),
        },
      });

      expect(AppSettings.instance.globalHotkeysEnabled, isTrue);
      expect(AppSettings.instance.inAppHotkeys[HotkeyAction.playPause], custom);
      expect(
        AppSettings.instance.globalHotkeys[HotkeyAction.next]?.label,
        'Ctrl + Alt + →',
      );
      expect(
        AppSettings.instance.inAppHotkeys[HotkeyAction.previous]?.label,
        'Ctrl + ←',
      );
    });

    test('empty in-app payload falls back to the default', () async {
      await AppSettings.readFromSettingsMapForTest({
        'Version': 'test',
        'InAppHotkeys': {'playPause': ''},
      });

      expect(
        AppSettings.instance.inAppHotkeys[HotkeyAction.playPause]?.label,
        'Space',
      );
    });

    test('encodes the current bindings for settings.json', () {
      final encoded = encodeHotkeySettings(
        globalEnabled: true,
        inApp: {
          HotkeyAction.playPause: defaultInAppBinding(HotkeyAction.playPause),
        },
        global: {
          HotkeyAction.next: HotkeyBinding(
            keyHid: PhysicalKeyboardKey.arrowRight.usbHidUsage,
            modifierHids: [PhysicalKeyboardKey.altLeft.usbHidUsage],
          ),
        },
      );

      expect(encoded['GlobalHotkeysEnabled'], isTrue);
      expect(
        (encoded['InAppHotkeys'] as Map)['playPause'],
        defaultInAppBinding(HotkeyAction.playPause).encode(),
      );
      expect((encoded['GlobalHotkeys'] as Map)['next'], isNot(isEmpty));
    });
  });
}
