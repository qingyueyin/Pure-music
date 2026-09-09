const kHangulFallbackFontFamily = 'Pretendard Variable';

List<String> appFontFamilyFallback([String? primary]) {
  if (primary == kHangulFallbackFontFamily) return const [];
  return const [kHangulFallbackFontFamily];
}
