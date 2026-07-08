import 'package:pure_music/core/enums.dart';

bool hasEnoughItemsToReorder(int itemCount) => itemCount > 1;

bool hasEnoughItemsToSort(int itemCount) => itemCount > 1;

bool canShowContentViewSwitch(int itemCount) => itemCount > 0;

bool canShowPlayAllAction(int itemCount) => itemCount > 0;

bool canShowRelatedContentTab(int itemCount) => itemCount > 0;

ContentView resolveContentViewAvailabilityChange({
  required ContentView currentView,
  required ContentView preferredView,
  required bool wasSwitchAvailable,
  required bool isSwitchAvailable,
}) {
  if (!wasSwitchAvailable && isSwitchAvailable) {
    return preferredView;
  }
  if (wasSwitchAvailable && !isSwitchAvailable) {
    return ContentView.table;
  }
  return currentView;
}

bool canSwitchTab({
  required int currentIndex,
  required int targetIndex,
}) =>
    currentIndex != targetIndex;

bool canOpenAddToPlaylistMenu({
  required bool hasSelectedAudios,
  required bool isAdding,
  required Iterable<int> addableCounts,
}) =>
    hasSelectedAudios && !isAdding && addableCounts.any((count) => count > 0);

bool canOpenSingleAudioAddToPlaylistMenu({
  required bool hasAudio,
  required bool isBusy,
  required Iterable<bool> alreadyInPlaylists,
}) =>
    hasAudio && !isBusy && alreadyInPlaylists.any((alreadyIn) => !alreadyIn);

bool canActivateQueueItem({
  required bool hasNowPlaying,
  required int currentIndex,
  required int targetIndex,
}) =>
    !hasNowPlaying || currentIndex != targetIndex;

bool canAddAudioToNext({
  required bool hasNowPlaying,
  required bool isPendingFeedback,
}) =>
    hasNowPlaying && !isPendingFeedback;

bool canStartSinglePlaylistRemoval({
  required bool hasRemoveAction,
  required bool isRemoving,
  required bool isAddingToPlaylist,
}) =>
    hasRemoveAction && !isRemoving && !isAddingToPlaylist;

final _playlistNameWhitespacePattern = RegExp(r'\s+');

String normalizedPlaylistName(String value) {
  return value
      .trim()
      .replaceAll(_playlistNameWhitespacePattern, ' ')
      .toLowerCase();
}

bool hasEquivalentPlaylistName({
  required Iterable<String> existingNames,
  required String targetName,
}) {
  final targetKey = normalizedPlaylistName(targetName);
  if (targetKey.isEmpty) return false;
  return existingNames.any((name) => normalizedPlaylistName(name) == targetKey);
}

bool canRemovePendingFolder({
  required bool isCommitting,
  required bool isPickingFolder,
}) =>
    !isCommitting && !isPickingFolder;

String pendingFolderKey(String value) {
  var normalized = value.trim().replaceAll('\\', '/');
  while (normalized.endsWith('/') && normalized.length > 1) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized.toLowerCase();
}

bool containsEquivalentFolderPath({
  required Iterable<String> paths,
  required String target,
}) {
  final targetKey = pendingFolderKey(target);
  if (targetKey.isEmpty) return false;
  return paths.any((path) => pendingFolderKey(path) == targetKey);
}

bool isFolderPathExcluded({
  required Iterable<String> excludedPaths,
  required String folderPath,
}) =>
    containsEquivalentFolderPath(paths: excludedPaths, target: folderPath);

List<String> folderPathKeys(Iterable<String> paths) {
  return paths.map(pendingFolderKey).where((key) => key.isNotEmpty).toList()
    ..sort();
}

List<String> appendUniquePendingFolders({
  required Iterable<String> current,
  required Iterable<String> incoming,
}) {
  final result = <String>[];
  final seen = <String>{};
  for (final path in current) {
    final key = pendingFolderKey(path);
    if (key.isEmpty || !seen.add(key)) continue;
    result.add(path);
  }
  for (final path in incoming) {
    final key = pendingFolderKey(path);
    if (key.isEmpty || !seen.add(key)) continue;
    result.add(path);
  }
  return result;
}

bool areAllContentItemsSelected<T>({
  required Iterable<T> contentList,
  required Set<T> selectedItems,
}) {
  var hasItem = false;
  for (final item in contentList) {
    hasItem = true;
    if (!selectedItems.contains(item)) return false;
  }
  return hasItem;
}
