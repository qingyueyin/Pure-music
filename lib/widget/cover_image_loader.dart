import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pure_music/core/color_extraction.dart';

class CoverImageLoader extends StatefulWidget {
  final Future<Uint8List?> coverDataFuture;
  final double size;
  final BorderRadius? borderRadius;
  final Function(Uint8List coverBytes)? onCoverLoaded;
  final Function(Color? dominantColor)? onColorExtracted;

  const CoverImageLoader({
    super.key,
    required this.coverDataFuture,
    this.size = 200,
    this.borderRadius,
    this.onCoverLoaded,
    this.onColorExtracted,
  });

  @override
  State<CoverImageLoader> createState() => _CoverImageLoaderState();
}

class _CoverImageLoaderState extends State<CoverImageLoader> {
  Uint8List? _coverBytes;
  bool _isLoading = true;
  final ColorExtractionService _colorService = ColorExtractionService();

  @override
  void initState() {
    super.initState();
    _loadCover();
  }

  @override
  void didUpdateWidget(CoverImageLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverDataFuture != widget.coverDataFuture) {
      _loadCover();
    }
  }

  Future<void> _loadCover() async {
    setState(() => _isLoading = true);
    try {
      final bytes = await widget.coverDataFuture;
      if (mounted) {
        setState(() {
          _coverBytes = bytes;
          _isLoading = false;
        });
        if (bytes != null) {
          widget.onCoverLoaded?.call(bytes);
          _extractColor(bytes);
        }
      }
    } catch (e) {
      debugPrint('Failed to load cover: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _extractColor(Uint8List bytes) async {
    final color = await _colorService.extractDominantColor(bytes);
    if (mounted && color != null) {
      widget.onColorExtracted?.call(color);
    }
  }

  @override
  Widget build(BuildContext context) {
    final borderRadius = widget.borderRadius ?? BorderRadius.circular(12);

    if (_isLoading) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: borderRadius,
        ),
        child: Center(
          child: SizedBox(
            width: widget.size * 0.2,
            height: widget.size * 0.2,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    if (_coverBytes == null) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: borderRadius,
        ),
        child: Icon(
          Icons.music_note,
          size: widget.size * 0.5,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }

    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
        image: DecorationImage(
          image: MemoryImage(_coverBytes!),
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}
