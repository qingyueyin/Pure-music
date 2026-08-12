import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/workload_policy.dart';

void main() {
  test('processor budget never exceeds available processors', () {
    expect(
      resolveProcessorBudget(actualProcessors: 16, configuredProcessors: 4),
      4,
    );
    expect(
      resolveProcessorBudget(actualProcessors: 4, configuredProcessors: 16),
      4,
    );
    expect(
      resolveProcessorBudget(actualProcessors: 16, configuredProcessors: 0),
      16,
    );
  });

  test('background work uses half of the shared processor budget', () {
    expect(backgroundWorkerConcurrencyFor(16), 4);
    expect(backgroundWorkerConcurrencyFor(8), 3);
    expect(backgroundWorkerConcurrencyFor(6), 2);
    expect(backgroundWorkerConcurrencyFor(4), 1);
    expect(backgroundWorkerConcurrencyFor(2), 1);
  });

  test(
    'library object batches yield more often for playback and low budgets',
    () {
      expect(
        libraryObjectBatchSizeFor(
          processorBudget: 16,
          hasPlaybackSession: true,
        ),
        512,
      );
      expect(
        libraryObjectBatchSizeFor(
          processorBudget: 4,
          hasPlaybackSession: false,
        ),
        1024,
      );
      expect(
        libraryObjectBatchSizeFor(
          processorBudget: 16,
          hasPlaybackSession: false,
        ),
        2048,
      );
    },
  );

  test('page work follows the shared budget and stays serial for playback', () {
    expect(
      libraryPagePreparationConcurrencyFor(
        processorBudget: 16,
        hasPlaybackSession: false,
      ),
      3,
    );
    expect(
      libraryPagePreparationConcurrencyFor(
        processorBudget: 8,
        hasPlaybackSession: false,
      ),
      3,
    );
    expect(
      libraryPagePreparationConcurrencyFor(
        processorBudget: 6,
        hasPlaybackSession: false,
      ),
      3,
    );
    expect(
      libraryPagePreparationConcurrencyFor(
        processorBudget: 4,
        hasPlaybackSession: false,
      ),
      3,
    );
    expect(
      libraryPagePreparationConcurrencyFor(
        processorBudget: 2,
        hasPlaybackSession: false,
      ),
      2,
    );
    expect(
      libraryPagePreparationConcurrencyFor(
        processorBudget: 1,
        hasPlaybackSession: false,
      ),
      1,
    );
    expect(
      libraryPagePreparationConcurrencyFor(
        processorBudget: 16,
        hasPlaybackSession: true,
      ),
      1,
    );
  });

  test('secondary pages leave the initial and playback critical paths', () {
    expect(
      shouldDeferSecondaryPagePreparation(
        processorBudget: 4,
        initialLoad: true,
        hasPlaybackSession: false,
      ),
      isTrue,
    );
    expect(
      shouldDeferSecondaryPagePreparation(
        processorBudget: 4,
        initialLoad: false,
        hasPlaybackSession: false,
      ),
      isFalse,
    );
    expect(
      shouldDeferSecondaryPagePreparation(
        processorBudget: 16,
        initialLoad: false,
        hasPlaybackSession: true,
      ),
      isTrue,
    );
  });

  test('deferred secondary pages give the foreground a short claim window', () {
    expect(
      deferredSecondaryPagePreparationDelayFor(
        processorBudget: 4,
        hasPlaybackSession: false,
      ),
      const Duration(milliseconds: 64),
    );
    expect(
      deferredSecondaryPagePreparationDelayFor(
        processorBudget: 16,
        hasPlaybackSession: true,
      ),
      const Duration(milliseconds: 240),
    );
    expect(
      deferredSecondaryPagePreparationDelayFor(
        processorBudget: 16,
        hasPlaybackSession: false,
      ),
      Duration.zero,
    );
  });
}
