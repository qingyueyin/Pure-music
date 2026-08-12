import 'dart:io';
import 'dart:math';

const _configuredProcessorBudget = int.fromEnvironment(
  'PURE_MUSIC_DART_PROCESSOR_BUDGET',
);

int resolveProcessorBudget({
  required int actualProcessors,
  int configuredProcessors = _configuredProcessorBudget,
}) {
  final available = max(1, actualProcessors);
  if (configuredProcessors <= 0) return available;
  return configuredProcessors.clamp(1, available).toInt();
}

int get applicationProcessorBudget =>
    resolveProcessorBudget(actualProcessors: Platform.numberOfProcessors);

int backgroundWorkerConcurrencyFor(int processorBudget) {
  final sharedBackgroundBudget = max(1, (processorBudget - 2) ~/ 2);
  return min(4, sharedBackgroundBudget);
}

int libraryObjectBatchSizeFor({
  required int processorBudget,
  required bool hasPlaybackSession,
}) {
  if (hasPlaybackSession) return 512;
  return processorBudget < 6 ? 1024 : 2048;
}

int libraryPagePreparationConcurrencyFor({
  required int processorBudget,
  required bool hasPlaybackSession,
}) {
  if (hasPlaybackSession) return 1;
  return min(3, max(1, processorBudget));
}

bool shouldDeferSecondaryPagePreparation({
  required int processorBudget,
  required bool initialLoad,
  required bool hasPlaybackSession,
}) => hasPlaybackSession || (initialLoad && processorBudget < 6);

Duration deferredSecondaryPagePreparationDelayFor({
  required int processorBudget,
  required bool hasPlaybackSession,
}) {
  if (hasPlaybackSession) return const Duration(milliseconds: 240);
  if (processorBudget < 6) return const Duration(milliseconds: 64);
  return Duration.zero;
}
