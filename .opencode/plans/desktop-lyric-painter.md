# 桌面歌词 CustomPainter 渲染器实现方案

## 问题

当前桌面歌词描边在高亮（已播放）字符上不显示。根本原因：渐变高亮用 `ShaderMask + BlendMode.srcIn`，描边一起被吃掉。

## 目标

- 描边始终可见（已播放、未播放、高亮中）
- 后续可扩展逐字上抬、缩放等动画
- 性能可控

## 架构

### 核心类

```
DesktopLyricPainter extends CustomPainter
├── 输入：歌词行数据 + 当前播放进度 + 样式配置
├── paint()：逐字符绘制
│   ├── 1. 遍历字符，计算每个字的 x/y/width/progress/yLift
│   ├── 2. 对齐处理（左/中/右）
│   ├── 3. 绘制：先描边层，再填色层
│   └── 4. 高亮渐变：用 clipRect 裁剪 + LinearGradient shader
└── shouldRepaint：监听 currentTimeListenable（复用主 app 的 ValueNotifier 模式）
```

### 绘制顺序（每个字符）

```
canvas.save()
  ├── 绘制描边（Paint..style = stroke, strokeWidth = N）
  ├── 绘制填色（Paint..style = fill）
  │   ├── 未播放：unplayedColor
  │   └── 已播放/高亮中：clipRect + LinearGradient shader
  └── 应用 yLift 偏移（逐字上抬时）
canvas.restore()
```

### 关键设计决策

#### 1. 描边方案：Paint.stroke vs Shadow

**推荐 Paint.stroke**，理由：
- 精确控制 strokeWidth（Shadow 的 blurRadius 是模糊半径，不是描边宽度）
- 描边在填色之前绘制，天然在文字下方
- 与主 app `LyricsLinePainter` 的 blur/foreground 模式一致，未来可复用
- 不需要 zerobit 那种双层 Stack hack

绘制方式：
```dart
// 描边层
final strokePaint = Paint()
  ..style = PaintingStyle.stroke
  ..strokeWidth = 1.5
  ..color = strokeColor;
tp.paint(canvas, offset); // 用 strokePaint 的 TextStyle foreground

// 填色层
tp.text = TextSpan(text: char, style: style.copyWith(foreground: fillPaint));
tp.paint(canvas, offset);
```

#### 2. 高亮渐变：clipRect + LinearGradient

复用主 app 的 sweep 方案（不用 ShaderMask/Stack）：
```dart
// 计算高亮推进位置 highlightR
// Pass 1: 全行绘制未播放色（含描边）
// Pass 2: clipRect(highlightR 左侧) + 绘制已播放色（含描边）
```

这样描边在 clipRect 内外都存在，不会被吃掉。

#### 3. 逐字上抬扩展

每个字符独立计算 `yLift`，在绘制时 `canvas.translate(0, yLift)`：
```dart
final liftPeak = -2.0; // 上抬像素
final yLift = Curves.easeOutCubic.transform(charProgress) * liftPeak;
canvas.translate(0, yLift);
```

### 数据结构

```dart
class DesktopCharInfo {
  final String char;
  final double x;
  final double y;
  final double width;
  final double charProgress; // 0.0 ~ 1.0
  final double yLift;        // 上抬偏移
  final int wordIndex;
}
```

### TextPainter 复用

复用主 app 的对象池模式：
```dart
static final _pool = <TextPainter>[];
static TextPainter obtain() => _pool.isNotEmpty ? _pool.removeLast() : TextPainter(textDirection: TextDirection.ltr);
static void recycle(TextPainter tp) { tp.text = null; if (_pool.length < 8) _pool.add(tp); }
```

### 字符测量缓存

```dart
static final _measureCache = <String, double>{}; // "$char|$fontSize|$fontWeight" → width
```

## 实现步骤

### Phase 1：基础 painter（解决描边问题）

1. 创建 `DesktopLyricPainter extends CustomPainter`
   - 输入：当前行文字 + words 列表 + currentTimeMs + 样式配置
   - 实现逐字符测量、布局、绘制
   - 描边：`Paint..style = PaintingStyle.stroke`
   - 填色：未播放/已播放两色
   - 高亮：clipRect + LinearGradient sweep

2. 创建 `DesktopLyricLineWidget`（StatefulWidget）
   - 包裹 `CustomPaint(painter: DesktopLyricPainter(...))`
   - 监听 `currentTimeListenable` 触发重绘

3. 替换现有桌面歌词文字渲染

### Phase 2：逐字上抬

4. 在 `DesktopCharInfo` 中加入 `yLift` 计算
5. 绘制时应用 `canvas.translate(0, yLift)`
6. 波浪感：相邻字的 `charProgress` 有启动偏移（stepRatio = 0.1）

### Phase 3：优化

7. TextPainter 对象池 + 字符测量缓存
8. `shouldRepaint` 精确判断（只在 currentTime 变化时重绘）
9. `RepaintBoundary` 隔离

## 性能预估

- 桌面歌词一两行，20-30 个字符
- 每帧：30 次 TextPainter.layout + 60 次 canvas 绘制（描边+填色）
- 主 app 的 `LyricsLinePainter` 处理整页歌词（几百字符）都能 60fps，桌面歌词这点量毫无压力
- 对象池 + 测量缓存进一步降低 GC 压力

## 窗口高度（pure-player-lyric）

当前 `main.dart` 默认高度 122px 只够两行（歌词+翻译）。三行（歌词+翻译+注音）需要约 138-180px。

需要修改：
- `main.dart:19` — `size: Size(800, 180)` （默认高度）
- `main.dart:25` — `minimumSize: Size(400, 120)` （最小高度，保证两行）
- `maximumSize: Size(2400, 600)` 已经够用，不用改

布局结构：顶部 40px（歌曲信息/操作栏）+ 间距 8px + 歌词区（每行约 fontSize*1.2）

## 参考

- 主 app 实现：`lib/page/now_playing_page/component/lyrics_line_painter.dart`
  - `_CharInfo` 数据结构
  - `_calcWordProgress` / `_calcLiftProgress` 进度计算
  - sweep 方案：clipRect + LinearGradient（行 1032-1132）
  - TextPainter 对象池（行 184-193）
- zerobit 参考：`github.com/Empty-57/zerobit_player_desktop_lyrics`
  - Shadow 描边方案（`lyrics_text_display_widget.dart`）
  - 双层 Stack 高亮方案（`desktop_lyrics_widget.dart` `_HighlightedWord`）
