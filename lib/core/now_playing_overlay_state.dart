import 'package:flutter/foundation.dart';

/// 播放页覆盖层完全展开时为 true；库页被盖住，背景图和布局都可以先卸掉。
final ValueNotifier<bool> nowPlayingOverlayShown = ValueNotifier<bool>(false);
