import 'dart:collection';

class LyricWritePromptHistory {
  LyricWritePromptHistory({this.capacity = 500});

  final int capacity;
  final LinkedHashSet<String> _handledPaths = LinkedHashSet();

  bool shouldPrompt(String path) => !_handledPaths.contains(path);

  void markPromptShown(String path) => _markHandled(path);

  void markEmbeddedLyricFound(String path) => _markHandled(path);

  void markWriteFailed(String path) => _handledPaths.remove(path);

  void clear() => _handledPaths.clear();

  void _markHandled(String path) {
    _handledPaths.remove(path);
    _handledPaths.add(path);
    if (_handledPaths.length > capacity) {
      _handledPaths.remove(_handledPaths.first);
    }
  }
}
