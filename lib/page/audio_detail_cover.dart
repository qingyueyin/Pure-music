import 'package:flutter/material.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/library/audio_library.dart';

class AudioDetailCover extends StatefulWidget {
  const AudioDetailCover({
    super.key,
    required this.audio,
    required this.placeholder,
    this.revision = 0,
  });

  final Audio audio;
  final Widget placeholder;
  final int revision;

  @override
  State<AudioDetailCover> createState() => _AudioDetailCoverState();
}

class _AudioDetailCoverState extends State<AudioDetailCover> {
  late Future<ImageProvider?> _future;
  late String _path;
  late int _modified;

  void _load() {
    _path = widget.audio.path;
    _modified = widget.audio.modified;
    _future = widget.audio.mediumCover;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AudioDetailCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.audio, oldWidget.audio) ||
        widget.audio.path != _path ||
        widget.audio.modified != _modified ||
        widget.revision != oldWidget.revision) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ImageProvider?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            width: 156,
            height: 156,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final image = snapshot.data;
        if (image == null) return widget.placeholder;
        return ClipRRect(
          borderRadius: AppRadius.mdCircular,
          child: Image(
            image: image,
            width: 156,
            height: 156,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => widget.placeholder,
          ),
        );
      },
    );
  }
}
