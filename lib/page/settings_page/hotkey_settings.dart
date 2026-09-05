import 'package:flutter/material.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/hotkey_binding.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';

class HotkeySettingsPanel extends StatefulWidget {
  const HotkeySettingsPanel({super.key});

  @override
  State<HotkeySettingsPanel> createState() => _HotkeySettingsPanelState();
}

class _HotkeySettingsPanelState extends State<HotkeySettingsPanel> {
  final settings = AppSettings.instance;

  Future<bool> _save() async {
    final saved = await settings.saveSettings();
    if (!saved && mounted) {
      showTextOnSnackBar('快捷键设置保存失败', variant: ToastVariant.error);
    }
    return saved;
  }

  Future<void> _reloadHotkeys() async {
    await HotkeysHelper.reload();
    if (mounted) setState(() {});
  }

  Future<void> _applyBinding({
    required HotkeyAction action,
    required bool isGlobal,
    required HotkeyBinding binding,
  }) async {
    if (isGlobal && !binding.isUnbound && binding.modifierHids.isEmpty) {
      showTextOnSnackBar('全局热键需要带 Ctrl / Alt / Shift，避免抢游戏按键');
      return;
    }
    final conflict = findHotkeyConflict(
      candidate: binding,
      action: action,
      isGlobal: isGlobal,
      inApp: settings.inAppHotkeys,
      global: settings.globalHotkeys,
      globalEnabled: settings.globalHotkeysEnabled || isGlobal,
    );
    if (conflict.kind != HotkeyConflictKind.none) {
      showTextOnSnackBar(
        _conflictMessage(conflict),
        variant: ToastVariant.error,
      );
      return;
    }

    if (isGlobal) {
      final previous = Map<HotkeyAction, HotkeyBinding>.from(
        settings.globalHotkeys,
      );
      setState(() {
        settings.globalHotkeys = {...settings.globalHotkeys, action: binding};
      });
      if (!await _save()) {
        setState(() => settings.globalHotkeys = previous);
        return;
      }
    } else {
      if (binding.isUnbound) return;
      final previous = Map<HotkeyAction, HotkeyBinding>.from(
        settings.inAppHotkeys,
      );
      setState(() {
        settings.inAppHotkeys = {...settings.inAppHotkeys, action: binding};
      });
      if (!await _save()) {
        setState(() => settings.inAppHotkeys = previous);
        return;
      }
    }
    await _reloadHotkeys();
  }

  Future<void> _recordBinding({
    required HotkeyAction action,
    required bool isGlobal,
  }) async {
    await HotkeysHelper.pauseForRecording();
    if (!mounted) {
      await HotkeysHelper.resumeAfterRecording();
      return;
    }
    final current = isGlobal
        ? (settings.globalHotkeys[action] ?? HotkeyBinding.unbound)
        : (settings.inAppHotkeys[action] ?? defaultInAppBinding(action));
    final recorded = await showDialog<HotkeyBinding>(
      context: context,
      builder: (context) => _HotkeyRecorderDialog(
        title: action.title,
        initial: current,
        allowClear: isGlobal,
      ),
    );
    await HotkeysHelper.resumeAfterRecording();
    if (recorded == null) return;
    await _applyBinding(action: action, isGlobal: isGlobal, binding: recorded);
  }

  Future<void> _resetInApp() async {
    final previous = Map<HotkeyAction, HotkeyBinding>.from(
      settings.inAppHotkeys,
    );
    setState(() => settings.inAppHotkeys = defaultInAppHotkeys());
    if (!await _save()) {
      setState(() => settings.inAppHotkeys = previous);
      return;
    }
    await _reloadHotkeys();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final action in inAppHotkeyActions) ...[
          SettingsTile(
            description: action.title,
            subtitle:
                (settings.inAppHotkeys[action] ?? defaultInAppBinding(action))
                    .label,
            action: OutlinedButton(
              onPressed: () => _recordBinding(action: action, isGlobal: false),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: AppRadius.smCircular,
                ),
              ),
              child: const Text('更改'),
            ),
          ),
          const SizedBox(height: 16.0),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: _resetInApp, child: const Text('恢复默认')),
        ),
      ],
    );
  }
}

class GlobalHotkeySettingsPanel extends StatefulWidget {
  const GlobalHotkeySettingsPanel({super.key});

  @override
  State<GlobalHotkeySettingsPanel> createState() =>
      _GlobalHotkeySettingsPanelState();
}

class _GlobalHotkeySettingsPanelState
    extends State<GlobalHotkeySettingsPanel> {
  final settings = AppSettings.instance;

  Future<bool> _save() async {
    final saved = await settings.saveSettings();
    if (!saved && mounted) {
      showTextOnSnackBar('快捷键设置保存失败', variant: ToastVariant.error);
    }
    return saved;
  }

  Future<void> _reloadHotkeys() async {
    await HotkeysHelper.reload();
    if (mounted) setState(() {});
  }

  Future<void> _setGlobalEnabled(bool value) async {
    if (value) {
      for (final action in globalHotkeyActions) {
        final binding =
            settings.globalHotkeys[action] ?? HotkeyBinding.unbound;
        final conflict = findHotkeyConflict(
          candidate: binding,
          action: action,
          isGlobal: true,
          inApp: settings.inAppHotkeys,
          global: settings.globalHotkeys,
          globalEnabled: true,
        );
        if (conflict.kind != HotkeyConflictKind.none) {
          showTextOnSnackBar(
            _conflictMessage(conflict),
            variant: ToastVariant.error,
          );
          return;
        }
      }
    }
    final previous = settings.globalHotkeysEnabled;
    setState(() => settings.globalHotkeysEnabled = value);
    if (!await _save()) {
      setState(() => settings.globalHotkeysEnabled = previous);
      return;
    }
    await _reloadHotkeys();
  }

  Future<void> _recordBinding(HotkeyAction action) async {
    await HotkeysHelper.pauseForRecording();
    if (!mounted) {
      await HotkeysHelper.resumeAfterRecording();
      return;
    }
    final current = settings.globalHotkeys[action] ?? HotkeyBinding.unbound;
    final recorded = await showDialog<HotkeyBinding>(
      context: context,
      builder: (_) => _HotkeyRecorderDialog(
        title: action.title,
        initial: current,
        allowClear: true,
      ),
    );
    await HotkeysHelper.resumeAfterRecording();
    if (recorded == null) return;

    if (!recorded.isUnbound && recorded.modifierHids.isEmpty) {
      showTextOnSnackBar('全局热键需要带 Ctrl / Alt / Shift，避免抢游戏按键');
      return;
    }
    final conflict = findHotkeyConflict(
      candidate: recorded,
      action: action,
      isGlobal: true,
      inApp: settings.inAppHotkeys,
      global: settings.globalHotkeys,
      globalEnabled: settings.globalHotkeysEnabled,
    );
    if (conflict.kind != HotkeyConflictKind.none) {
      showTextOnSnackBar(
        _conflictMessage(conflict),
        variant: ToastVariant.error,
      );
      return;
    }

    final previous = Map<HotkeyAction, HotkeyBinding>.from(
      settings.globalHotkeys,
    );
    setState(() => settings.globalHotkeys = {...settings.globalHotkeys, action: recorded});
    if (!await _save()) {
      setState(() => settings.globalHotkeys = previous);
      return;
    }
    await _reloadHotkeys();
  }

  Future<void> _clearGlobal() async {
    final previous = Map<HotkeyAction, HotkeyBinding>.from(
      settings.globalHotkeys,
    );
    setState(() => settings.globalHotkeys = defaultGlobalHotkeys());
    if (!await _save()) {
      setState(() => settings.globalHotkeys = previous);
      return;
    }
    await _reloadHotkeys();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsTile(
          description: '启用全局热键',
          subtitle: settings.globalHotkeysEnabled
              ? '最小化或切换到其他窗口时仍可使用。以管理员权限运行的游戏可能拦截热键'
              : '关闭后仅使用应用内快捷键',
          action: Switch(
            value: settings.globalHotkeysEnabled,
            onChanged: _setGlobalEnabled,
          ),
        ),
        const SizedBox(height: 16.0),
        for (final action in globalHotkeyActions) ...[
          SettingsTile(
            description: action.title,
            subtitle:
                (settings.globalHotkeys[action] ?? HotkeyBinding.unbound)
                    .label,
            action: OutlinedButton(
              onPressed: settings.globalHotkeysEnabled
                  ? () => _recordBinding(action)
                  : null,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: AppRadius.smCircular,
                ),
              ),
              child: const Text('更改'),
            ),
          ),
          const SizedBox(height: 16.0),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: _clearGlobal, child: const Text('清空')),
        ),
      ],
    );
  }
}

class _HotkeyRecorderDialog extends StatefulWidget {
  const _HotkeyRecorderDialog({
    required this.title,
    required this.initial,
    required this.allowClear,
  });

  final String title;
  final HotkeyBinding initial;
  final bool allowClear;

  @override
  State<_HotkeyRecorderDialog> createState() => _HotkeyRecorderDialogState();
}

class _HotkeyRecorderDialogState extends State<_HotkeyRecorderDialog> {
  late HotkeyBinding _binding = widget.initial;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('设置「${widget.title}」'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _binding.label,
            style: const TextStyle(fontSize: AppType.subtitle),
          ),
          const SizedBox(height: 16),
          HotKeyRecorder(
            initalHotKey: widget.initial.toHotKey(
              scope: HotKeyScope.inapp,
              identifier: 'record',
            ),
            onHotKeyRecorded: (hotKey) {
              setState(() => _binding = HotkeyBinding.fromHotKey(hotKey));
            },
          ),
        ],
      ),
      actions: [
        if (widget.allowClear)
          TextButton(
            onPressed: () => Navigator.of(context).pop(HotkeyBinding.unbound),
            child: const Text('清除'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _binding.isUnbound && !widget.allowClear
              ? null
              : () => Navigator.of(context).pop(_binding),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

String _conflictMessage(HotkeyConflict conflict) {
  final other = conflict.otherAction?.title ?? '其它快捷键';
  return switch (conflict.kind) {
    HotkeyConflictKind.sameScope => '已用于「$other」，请更换',
    HotkeyConflictKind.globalVsInApp => '与应用内「$other」相同，请更换',
    HotkeyConflictKind.none => '',
  };
}
