import 'package:pure_music/component/danger_confirm_dialog.dart';
import 'package:pure_music/core/equalizer_action_state.dart';
import 'package:pure_music/core/equalizer_preset_parser.dart';
import 'package:pure_music/core/audio_dsp_settings.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

const _maxEqImportFileBytes = 8 * 1024 * 1024;
const _maxEqImportTotalBytes = 64 * 1024 * 1024;
const _maxEqImportFileCount = 2048;

class _EqValuePill extends StatelessWidget {
  const _EqValuePill({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: AppRadius.mdCircular,
      ),
      child: Text(
        '${value.toStringAsFixed(1)} dB',
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontSize: AppType.caption,
          fontWeight: AppType.weightSemibold,
        ),
      ),
    );
  }
}

class EqualizerDialog extends StatefulWidget {
  const EqualizerDialog({super.key});

  @override
  State<EqualizerDialog> createState() => _EqualizerDialogState();
}

class _EqualizerDialogState extends State<EqualizerDialog> {
  late List<double> _gains;
  late double _preampDb;
  late AudioDspSettings _effects;
  bool _isImportingWaveletEq = false;
  bool _isImportingFolder = false;
  int _tabIndex = 0;
  static const _eqCenters = eqBandLabels;

  @override
  void initState() {
    super.initState();
    final playbackService = PlayService.instance.playbackService;
    _gains = List.from(playbackService.eqGains);
    _preampDb = playbackService.eqPreampDb;
    _effects = playbackService.audioEffects;
  }

  void _updateEffects(AudioDspSettings effects, {bool save = false}) {
    _effects = effects.normalized();
    final playbackService = PlayService.instance.playbackService;
    playbackService.setAudioEffects(_effects);
    if (save) playbackService.savePreference();
    setState(() {});
  }

  Widget _effectSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 48, child: Text(label)),
          Expanded(
            child: Slider(
              value: value.clamp(min, max).toDouble(),
              min: min,
              max: max,
              onChanged: enabled ? onChanged : null,
              onChangeEnd: enabled
                  ? (_) => PlayService.instance.playbackService.savePreference()
                  : null,
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              format(value),
              textAlign: TextAlign.end,
              style: const TextStyle(fontSize: AppType.microlabel),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _importWaveletEq() async {
    if (_isImportingWaveletEq || _isImportingFolder) return;
    setState(() => _isImportingWaveletEq = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt'],
        dialogTitle: 'Select Wavelet GraphicEQ.txt',
      );

      if (result != null && result.files.isNotEmpty) {
        try {
          final pickedFile = result.files.first;
          final pickedPath = pickedFile.path;
          if (pickedPath == null || pickedPath.trim().isEmpty) return;
          final file = File(pickedPath);
          final bytes = await _readEqFileBytes(
            file,
            remainingBytes: _maxEqImportFileBytes,
          );
          if (bytes == null) {
            if (mounted) showTextOnSnackBar('EQ 文件过大，未导入');
            return;
          }
          final content = _decodeEqText(bytes);
          final fileName = _waveletPresetName(pickedFile.name);
          if (mounted) {
            final saved = await _applyWaveletEqFromContent(
              content,
              presetName: fileName,
            );
            if (!saved) showTextOnSnackBar('保存均衡器预设失败');
          }
        } catch (e, trace) {
          logger.e('导入均衡器预设失败', error: e, stackTrace: trace);
          if (mounted) {
            showTextOnSnackBar('导入均衡器预设失败，请查看日志');
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isImportingWaveletEq = false);
      }
    }
  }

  String _waveletPresetName(String fileName) {
    final name = fileName
        .replaceFirst(RegExp(r'\.txt$', caseSensitive: false), '')
        .trim();
    return name.isEmpty ? '导入预设' : name;
  }

  Future<List<int>?> _readEqFileBytes(
    File file, {
    required int remainingBytes,
  }) async {
    if (remainingBytes <= 0) return null;
    final stat = await file.stat();
    if (stat.size > _maxEqImportFileBytes || stat.size > remainingBytes) {
      return null;
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > _maxEqImportFileBytes || bytes.length > remainingBytes) {
      return null;
    }
    return bytes;
  }

  Future<bool> _applyWaveletEqFromContent(
    String content, {
    required String presetName,
    bool updateState = true,
  }) async {
    final playbackService = PlayService.instance.playbackService;

    final parsed = parseWaveletEqContent(content);
    final newGains = parsed.gains;
    final preampDb = parsed.preampDb;

    final appliedPreamp = (preampDb ?? playbackService.eqPreampDb)
        .clamp(eqPreampMinDb, eqPreampMaxDb)
        .toDouble();
    final saved = await playbackService.importEqPresetsAndApplyLast([
      EqPreset(
        presetName,
        newGains,
        eqEnabled: playbackService.eqEnabled,
        preampDb: appliedPreamp,
        eqAutoGainEnabled: playbackService.eqAutoGainEnabled,
        eqAutoHeadroomDb: playbackService.eqAutoHeadroomDb,
        audioDspSettings: playbackService.audioEffects,
      ),
    ]);
    if (!saved) return false;

    if (!updateState || !mounted) return true;
    setState(() {
      _gains = List.from(newGains);
      _preampDb = appliedPreamp;
    });
    return true;
  }

  Future<void> _importEqFolder() async {
    if (_isImportingFolder || _isImportingWaveletEq) return;
    setState(() => _isImportingFolder = true);

    try {
      final selected = (await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择 EQ 文件夹（批量导入 .txt）',
      ))?.trim();
      if (!mounted || selected == null || selected.isEmpty) return;

      final dir = Directory(selected);
      if (!await dir.exists()) {
        showTextOnSnackBar('未找到文件夹');
        return;
      }

      final discoveredFiles = <File>[];
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is File && entry.path.toLowerCase().endsWith('.txt')) {
          discoveredFiles.add(entry);
        }
      }
      discoveredFiles.sort(
        (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
      );
      final skippedByCount = math.max(
        0,
        discoveredFiles.length - _maxEqImportFileCount,
      );
      final files = discoveredFiles
          .take(_maxEqImportFileCount)
          .toList(growable: false);

      if (files.isEmpty) {
        showTextOnSnackBar('该文件夹没有可导入的预设');
        return;
      }

      final playbackService = PlayService.instance.playbackService;
      final currentPreampDb = playbackService.eqPreampDb;
      final currentEqEnabled = playbackService.eqEnabled;
      final currentAutoGainEnabled = playbackService.eqAutoGainEnabled;
      final currentAutoHeadroomDb = playbackService.eqAutoHeadroomDb;
      final currentEffects = playbackService.audioEffects;
      final imported = <EqPreset>[];
      var totalBytes = 0;
      var failed = skippedByCount;

      for (final file in files) {
        try {
          final bytes = await _readEqFileBytes(
            file,
            remainingBytes: _maxEqImportTotalBytes - totalBytes,
          );
          if (bytes == null) {
            failed++;
            logger.w('跳过过大或发生变化的 EQ 文件：${file.path}');
            continue;
          }
          totalBytes += bytes.length;
          final content = _decodeEqText(bytes);
          if (!mounted) return;
          final fileName = file.uri.pathSegments.isEmpty
              ? file.path
              : file.uri.pathSegments.last;
          final parsed = parseWaveletEqContent(content);
          final appliedPreamp = (parsed.preampDb ?? currentPreampDb)
              .clamp(eqPreampMinDb, eqPreampMaxDb)
              .toDouble();
          imported.add(
            EqPreset(
              _waveletPresetName(fileName),
              parsed.gains,
              eqEnabled: currentEqEnabled,
              preampDb: appliedPreamp,
              eqAutoGainEnabled: currentAutoGainEnabled,
              eqAutoHeadroomDb: currentAutoHeadroomDb,
              audioDspSettings: currentEffects,
            ),
          );
        } catch (error, trace) {
          failed++;
          logger.w('跳过无效的 EQ 文件：${file.path}', error: error, stackTrace: trace);
        }
      }

      if (imported.isEmpty) {
        showTextOnSnackBar('没有成功导入的 EQ 预设', variant: ToastVariant.error);
        return;
      }

      final saved = await playbackService.importEqPresetsAndApplyLast(imported);
      if (!saved) {
        showTextOnSnackBar('批量保存 EQ 预设失败', variant: ToastVariant.error);
        return;
      }
      if (!mounted) return;

      final last = imported.last;
      setState(() {
        _gains = List.from(last.gains);
        _preampDb = last.preampDb;
      });
      showTextOnSnackBar(
        failed == 0
            ? '已导入 ${imported.length} 个 EQ 预设'
            : '已导入 ${imported.length} 个，跳过 $failed 个无效文件',
      );
    } catch (error, trace) {
      logger.e('批量导入均衡器预设失败', error: error, stackTrace: trace);
      if (mounted) {
        showTextOnSnackBar('批量导入均衡器预设失败，请查看日志');
      }
    } finally {
      if (mounted) setState(() => _isImportingFolder = false);
    }
  }

  String _decodeEqText(List<int> bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      final codeUnits = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        codeUnits.add(bytes[i] | (bytes[i + 1] << 8));
      }
      return String.fromCharCodes(codeUnits);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      final codeUnits = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        codeUnits.add((bytes[i] << 8) | bytes[i + 1]);
      }
      return String.fromCharCodes(codeUnits);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  void _savePreset() {
    final controller = TextEditingController();
    var isSaving = false;
    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('保存预设'),
          content: Focus(
            onFocusChange: HotkeysHelper.onFocusChanges,
            child: TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: '预设名称'),
              autofocus: true,
              enabled: !isSaving,
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSaving
                  ? null
                  : () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                final playbackService = PlayService.instance.playbackService;
                final existingName = findEquivalentEqPresetName(
                  existingNames: playbackService.eqPresets.map((e) => e.name),
                  input: value.text,
                );
                final presetName =
                    existingName ?? normalizedEqPresetName(value.text);
                final canSubmit = canSubmitEqPresetName(
                  input: value.text,
                  isSaving: isSaving,
                );
                return TextButton(
                  onPressed: !canSubmit
                      ? null
                      : () async {
                          setDialogState(() => isSaving = true);
                          final saved = await playbackService.saveEqPreset(
                            presetName,
                          );
                          if (!dialogContext.mounted) return;
                          if (!saved) {
                            setDialogState(() => isSaving = false);
                            showTextOnSnackBar(
                              '保存均衡器预设失败',
                              variant: ToastVariant.error,
                            );
                            return;
                          }
                          Navigator.of(dialogContext).pop();
                          if (mounted) {
                            showTextOnSnackBar(
                              '已保存预设',
                              variant: ToastVariant.success,
                            );
                            setState(() {});
                          }
                        },
                  child: isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(existingName == null ? '保存' : '更新'),
                );
              },
            ),
          ],
        ),
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _applyPreset(EqPreset preset) async {
    final saved = await PlayService.instance.playbackService.applyEqPreset(
      preset,
    );
    if (!mounted) return;
    if (!saved) {
      showTextOnSnackBar('保存均衡器设置失败', variant: ToastVariant.error);
      return;
    }
    showTextOnSnackBar('已应用预设', variant: ToastVariant.success);
    setState(() {
      _gains = List.from(preset.gains);
      if (preset.hasAudioState) {
        _preampDb = preset.preampDb;
        _effects = preset.audioDspSettings;
      }
    });
  }

  Future<void> _deletePreset(EqPreset preset) async {
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await showDangerConfirmDialog(
      context: context,
      title: '删除均衡器预设？',
      message: '这个预设会从列表中移除，不会改变当前正在播放的声音设置。',
      confirmLabel: '删除',
      details: Text(
        preset.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: AppType.caption,
        ),
      ),
    );
    if (!confirmed || !mounted) return;
    final saved = await PlayService.instance.playbackService.removeEqPreset(
      preset.name,
    );
    if (!mounted) return;
    if (!saved) {
      showTextOnSnackBar('删除均衡器预设失败', variant: ToastVariant.error);
      return;
    }
    showTextOnSnackBar('已删除预设', variant: ToastVariant.success);
    setState(() {}); // Refresh UI
  }

  bool get _isFlatEq {
    if (_preampDb.abs() > 0.001) return false;
    return _gains.every((gain) => gain.abs() <= 0.001);
  }

  bool _matchesCurrentGains(EqPreset preset) {
    final playbackService = PlayService.instance.playbackService;
    if (preset.gains.length != playbackService.eqGains.length) return false;
    for (var i = 0; i < _gains.length; i++) {
      if ((preset.gains[i] - playbackService.eqGains[i]).abs() > 0.001) {
        return false;
      }
    }
    if (!preset.hasAudioState) return true;
    if (preset.eqEnabled != playbackService.eqEnabled) return false;
    if ((preset.preampDb - playbackService.eqPreampDb).abs() > 0.001) {
      return false;
    }
    if (preset.eqAutoGainEnabled != playbackService.eqAutoGainEnabled) {
      return false;
    }
    if ((preset.eqAutoHeadroomDb - playbackService.eqAutoHeadroomDb).abs() >
        0.001) {
      return false;
    }
    final currentEffects = playbackService.audioEffects;
    final presetEffects = preset.audioDspSettings;
    if (currentEffects.enabled != presetEffects.enabled ||
        currentEffects.limiterEnabled != presetEffects.limiterEnabled ||
        (currentEffects.highPassHz - presetEffects.highPassHz).abs() > 0.001 ||
        (currentEffects.lowPassHz - presetEffects.lowPassHz).abs() > 0.001 ||
        (currentEffects.drive - presetEffects.drive).abs() > 0.001 ||
        (currentEffects.reverb - presetEffects.reverb).abs() > 0.001 ||
        (currentEffects.punch - presetEffects.punch).abs() > 0.001 ||
        (currentEffects.limiterCeilingDb - presetEffects.limiterCeilingDb)
                .abs() >
            0.001) {
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playbackService = PlayService.instance.playbackService;
    final presets = playbackService.eqPresets;
    final viewSize = MediaQuery.sizeOf(context);
    final contentWidth = (viewSize.width - 96).clamp(280.0, 600.0).toDouble();
    final contentHeight = (viewSize.height - 260)
        .clamp(220.0, 360.0)
        .toDouble();
    final bandsWidth = contentWidth < 520 ? 520.0 : contentWidth;
    final isImporting = _isImportingWaveletEq || _isImportingFolder;

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Row(
        children: [
          const Icon(Symbols.graphic_eq),
          const SizedBox(width: 12),
          const Text('均衡器'),
          const Spacer(),
          MenuAnchor(
            builder: (context, controller, child) {
              return IconButton(
                onPressed: isImporting
                    ? null
                    : () {
                        if (controller.isOpen) {
                          controller.close();
                        } else {
                          controller.open();
                        }
                      },
                tooltip: '预设',
                icon: const Icon(Symbols.queue_music),
              );
            },
            menuChildren: [
              if (presets.isEmpty)
                const MenuItemButton(onPressed: null, child: Text('无预设')),
              ...presets.map((preset) {
                final selected = _matchesCurrentGains(preset);
                return MenuItemButton(
                  onPressed: isImporting || selected
                      ? null
                      : () => _applyPreset(preset),
                  leadingIcon: selected ? const Icon(Symbols.check) : null,
                  trailingIcon: IconButton(
                    onPressed: isImporting ? null : () => _deletePreset(preset),
                    icon: const Icon(Symbols.close, size: 16),
                    tooltip: '删除',
                  ),
                  child: Text(preset.name),
                );
              }),
              const Divider(),
              for (final preset in builtInAudioPresets)
                MenuItemButton(
                  onPressed: isImporting
                      ? null
                      : () async {
                          final saved = await playbackService
                              .applyBuiltInAudioPreset(preset);
                          if (!mounted) return;
                          if (!saved) {
                            showTextOnSnackBar(
                              '保存均衡器设置失败',
                              variant: ToastVariant.error,
                            );
                            return;
                          }
                          setState(() {
                            _gains = List.from(preset.gains);
                            _preampDb = preset.preampDb;
                            _effects = playbackService.audioEffects;
                          });
                        },
                  leadingIcon: const Icon(Symbols.tune),
                  child: Text(preset.name),
                ),
              const Divider(),
              MenuItemButton(
                onPressed: isImporting ? null : _savePreset,
                leadingIcon: const Icon(Symbols.save),
                child: const Text('保存当前为预设...'),
              ),
            ],
          ),
          IconButton(
            onPressed: isImporting ? null : _importWaveletEq,
            tooltip: '\u5bfc\u5165 Wavelet AutoEq',
            icon: _isImportingWaveletEq
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Symbols.file_upload),
          ),
          IconButton(
            onPressed: isImporting ? null : _importEqFolder,
            tooltip: '从文件夹批量导入',
            icon: _isImportingFolder
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Symbols.folder_open),
          ),
          if (!playbackService.isBassFxLoaded)
            Tooltip(
              message: 'BASS_FX not loaded',
              child: Icon(Symbols.error, color: scheme.error),
            ),
        ],
      ),
      content: SizedBox(
        width: contentWidth,
        height: contentHeight,
        child: Column(
          children: [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment<int>(
                  value: 0,
                  icon: Icon(Symbols.equalizer, size: 18),
                  label: Text('均衡器'),
                ),
                ButtonSegment<int>(
                  value: 1,
                  icon: Icon(Symbols.tune, size: 18),
                  label: Text('音效'),
                ),
              ],
              selected: {_tabIndex},
              showSelectedIcon: false,
              onSelectionChanged: (selection) {
                setState(() => _tabIndex = selection.first);
              },
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _tabIndex == 0
                  ? _buildEqPanel(
                      scheme,
                      playbackService,
                      isImporting,
                      bandsWidth,
                    )
                  : _buildEffectsPanel(disabled: isImporting),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed:
              isImporting || (_tabIndex == 0 ? _isFlatEq : _isDefaultEffects)
              ? null
              : () {
                  if (_tabIndex == 0) {
                    setState(() {
                      _gains = List.filled(eqBandCount, 0.0);
                      _preampDb = 0.0;
                    });
                    playbackService.applyEqGainsSnapshot(
                      List.filled(eqBandCount, 0.0),
                      preampDb: 0.0,
                    );
                    playbackService.savePreference();
                  } else {
                    _updateEffects(const AudioDspSettings(), save: true);
                  }
                },
          icon: const Icon(Symbols.restart_alt),
          label: Text(_tabIndex == 0 ? 'EQ 归零' : '重置音效'),
        ),
        TextButton(
          onPressed: isImporting ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  bool get _isDefaultEffects {
    return !_effects.enabled &&
        (_effects.highPassHz - dspHighPassMinHz).abs() < 1e-6 &&
        (_effects.lowPassHz - dspLowPassMaxHz).abs() < 1e-6 &&
        _effects.drive.abs() < 1e-6 &&
        _effects.reverb.abs() < 1e-6 &&
        _effects.punch.abs() < 1e-6 &&
        !_effects.limiterEnabled &&
        (_effects.limiterCeilingDb + 1.0).abs() < 1e-6;
  }

  Widget _buildEqPanel(
    ColorScheme scheme,
    PlaybackService playbackService,
    bool isImporting,
    double bandsWidth,
  ) {
    return Column(
      children: [
        Row(
          children: [
            Text(
              '启用均衡器',
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: AppType.weightSemibold,
              ),
            ),
            const Spacer(),
            Switch(
              value: playbackService.eqEnabled,
              onChanged: isImporting
                  ? null
                  : (value) {
                      playbackService.setEqEnabled(value);
                      playbackService.savePreference();
                      setState(() {});
                    },
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              '前级增益',
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: AppType.weightSemibold,
              ),
            ),
            const SizedBox(width: 8),
            _EqValuePill(value: _preampDb),
            const SizedBox(width: 12),
            Expanded(
              child: Slider(
                min: -24.0,
                max: 24.0,
                value: _preampDb.clamp(-24.0, 24.0).toDouble(),
                onChanged: isImporting
                    ? null
                    : (value) {
                        setState(() {
                          _preampDb = value;
                        });
                        playbackService.setEqPreampDb(value);
                      },
                onChangeEnd: isImporting
                    ? null
                    : (_) => playbackService.savePreference(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('自动防削波'),
            const Spacer(),
            Text(
              '${playbackService.eqAutoGainDb.toStringAsFixed(1)} dB',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: AppType.microlabel,
              ),
            ),
            Switch(
              value: playbackService.eqAutoGainEnabled,
              onChanged: isImporting
                  ? null
                  : (value) {
                      playbackService.setEqAutoGainEnabled(value);
                      playbackService.savePreference();
                      setState(() {});
                    },
            ),
          ],
        ),
        Row(
          children: [
            const Text('保护余量'),
            const SizedBox(width: 8),
            _EqValuePill(value: playbackService.eqAutoHeadroomDb),
            const SizedBox(width: 12),
            Expanded(
              child: Slider(
                min: 0.0,
                max: 6.0,
                value: playbackService.eqAutoHeadroomDb
                    .clamp(0.0, 6.0)
                    .toDouble(),
                onChanged: isImporting
                    ? null
                    : (value) {
                        playbackService.setEqAutoHeadroomDb(value);
                        setState(() {});
                      },
                onChangeEnd: isImporting
                    ? null
                    : (_) => playbackService.savePreference(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: bandsWidth,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(eqBandCount, (index) {
                  return Column(
                    children: [
                      Text(
                        '${_gains[index].toInt()}',
                        style: TextStyle(
                          fontSize: AppType.microlabel,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 4.0,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6.0,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 14.0,
                              ),
                            ),
                            child: Slider(
                              min: -15.0,
                              max: 15.0,
                              value: _gains[index],
                              onChanged:
                                  isImporting || !playbackService.eqEnabled
                                  ? null
                                  : (value) {
                                      setState(() {
                                        _gains[index] = value;
                                      });
                                      playbackService.setEQ(index, value);
                                    },
                              onChangeEnd: isImporting
                                  ? null
                                  : (_) {
                                      playbackService.savePreference();
                                    },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _eqCenters[index],
                        style: const TextStyle(fontSize: AppType.microlabel),
                      ),
                    ],
                  );
                }),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEffectsPanel({required bool disabled}) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('启用音效处理'),
              const Spacer(),
              Switch(
                value: _effects.enabled,
                onChanged: disabled
                    ? null
                    : (value) {
                        _updateEffects(
                          _effects.copyWith(enabled: value),
                          save: true,
                        );
                      },
              ),
            ],
          ),
          Row(
            children: [
              const Text('峰值保护'),
              const Spacer(),
              Switch(
                value: _effects.limiterEnabled,
                onChanged: disabled
                    ? null
                    : (value) {
                        _updateEffects(
                          _effects.copyWith(limiterEnabled: value),
                          save: true,
                        );
                      },
              ),
            ],
          ),
          if (_effects.limiterEnabled)
            _effectSlider(
              label: '上限',
              value: _effects.limiterCeilingDb,
              min: -12,
              max: -0.1,
              format: (value) => '${value.toStringAsFixed(1)}dB',
              onChanged: (value) =>
                  _updateEffects(_effects.copyWith(limiterCeilingDb: value)),
              enabled: !disabled,
            ),
          _effectSlider(
            label: '高通',
            value: _effects.highPassHz,
            min: dspHighPassMinHz,
            max: math.min(
              dspHighPassMaxHz,
              _effects.lowPassHz - dspMinimumPassBandGapHz,
            ),
            format: (value) => '${value.round()}Hz',
            onChanged: (value) =>
                _updateEffects(_effects.copyWith(highPassHz: value)),
            enabled: !disabled,
          ),
          _effectSlider(
            label: '低通',
            value: _effects.lowPassHz,
            min: math.max(
              dspLowPassMinHz,
              _effects.highPassHz + dspMinimumPassBandGapHz,
            ),
            max: dspLowPassMaxHz,
            format: (value) => '${(value / 1000).toStringAsFixed(1)}k',
            onChanged: (value) =>
                _updateEffects(_effects.copyWith(lowPassHz: value)),
            enabled: !disabled,
          ),
          _effectSlider(
            label: '驱动',
            value: _effects.drive,
            min: 0,
            max: 1,
            format: (value) => '${(value * 100).round()}%',
            onChanged: (value) =>
                _updateEffects(_effects.copyWith(drive: value)),
            enabled: !disabled,
          ),
          _effectSlider(
            label: '混响',
            value: _effects.reverb,
            min: 0,
            max: 1,
            format: (value) => '${(value * 100).round()}%',
            onChanged: (value) =>
                _updateEffects(_effects.copyWith(reverb: value)),
            enabled: !disabled,
          ),
          _effectSlider(
            label: '压缩',
            value: _effects.punch,
            min: 0,
            max: 1,
            format: (value) => '${(value * 100).round()}%',
            onChanged: (value) =>
                _updateEffects(_effects.copyWith(punch: value)),
            enabled: !disabled,
          ),
          const SizedBox(height: 8),
          Text(
            '处理顺序：EQ → 滤波 → 染色 → 压缩 → 输出 → 峰值保护',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: AppType.microlabel,
            ),
          ),
        ],
      ),
    );
  }
}
