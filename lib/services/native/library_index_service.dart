import 'package:pure_music/native/rust/api/tag_reader.dart' as rust_tag_reader;

enum LibraryIndexPhase { preparing, scanning, saving, complete }

class LibraryIndexState {
  const LibraryIndexState({
    required this.progress,
    required this.message,
    required this.phase,
    required this.unreadableTotal,
  });

  factory LibraryIndexState.fromNative(rust_tag_reader.IndexActionState value) {
    return LibraryIndexState(
      progress: value.progress,
      message: value.message,
      phase: switch (value.phase) {
        rust_tag_reader.IndexPhase.preparing => LibraryIndexPhase.preparing,
        rust_tag_reader.IndexPhase.scanning => LibraryIndexPhase.scanning,
        rust_tag_reader.IndexPhase.saving => LibraryIndexPhase.saving,
        rust_tag_reader.IndexPhase.complete => LibraryIndexPhase.complete,
      },
      unreadableTotal: value.unreadableTotal.toInt(),
    );
  }

  final double progress;
  final String message;
  final LibraryIndexPhase phase;
  final int unreadableTotal;
}

class LibraryIndexService {
  LibraryIndexService._();

  static final LibraryIndexService instance = LibraryIndexService._();

  Stream<LibraryIndexState> buildIndexFromFolders({
    required List<String> folders,
    required String indexPath,
  }) {
    return rust_tag_reader
        .buildIndexFromFoldersRecursively(
          folders: folders,
          indexPath: indexPath,
        )
        .map(LibraryIndexState.fromNative);
  }

  Stream<LibraryIndexState> updateIndex({
    required List<String> folders,
    required String indexPath,
    required bool forceMetadataCheck,
  }) {
    return rust_tag_reader
        .updateIndex(
          folders: folders,
          indexPath: indexPath,
          forceMetadataCheck: forceMetadataCheck,
        )
        .map(LibraryIndexState.fromNative);
  }
}
