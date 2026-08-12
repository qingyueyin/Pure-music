import 'dart:isolate';
import 'dart:typed_data';

import 'package:pure_music/core/utils.dart';

const int _pageSortBatchSize = 4096;

final class PageSortControl {
  const PageSortControl({required this.isCurrent, required this.batchSize});

  final bool Function() isCurrent;
  final int Function() batchSize;
}

typedef PageSortPhaseObserver = void Function(String phase, Duration elapsed);

/// 诊断埋点：性能工具读取排序各阶段耗时；未安装观察者时零开销。
PageSortPhaseObserver? pageSortPhaseObserver;

int _batchSizeFor(PageSortControl? control) {
  final batchSize = control?.batchSize() ?? _pageSortBatchSize;
  return batchSize > 0 ? batchSize : _pageSortBatchSize;
}

Uint32List _naturalOrder(
  List<String> values,
  bool descending,
  bool reuseEqualKeys,
) {
  final indexes = Uint32List(values.length);
  for (var index = 0; index < indexes.length; index++) {
    indexes[index] = index;
  }
  sortNaturallyBy(
    indexes,
    (index) => values[index],
    descending: descending,
    reuseEqualKeys: reuseEqualKeys,
  );
  return indexes;
}

Uint32List _localeOrder(List<String> values, bool descending) {
  final indexes = Uint32List(values.length);
  for (var index = 0; index < indexes.length; index++) {
    indexes[index] = index;
  }
  if (descending) {
    indexes.sort((a, b) => values[b].localeCompareTo(values[a]));
  } else {
    indexes.sort((a, b) => values[a].localeCompareTo(values[b]));
  }
  return indexes;
}

Uint32List _integerOrder(List<int> values, bool descending) {
  final indexes = Uint32List(values.length);
  for (var index = 0; index < indexes.length; index++) {
    indexes[index] = index;
  }
  if (descending) {
    indexes.sort((a, b) => values[b].compareTo(values[a]));
  } else {
    indexes.sort((a, b) => values[a].compareTo(values[b]));
  }
  return indexes;
}

Future<List<String>?> _extractStringValues<T>(
  List<T> items,
  String Function(T item) valueOf,
  PageSortControl? control,
) async {
  if (control != null && !control.isCurrent()) return null;
  final stopwatch = Stopwatch()..start();
  try {
    final values = List<String>.filled(items.length, '', growable: false);
    var batchRemaining = _batchSizeFor(control);
    for (var index = 0; index < items.length; index++) {
      values[index] = valueOf(items[index]);
      batchRemaining--;
      if (batchRemaining == 0) {
        await Future<void>.delayed(Duration.zero);
        if (control != null && !control.isCurrent()) return null;
        batchRemaining = _batchSizeFor(control);
      }
    }
    return control == null || control.isCurrent() ? values : null;
  } finally {
    stopwatch.stop();
    pageSortPhaseObserver?.call('Extract', stopwatch.elapsed);
  }
}

Future<List<int>?> _extractIntegerValues<T>(
  List<T> items,
  int Function(T item) valueOf,
  PageSortControl? control,
) async {
  if (control != null && !control.isCurrent()) return null;
  final stopwatch = Stopwatch()..start();
  try {
    final values = List<int>.filled(items.length, 0, growable: false);
    var batchRemaining = _batchSizeFor(control);
    for (var index = 0; index < items.length; index++) {
      values[index] = valueOf(items[index]);
      batchRemaining--;
      if (batchRemaining == 0) {
        await Future<void>.delayed(Duration.zero);
        if (control != null && !control.isCurrent()) return null;
        batchRemaining = _batchSizeFor(control);
      }
    }
    return control == null || control.isCurrent() ? values : null;
  } finally {
    stopwatch.stop();
    pageSortPhaseObserver?.call('Extract', stopwatch.elapsed);
  }
}

Future<List<T>?> _materializeSortedItems<T>(
  List<T> items,
  Uint32List indexes,
  PageSortControl? control,
) async {
  if (control != null && !control.isCurrent()) return null;
  if (indexes.isEmpty) return <T>[];
  final stopwatch = Stopwatch()..start();
  try {
    final sorted = List<T>.filled(
      indexes.length,
      items[indexes.first],
      growable: false,
    );
    var batchRemaining = _batchSizeFor(control);
    for (var index = 1; index < indexes.length; index++) {
      sorted[index] = items[indexes[index]];
      batchRemaining--;
      if (batchRemaining == 0) {
        await Future<void>.delayed(Duration.zero);
        if (control != null && !control.isCurrent()) return null;
        batchRemaining = _batchSizeFor(control);
      }
    }
    return control == null || control.isCurrent() ? sorted : null;
  } finally {
    stopwatch.stop();
    pageSortPhaseObserver?.call('Materialize', stopwatch.elapsed);
  }
}

Future<List<T>?> sortPageNaturallyInBackground<T>(
  List<T> items,
  String Function(T item) valueOf, {
  required bool descending,
  bool reuseEqualKeys = false,
  PageSortControl? control,
}) async {
  final values = await _extractStringValues(items, valueOf, control);
  if (values == null) return null;
  final sortStopwatch = Stopwatch()..start();
  final indexes = await Isolate.run(
    () => _naturalOrder(values, descending, reuseEqualKeys),
  );
  sortStopwatch.stop();
  pageSortPhaseObserver?.call('BackgroundSort', sortStopwatch.elapsed);
  if (control != null && !control.isCurrent()) return null;
  return _materializeSortedItems(items, indexes, control);
}

Future<List<T>?> sortPageByLocaleInBackground<T>(
  List<T> items,
  String Function(T item) valueOf, {
  required bool descending,
  PageSortControl? control,
}) async {
  final values = await _extractStringValues(items, valueOf, control);
  if (values == null) return null;
  final sortStopwatch = Stopwatch()..start();
  final indexes = await Isolate.run(() => _localeOrder(values, descending));
  sortStopwatch.stop();
  pageSortPhaseObserver?.call('BackgroundSort', sortStopwatch.elapsed);
  if (control != null && !control.isCurrent()) return null;
  return _materializeSortedItems(items, indexes, control);
}

Future<List<T>?> sortPageByIntegerInBackground<T>(
  List<T> items,
  int Function(T item) valueOf, {
  required bool descending,
  PageSortControl? control,
}) async {
  final values = await _extractIntegerValues(items, valueOf, control);
  if (values == null) return null;
  final sortStopwatch = Stopwatch()..start();
  final indexes = await Isolate.run(() => _integerOrder(values, descending));
  sortStopwatch.stop();
  pageSortPhaseObserver?.call('BackgroundSort', sortStopwatch.elapsed);
  if (control != null && !control.isCurrent()) return null;
  return _materializeSortedItems(items, indexes, control);
}
