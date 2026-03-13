import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class AmllLikeBackground extends StatefulWidget {
  final ImageProvider? albumImage;
  final Color? dominantColor;
  final double flowSpeed;
  final double intensity;
  final bool enableAnimation;
  final Stream<Float32List>? spectrumStream;
  final Widget? fallback;

  const AmllLikeBackground({
    super.key,
    this.albumImage,
    this.dominantColor,
    this.flowSpeed = 2.0,
    this.intensity = 1.0,
    this.enableAnimation = true,
    this.spectrumStream,
    this.fallback,
  });

  @override
  State<AmllLikeBackground> createState() => _AmllLikeBackgroundState();
}

class _AmllLikeBackgroundState extends State<AmllLikeBackground>
    with TickerProviderStateMixin {
  late AnimationController _animationController;
  late AnimationController _colorAnimationController;
  late Animation<Color?> _colorAnimation;
  
  StreamSubscription<Float32List>? _spectrumSub;
  double _lowFreqVolume = 0.0;
  
  Color _currentColor = Colors.grey.shade900;
  Color _previousColor = Colors.grey.shade900;
  
  final math.Random _random = math.Random();
  late List<_BlurLayer> _layers;

  @override
  void initState() {
    super.initState();
    
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    );
    
    _colorAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    
    _currentColor = widget.dominantColor ?? Colors.grey.shade900;
    _previousColor = _currentColor;
    
    _colorAnimation = ColorTween(
      begin: _currentColor,
      end: _currentColor,
    ).animate(CurvedAnimation(
      parent: _colorAnimationController,
      curve: Curves.easeInOut,
    ));
    
    _initLayers();
    _bindSpectrumStream();
    
    if (widget.enableAnimation) {
      _animationController.repeat();
    }
  }

  void _initLayers() {
    _layers = List.generate(5, (index) {
      return _BlurLayer(
        baseOffset: Offset(
          (_random.nextDouble() - 0.5) * 0.6,
          (_random.nextDouble() - 0.5) * 0.6,
        ),
        speed: 0.3 + _random.nextDouble() * 0.5,
        amplitude: 0.05 + _random.nextDouble() * 0.1,
        phase: _random.nextDouble() * math.pi * 2,
      );
    });
  }

  void _bindSpectrumStream() {
    _spectrumSub?.cancel();
    final stream = widget.spectrumStream;
    if (stream == null) return;
    
    _spectrumSub = stream.listen((frame) {
      if (!mounted) return;
      if (frame.isEmpty) return;
      
      // 取低频平均值 (前8个)
      final lowFreq = frame.length >= 8 
          ? frame.sublist(0, 8).reduce((a, b) => a + b) / 8
          : frame.reduce((a, b) => a + b) / frame.length;
      
      // 平滑过渡
      setState(() {
        _lowFreqVolume = _lowFreqVolume * 0.7 + lowFreq * 0.3;
      });
    });
  }

  @override
  void didUpdateWidget(AmllLikeBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    if (widget.enableAnimation != oldWidget.enableAnimation) {
      if (widget.enableAnimation) {
        _animationController.repeat();
      } else {
        _animationController.stop();
      }
    }
    
    if (widget.spectrumStream != oldWidget.spectrumStream) {
      _bindSpectrumStream();
    }
    
    if (widget.dominantColor != oldWidget.dominantColor && widget.dominantColor != null) {
      _transitionToColor(widget.dominantColor!);
    }
  }

  void _transitionToColor(Color newColor) {
    _previousColor = _colorAnimation.value ?? _currentColor;
    _currentColor = newColor;
    
    _colorAnimation = ColorTween(
      begin: _previousColor,
      end: newColor,
    ).animate(CurvedAnimation(
      parent: _colorAnimationController,
      curve: Curves.easeInOut,
    ));
    
    _colorAnimationController.forward(from: 0);
  }

  @override
  void dispose() {
    _spectrumSub?.cancel();
    _animationController.dispose();
    _colorAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.albumImage == null && widget.dominantColor == null) {
      return widget.fallback ?? Container(color: Colors.black);
    }

    return AnimatedBuilder(
      animation: Listenable.merge([_animationController, _colorAnimation]),
      builder: (context, child) {
        final color = _colorAnimation.value ?? _currentColor;
        final secondaryColor = _getComplementaryColor(color);
        
        // 根据低频音量调整跳动强度
        final bounceScale = 1.0 + _lowFreqVolume * 0.15 * widget.intensity;
        
        return Stack(
          fit: StackFit.expand,
          children: [
            // 底层颜色
            Container(color: color),
            
            // 封面图片（模糊后）
            if (widget.albumImage != null)
              _buildBlurredImage(bounceScale),
            
            // 彩色渐变层
            ..._buildGradientLayers(color, secondaryColor, bounceScale),
            
            // 顶部模糊叠加
            _buildTopBlurOverlay(),
          ],
        );
      },
    );
  }

  Widget _buildBlurredImage(double bounceScale) {
    return Transform.scale(
      scale: bounceScale,
      child: Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: widget.albumImage!,
            fit: BoxFit.cover,
            colorFilter: ColorFilter.mode(
              Colors.black.withValues(alpha: 0.3),
              BlendMode.srcOver,
            ),
          ),
        ),
        child: ClipRect(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 60, sigmaY: 60),
            child: Container(color: Colors.transparent),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildGradientLayers(Color primary, Color secondary, double bounceScale) {
    final time = _animationController.value * 2 * math.pi;
    final layers = <Widget>[];
    
    for (int i = 0; i < _layers.length; i++) {
      final layer = _layers[i];
      
      // 持续的流动动画
      final flowX = math.cos(time * layer.speed * widget.flowSpeed + layer.phase) * layer.amplitude;
      final flowY = math.sin(time * layer.speed * widget.flowSpeed + layer.phase) * layer.amplitude;
      
      // 低频引起的跳动
      final bounce = (bounceScale - 1.0) * (i + 1) * 0.1;
      
      final size = 1.2 + i * 0.3 + bounce;
      
      layers.add(
        Positioned.fill(
          child: Transform.translate(
            offset: Offset(
              MediaQuery.of(context).size.width * (layer.baseOffset.dx + flowX),
              MediaQuery.of(context).size.height * (layer.baseOffset.dy + flowY),
            ),
            child: Center(
              child: Transform.scale(
                scale: size,
                child: Container(
                  width: MediaQuery.of(context).size.width,
                  height: MediaQuery.of(context).size.height,
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [
                        i.isEven ? primary : secondary,
                        (i.isEven ? primary : secondary).withValues(alpha: 0.5 * widget.intensity),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.4, 1.0],
                    ),
                  ),
                  child: ClipRect(
                    child: ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: 40.0 + i * 20,
                        sigmaY: 40.0 + i * 20,
                      ),
                      child: Container(color: Colors.transparent),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    
    return layers;
  }

  Widget _buildTopBlurOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.2),
                Colors.black.withValues(alpha: 0.0),
                Colors.black.withValues(alpha: 0.3),
              ],
              stops: const [0.0, 0.4, 1.0],
            ),
          ),
        ),
      ),
    );
  }

  Color _getComplementaryColor(Color color) {
    final hsl = HSLColor.fromColor(color);
    return hsl.withHue((hsl.hue + 30) % 360).toColor();
  }
}

class _BlurLayer {
  final Offset baseOffset;
  final double speed;
  final double amplitude;
  final double phase;

  _BlurLayer({
    required this.baseOffset,
    required this.speed,
    required this.amplitude,
    required this.phase,
  });
}
