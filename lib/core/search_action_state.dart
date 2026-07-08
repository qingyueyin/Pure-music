final _searchWhitespacePattern = RegExp(r'\s+');

String normalizedSearchQuery(String value) =>
    value.trim().replaceAll(_searchWhitespacePattern, '');

bool canSubmitChangedSearchQuery({
  required String currentQuery,
  required String nextQuery,
}) {
  final normalizedCurrent = normalizedSearchQuery(currentQuery);
  final normalizedNext = normalizedSearchQuery(nextQuery);
  return normalizedNext.isNotEmpty && normalizedNext != normalizedCurrent;
}

bool canShowSearchClearAction(String value) =>
    normalizedSearchQuery(value).isNotEmpty;
