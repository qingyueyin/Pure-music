import 'package:flutter/material.dart';
import 'package:pure_music/component/settings_tile.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/play_service.dart';

/// 输出设备选择。共享和 WASAPI 独占模式分别保存设备 key。
class AudioOutputSettingsPanel extends StatefulWidget {
  const AudioOutputSettingsPanel({super.key});

  @override
  State<AudioOutputSettingsPanel> createState() =>
      _AudioOutputSettingsPanelState();
}

class _AudioOutputSettingsPanelState extends State<AudioOutputSettingsPanel> {
  late final PlaybackService _service;
  late final ValueNotifier<bool> _exclusiveMode;
  var _exclusive = false;
  String _selected = '';
  List<AudioOutputDevice> _devices = const [];

  @override
  void initState() {
    super.initState();
    _service = PlayService.instance.playbackService;
    _exclusiveMode = _service.wasapiExclusive;
    _exclusive = _exclusiveMode.value;
    _selected = _currentKey;
    _exclusiveMode.addListener(_onModeChanged);
    _reload();
  }

  @override
  void dispose() {
    _exclusiveMode.removeListener(_onModeChanged);
    super.dispose();
  }

  String get _currentKey => _exclusive
      ? AppPreference.instance.playbackPref.wasapiOutputDevice
      : AppPreference.instance.playbackPref.sharedOutputDevice;

  void _onModeChanged() {
    if (!mounted) return;
    setState(() {
      _exclusive = _exclusiveMode.value;
      _selected = _currentKey;
      _reload();
    });
  }

  void _reload() {
    try {
      _devices = _service.listOutputDevices(exclusive: _exclusive);
    } catch (error, trace) {
      log.settings.warn('legacy', '枚举输出设备失败', error: error, stackTrace: trace);
      _devices = const [];
    }
  }

  String get _subtitle {
    if (_selected.isEmpty) return '系统默认设备';
    final found = _devices.where((device) => device.key == _selected).firstOrNull;
    return found == null ? '设备不可用，将使用系统默认' : found.name;
  }

  Future<void> _pick() async {
    _reload();
    final pick = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择输出设备'),
        children: [
          _DeviceOption(
            label: '系统默认设备',
            selected: _selected.isEmpty,
            onTap: () => Navigator.pop(context, ''),
          ),
          for (final device in _devices)
            _DeviceOption(
              label: device.name.isEmpty ? '未命名设备' : device.name,
              note: device.isDefault ? '系统默认' : null,
              selected: _selected == device.key,
              onTap: () => Navigator.pop(context, device.key),
            ),
          if (_devices.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Text(
                '没有读到可用设备。请确认音频驱动正常；独占模式下列表会改用 WASAPI 设备。',
                style: TextStyle(fontSize: AppType.caption),
              ),
            ),
        ],
      ),
    );
    if (pick == null || !mounted) return;
    final result = await _service.setOutputDevice(pick);
    if (!mounted) return;
    setState(() => _selected = result.activeKey);
    if (result.succeeded) await AppPreference.instance.save();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      description: '输出设备',
      subtitle: _subtitle,
      action: TextButton(onPressed: _pick, child: const Text('选择')),
    );
  }
}

class _DeviceOption extends StatelessWidget {
  const _DeviceOption({
    required this.label,
    required this.selected,
    required this.onTap,
    this.note,
  });

  final String label;
  final String? note;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      subtitle: note == null
          ? null
          : Text(note!, style: const TextStyle(fontSize: AppType.caption)),
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: onTap,
    );
  }
}
