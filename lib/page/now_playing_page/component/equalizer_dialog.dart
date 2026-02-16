import 'package:pure_music/app_preference.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/utils.dart';
import 'dart:io';
import 'package:filepicker_windows/filepicker_windows.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class EqualizerDialog extends StatefulWidget {
  const EqualizerDialog({super.key});

  @override
  State<EqualizerDialog> createState() => _EqualizerDialogState();
}

class _EqualizerDialogState extends State<EqualizerDialog> {
  late List<double> _gains;
  late double _preampDb;
  bool _isImportingFolder = false;
  static const _eqCenters = [
    "80",
    "100",
    "125",
    "250",
    "500",
    "1k",
    "2k",
    "4k",
    "8k",
    "16k"
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
    final file = OpenFilePicker()
      ..filterSpecification = {
        'Wavelet AutoEq Files (*.txt)': '*.txt',
        'All Files (*.*)': '*.*'
      }
      ..defaultFilterIndex = 0
      ..defaultExtension = 'txt'
      ..title = 'Select Wavelet GraphicEQ.txt';

    final result = file.getFile();
    if (result != null) {
      try {
        final content = await result.readAsString();
        final fileName = result.path.split('\\').last.replaceAll('.txt', '');
        _applyWaveletEqFromContent(content, presetName: fileName);
      } catch (e) {
        if (mounted) {
          showTextOnSnackBar("Import failed: $e");
        }
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

  void _applyWaveletEqFromContent(
    String content, {
    required String presetName,
  }) {
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
    playbackService.saveEqPreset(presetName);

    setState(() {
      _gains = List.from(newGains);
      if (preampDb != null) {
        _preampDb = preampDb;
      }
    });
  }

  Future<void> _importEqFolder() async {
    if (_isImportingFolder) return;
    setState(() {
      _isImportingFolder = true;
    });

    final dirPicker = DirectoryPicker();
    dirPicker.title = "选择 EQ 文件夹（批量导入 .txt）";
    final selected = dirPicker.getDirectory();
    if (selected == null) {
      if (mounted) {
        setState(() {
          _isImportingFolder = false;
        });
      }
      return;
    }

    final folderPath = selected.path;
    final dir = Directory(folderPath);
    if (!dir.existsSync()) {
      if (mounted) showTextOnSnackBar("未找到文件夹：$folderPath");
      setState(() {
        _isImportingFolder = false;
      });
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
        showTextOnSnackBar("该文件夹没有可导入的 .txt：$folderPath");
        setState(() {
          _isImportingFolder = false;
        });
      }
      return;
    }

    int ok = 0;
    int failed = 0;
    String? lastImportedName;
    String? lastImportedContent;

    for (final f in files) {
      try {
        final content = await f.readAsString();
        final name = f.uri.pathSegments.last.replaceAll('.txt', '');
        _applyWaveletEqFromContent(content, presetName: name);
        ok += 1;
        lastImportedName = name;
        lastImportedContent = content;
      } catch (_) {
        failed += 1;
      }
    }

    if (mounted) {
      showTextOnSnackBar("已从文件夹导入 $ok 个，失败 $failed 个");
    }

    if (lastImportedName != null && lastImportedContent != null) {
      try {
        _applyWaveletEqFromContent(
          lastImportedContent,
          presetName: lastImportedName,
        );
      } catch (_) {}
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
        title: const Text("保存预设"),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: "预设名称"),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                PlayService.instance.playbackService
                    .saveEqPreset(controller.text);
                Navigator.of(context).pop();
                setState(() {}); // Refresh UI
              }
            },
            child: const Text("保存"),
          ),
        ],
      ),
    );
  }

  void _applyPreset(EqPreset preset) {
    PlayService.instance.playbackService.applyEqPreset(preset);
    setState(() {
      _gains = List.from(preset.gains);
    });
  }

  void _deletePreset(EqPreset preset) {
    PlayService.instance.playbackService.removeEqPreset(preset.name);
    setState(() {}); // Refresh UI
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playbackService = PlayService.instance.playbackService;
    final presets = playbackService.eqPresets;

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Symbols.graphic_eq),
          const SizedBox(width: 12),
          const Text("均衡器"),
          const Spacer(),
          // Presets Menu
          MenuAnchor(
            builder: (context, controller, child) {
              return IconButton(
                onPressed: () {
                  if (controller.isOpen) {
                    controller.close();
                  } else {
                    controller.open();
                  }
                },
                tooltip: "预设",
                icon: const Icon(Symbols.queue_music),
              );
            },
            menuChildren: [
              if (presets.isEmpty)
                const MenuItemButton(
                  onPressed: null,
                  child: Text("无预设"),
                ),
              ...presets.map(
                (preset) => MenuItemButton(
                  onPressed: () => _applyPreset(preset),
                  trailingIcon: IconButton(
                    onPressed: () => _deletePreset(preset),
                    icon: const Icon(Symbols.close, size: 16),
                    tooltip: "删除",
                  ),
                  child: Text(preset.name),
                ),
              ),
              const Divider(),
              MenuItemButton(
                onPressed: _savePreset,
                leadingIcon: const Icon(Symbols.save),
                child: const Text("保存当前为预设..."),
              ),
            ],
          ),
          IconButton(
            onPressed: _importWaveletEq,
            tooltip: "导入 Wavelet AutoEq",
            icon: const Icon(Symbols.file_upload),
          ),
          IconButton(
            onPressed: _isImportingFolder ? null : _importEqFolder,
            tooltip: "从文件夹批量导入",
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
              message: "BASS_FX not loaded",
              child: Icon(Symbols.error, color: scheme.error),
            ),
        ],
      ),
      content: SizedBox(
        width: 600,
        height: 360,
        child: Column(
          children: [
            Row(
              children: [
                const Text("Preamp"),
                const SizedBox(width: 12),
                Expanded(
                  child: Slider(
                    min: -24.0,
                    max: 24.0,
                    value: _preampDb.clamp(-24.0, 24.0).toDouble(),
                    onChanged: (value) {
                      setState(() {
                        _preampDb = value;
                      });
                      playbackService.setEqPreampDb(value);
                    },
                    onChangeEnd: (_) => playbackService.savePreference(),
                  ),
                ),
                SizedBox(
                  width: 72,
                  child: Text(
                    "${_preampDb.toStringAsFixed(1)}dB",
                    textAlign: TextAlign.end,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(10, (index) {
                  return Column(
                    children: [
                      Text(
                        "${_gains[index].toInt()}",
                        style: TextStyle(
                          fontSize: 10,
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
                              onChanged: (value) {
                                setState(() {
                                  _gains[index] = value;
                                });
                                playbackService.setEQ(index, value);
                              },
                              onChangeEnd: (_) {
                                playbackService.savePreference();
                              },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _eqCenters[index],
                        style: const TextStyle(fontSize: 10),
                      ),
                    ],
                  );
                }),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
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
          child: const Text("重置"),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("关闭"),
        ),
      ],
    );
  }
}
