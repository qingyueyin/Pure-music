import 'package:pure_music/component/danger_confirm_dialog.dart';
import 'package:pure_music/core/equalizer_action_state.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

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
  bool _isImportingWaveletEq = false;
  bool _isImportingFolder = false;
  static const _eqCenters = [
    '80',
    '100',
    '125',
    '250',
    '500',
    '1k',
    '2k',
    '4k',
    '8k',
    '16k'
  ];
  static const _eqFreqs = [
    80.0,
    100.0,
    125.0,
    250.0,
    500.0,
    1000.0,
    2000.0,
    4000.0,
    8000.0,
    16000.0
  ];

  @override
  void initState() {
    super.initState();
    final playbackService = PlayService.instance.playbackService;
    _gains = List.from(playbackService.eqGains);
    _preampDb = playbackService.eqPreampDb;
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

      if (result != null && result.files.single.path != null) {
        try {
          final content = await File(result.files.single.path!).readAsString();
          final fileName =
              result.files.single.name.split('.').first.replaceAll('.txt', '');
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

  double? _tryParseWaveletPreampDb(String content) {
    final match = RegExp(
      r'^\s*preamp\s*:\s*([+-]?\d+(?:\.\d+)?)',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(content);
    if (match == null) return null;
    return double.tryParse(match.group(1) ?? '');
  }

  Iterable<MapEntry<double, double>> _extractWaveletPairs(String content) {
    final normalized = content.replaceAll('\uFEFF', '');
    final graphicEqMatch = RegExp(
      r'^\s*graphiceq\s*:\s*(.*)$',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(normalized);

    final region =
        graphicEqMatch == null ? normalized : graphicEqMatch.group(1)!;
    final pairs = <MapEntry<double, double>>[];

    final pairReg = RegExp(
      r'(\d+(?:[.,]\d+)?)\s*(?:hz)?\s*[:\s]\s*([+-]?\d+(?:[.,]\d+)?)\s*(?:db)?',
      caseSensitive: false,
      multiLine: true,
    );
    for (final m in pairReg.allMatches(region)) {
      final freqStr = (m.group(1) ?? '').replaceAll(',', '.');
      final gainStr = (m.group(2) ?? '').replaceAll(',', '.');
      final freq = double.tryParse(freqStr);
      final gain = double.tryParse(gainStr);
      if (freq == null || gain == null) continue;
      if (freq <= 0) continue;
      pairs.add(MapEntry(freq, gain));
    }

    return pairs;
  }

  ({List<double> gains, double? preampDb}) _parseWaveletEqContent(
    String content,
  ) {
    final preampDb = _tryParseWaveletPreampDb(content);
    final points = _extractWaveletPairs(content).toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    if (points.isEmpty) {
      throw const FormatException('No valid GraphicEQ pairs found');
    }

    final newGains = List<double>.filled(10, 0.0);
    for (int i = 0; i < 10; i++) {
      final centerFreq = _eqFreqs[i];
      newGains[i] = _interpolateGain(centerFreq, points).clamp(-15.0, 15.0);
    }

    return (gains: newGains, preampDb: preampDb);
  }

  Future<bool> _applyWaveletEqFromContent(
    String content, {
    required String presetName,
    bool updateState = true,
  }) async {
    final playbackService = PlayService.instance.playbackService;

    final parsed = _parseWaveletEqContent(content);
    final newGains = parsed.gains;
    final preampDb = parsed.preampDb;

    if (preampDb != null) {
      _preampDb = preampDb;
      playbackService.setEqPreampDb(preampDb);
    }

    for (int i = 0; i < 10; i++) {
      playbackService.setEQ(i, newGains[i]);
    }
    playbackService.savePreference();
    final saved = await playbackService.saveEqPreset(presetName);
    if (!saved) return false;

    if (!updateState || !mounted) return true;
    setState(() {
      _gains = List.from(newGains);
      if (preampDb != null) {
        _preampDb = preampDb;
      }
    });
    return true;
  }

  Future<void> _importEqFolder() async {
    if (_isImportingFolder || _isImportingWaveletEq) return;
    setState(() {
      _isImportingFolder = true;
    });

    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择 EQ 文件夹（批量导入 .txt）',
    );
    if (selected == null) {
      if (mounted) {
        setState(() {
          _isImportingFolder = false;
        });
      }
      return;
    }

    final folderPath = selected;
    final dir = Directory(folderPath);
    if (!dir.existsSync()) {
      if (mounted) showTextOnSnackBar('未找到文件夹');
      if (mounted) {
        setState(() {
          _isImportingFolder = false;
        });
      }
      return;
    }

    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.txt'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    if (files.isEmpty) {
      if (mounted) {
        showTextOnSnackBar('该文件夹没有可导入的预设');
        setState(() {
          _isImportingFolder = false;
        });
      }
      return;
    }

    String? lastImportedName;
    String? lastImportedContent;

    for (final f in files) {
      try {
        final content = await f.readAsString();
        final name = f.uri.pathSegments.last.replaceAll('.txt', '');
        final saved = await _applyWaveletEqFromContent(
          content,
          presetName: name,
          updateState: false,
        );
        if (!saved) {
          continue;
        }
        lastImportedName = name;
        lastImportedContent = content;
      } catch (_) {}
    }

    if (lastImportedName != null && lastImportedContent != null && mounted) {
      try {
        await _applyWaveletEqFromContent(
          lastImportedContent,
          presetName: lastImportedName,
        );
      } catch (_) {}
    }

    if (mounted) {
      showTextOnSnackBar('已导入预设');
    }

    if (mounted) {
      setState(() {
        _isImportingFolder = false;
      });
    }
  }

  double _interpolateGain(
      double targetFreq, List<MapEntry<double, double>> points) {
    // Find closest points
    if (targetFreq <= points.first.key) return points.first.value;
    if (targetFreq >= points.last.key) return points.last.value;

    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];
      if (targetFreq >= p1.key && targetFreq <= p2.key) {
        // Linear interpolation
        final t = (targetFreq - p1.key) / (p2.key - p1.key);
        return p1.value + (p2.value - p1.value) * t;
      }
    }
    return 0.0;
  }

  void _savePreset() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存预设'),
        content: Focus(
          onFocusChange: HotkeysHelper.onFocusChanges,
          child: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: '预设名称'),
            autofocus: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
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
                isSaving: false,
              );
              return TextButton(
                onPressed: !canSubmit
                    ? null
                    : () async {
                        final saved =
                            await playbackService.saveEqPreset(presetName);
                        if (!context.mounted) return;
                        if (!saved) {
                          showTextOnSnackBar('保存均衡器预设失败',
                              variant: ToastVariant.error);
                          return;
                        }
                        Navigator.of(context).pop();
                        if (mounted) {
                          showTextOnSnackBar('已保存预设',
                              variant: ToastVariant.success);
                          setState(() {});
                        }
                      },
                child: Text(existingName == null ? '保存' : '更新'),
              );
            },
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _applyPreset(EqPreset preset) async {
    final saved =
        await PlayService.instance.playbackService.applyEqPreset(preset);
    if (!mounted) return;
    if (!saved) {
      showTextOnSnackBar('保存均衡器设置失败', variant: ToastVariant.error);
      return;
    }
    showTextOnSnackBar('已应用预设', variant: ToastVariant.success);
    setState(() {
      _gains = List.from(preset.gains);
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
            color: scheme.onSurfaceVariant, fontSize: AppType.caption),
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
    if (preset.gains.length != _gains.length) return false;
    for (var i = 0; i < _gains.length; i++) {
      if ((preset.gains[i] - _gains[i]).abs() > 0.001) return false;
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
    final contentHeight =
        (viewSize.height - 260).clamp(220.0, 360.0).toDouble();
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
          // Presets Menu
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
                const MenuItemButton(
                  onPressed: null,
                  child: Text('无预设'),
                ),
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
            const SizedBox(height: 20),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: bandsWidth,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: List.generate(10, (index) {
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
                                  onChanged: isImporting
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
                            style:
                                const TextStyle(fontSize: AppType.microlabel),
                          ),
                        ],
                      );
                    }),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: isImporting || _isFlatEq
              ? null
              : () {
                  setState(() {
                    _gains = List.filled(10, 0.0);
                    _preampDb = 0.0;
                  });
                  for (int i = 0; i < 10; i++) {
                    playbackService.setEQ(i, 0.0);
                  }
                  playbackService.setEqPreampDb(0.0);
                  playbackService.savePreference();
                },
          icon: const Icon(Symbols.restart_alt),
          label: const Text('全部归零'),
        ),
        TextButton(
          onPressed: isImporting ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
