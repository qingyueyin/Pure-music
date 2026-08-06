import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:pure_music/page/now_playing_page/component/now_playing_background_inputs.dart';
import 'package:pure_music/page/now_playing_page/component/static_cover_background.dart';
import 'package:pure_music/native/bass/bass_player.dart' show PlayerState;

class StaticCoverBackgroundTestPage extends StatefulWidget {
  const StaticCoverBackgroundTestPage({super.key});

  @override
  State<StaticCoverBackgroundTestPage> createState() =>
      _StaticCoverBackgroundTestPageState();
}

class _StaticCoverBackgroundTestPageState
    extends State<StaticCoverBackgroundTestPage> {
  bool _darkTheme = true;
  Uint8List? _testImageBytes;
  int _testPattern = 0;

  @override
  void initState() {
    super.initState();
    _generateTestImage();
  }

  Future<void> _generateTestImage() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    switch (_testPattern) {
      case 0:
        _drawGradientPattern(canvas);
      case 1:
        _drawColorBarsPattern(canvas);
      case 2:
        _drawPortraitPattern(canvas);
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(128, 128);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (!mounted) return;
    setState(() {
      _testImageBytes = byteData!.buffer.asUint8List();
    });
  }

  void _drawGradientPattern(Canvas canvas) {
    final paint = Paint();
    for (int y = 0; y < 128; y++) {
      for (int x = 0; x < 128; x++) {
        paint.color = Color.fromARGB(255, x * 2, y * 2, (x + y) * 2);
        canvas.drawCircle(Offset(x.toDouble(), y.toDouble()), 0.5, paint);
      }
    }
    Paint shapePaint = Paint()..color = Colors.red;
    canvas.drawCircle(const Offset(32, 32), 20, shapePaint);
    shapePaint.color = Colors.green;
    canvas.drawRect(const Rect.fromLTWH(80, 64, 40, 40), shapePaint);
    shapePaint.color = Colors.blue;
    canvas.drawOval(const Rect.fromLTWH(20, 70, 48, 50), shapePaint);
    shapePaint.color = Colors.yellow;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(50, 16, 60, 30),
        const Radius.circular(8),
      ),
      shapePaint,
    );
  }

  void _drawColorBarsPattern(Canvas canvas) {
    final paint = Paint();
    const barW = 128.0 / 6;
    const colors = [
      0xFFFF0000,
      0xFF00FF00,
      0xFF0000FF,
      0xFFFFFF00,
      0xFFFF00FF,
      0xFF00FFFF,
    ];
    for (int i = 0; i < 6; i++) {
      paint.color = Color(colors[i]);
      canvas.drawRect(Rect.fromLTWH(i * barW, 0, barW, 128), paint);
    }
  }

  void _drawPortraitPattern(Canvas canvas) {
    final paint = Paint();
    paint.color = const Color(0xFFFF8C00);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 128, 128), paint);
    paint.color = const Color(0xFF8B4513);
    canvas.drawRect(const Rect.fromLTWH(20, 30, 88, 90), paint);
    paint.color = const Color(0xFFD2691E);
    canvas.drawCircle(const Offset(64, 50), 16, paint);
    paint.color = const Color(0xFF228B22);
    canvas.drawCircle(const Offset(50, 40), 6, paint);
    canvas.drawCircle(const Offset(78, 40), 6, paint);
    paint.color = const Color(0xFF000000);
    canvas.drawCircle(const Offset(50, 40), 2, paint);
    canvas.drawCircle(const Offset(78, 40), 2, paint);
    paint.color = const Color(0xFFFFB6C1);
    canvas.drawArc(
      const Rect.fromLTWH(44, 50, 40, 24),
      -0.2,
      -3.14 + 0.4,
      false,
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    paint.style = PaintingStyle.fill;
  }

  Color get _fallbackColor => _darkTheme ? Colors.black : Colors.white;

  @override
  Widget build(BuildContext context) {
    final textColor =
        _darkTheme ? Colors.white.withAlpha(200) : Colors.black.withAlpha(200);

    return Theme(
      data: _darkTheme ? ThemeData.dark() : ThemeData.light(),
      child: Scaffold(
        body: Stack(
          children: [
            if (_testImageBytes != null)
              StaticCoverBackground(
                inputs: NowPlayingBackgroundInputs(
                  albumCoverBytes: _testImageBytes,
                  dominantColor: null,
                  spectrumStream: null,
                  enableAnimation: false,
                  isVisible: true,
                  playerState: PlayerState.paused,
                ),
                fallbackColor: _fallbackColor,
              ),
            Positioned(
              left: 16,
              bottom: 32,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InfoChip(
                    label: 'darkScrim',
                    value: '0.15',
                    color: textColor,
                  ),
                  const SizedBox(height: 4),
                  _InfoChip(
                    label: 'lightScrim',
                    value: '0.25',
                    color: textColor,
                  ),
                  const SizedBox(height: 4),
                  _InfoChip(
                    label: 'whiteScrim',
                    value: '0.04',
                    color: textColor,
                  ),
                ],
              ),
            ),
            Positioned(
              right: 16,
              bottom: 32,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Controls',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Dark'),
                          Switch(
                            value: _darkTheme,
                            onChanged: (v) => setState(() {
                              _darkTheme = v;
                              _generateTestImage();
                            }),
                          ),
                          const Text('Light'),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 0, label: Text('Gradient')),
                          ButtonSegment(value: 1, label: Text('Bars')),
                          ButtonSegment(value: 2, label: Text('Face')),
                        ],
                        selected: {_testPattern},
                        onSelectionChanged: (v) {
                          setState(() => _testPattern = v.first);
                          _generateTestImage();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 48,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close),
                style: IconButton.styleFrom(
                  backgroundColor: _darkTheme
                      ? Colors.white.withAlpha(30)
                      : Colors.black.withAlpha(30),
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label = $value',
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}
