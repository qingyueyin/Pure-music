import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 从封面字节里取调色板。
///
/// 本地曲目走 Rust 的 `getPictureAndColors`（按文件路径读 + k-means 取色），
/// 远程曲目没有真实文件路径，只能拿已经下载好的封面字节，在这里做一次
/// 轻量的颜色量化。算法不同，主色会和本地略有差异，但足以撑起播放页的渐变背景
/// —— 总比一片黑好。
Future<List<int>> extractCoverPalette(
  Uint8List bytes, {
  int numColors = 8,
}) async {
  if (bytes.isEmpty) return const <int>[];
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(bytes, targetWidth: 64, targetHeight: 64);
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return const <int>[];
    return _quantize(data.buffer.asUint8List(), numColors);
  } catch (_) {
    return const <int>[];
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

/// 4 bit/通道分桶后按占比排序，差不多就是主色序列。
List<int> _quantize(Uint8List rgba, int numColors) {
  final buckets = <int, List<int>>{};
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 128) continue;
    final r = rgba[i];
    final g = rgba[i + 1];
    final b = rgba[i + 2];
    final maxChannel = math.max(r, math.max(g, b));
    final minChannel = math.min(r, math.min(g, b));
    // 太暗的像素会把背景压成黑；接近纯白的没有色彩信息。
    if (maxChannel < 30) continue;
    if (maxChannel > 236 && maxChannel - minChannel < 12) continue;
    final key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
    final bucket = buckets.putIfAbsent(key, () => <int>[0, 0, 0, 0]);
    bucket[0]++;
    bucket[1] += r;
    bucket[2] += g;
    bucket[3] += b;
  }
  if (buckets.isEmpty) return const <int>[];
  final ordered = buckets.values.toList()
    ..sort((a, b) => b[0].compareTo(a[0]));

  final colors = <int>[];
  for (final bucket in ordered) {
    if (colors.length >= numColors) break;
    final count = bucket[0];
    if (count == 0) continue;
    final r = bucket[1] ~/ count;
    final g = bucket[2] ~/ count;
    final b = bucket[3] ~/ count;
    // 和已选颜色太近的丢弃，否则渐变会糊成一片。
    if (colors.any((value) => _distance(value, r, g, b) < 26)) continue;
    colors.add(0xFF000000 | (r << 16) | (g << 8) | b);
  }
  return colors;
}

double _distance(int argb, int r, int g, int b) {
  final dr = ((argb >> 16) & 0xFF) - r;
  final dg = ((argb >> 8) & 0xFF) - g;
  final db = (argb & 0xFF) - b;
  return math.sqrt((dr * dr + dg * dg + db * db).toDouble());
}
