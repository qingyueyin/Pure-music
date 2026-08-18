import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/rectangle_progress_indicator.dart';

void main() {
  group('ProgressDragController', () {
    test('无正在播放（identity 为 null）时不允许开始拖拽', () {
      final controller = ProgressDragController();
      expect(controller.begin(audioIdentity: null), isFalse);
      expect(controller.isDragging, isFalse);
    });

    test('有正在播放时可以开始拖拽', () {
      final controller = ProgressDragController();
      expect(controller.begin(audioIdentity: 'a.mp3'), isTrue);
      expect(controller.isDragging, isTrue);
    });

    test('结束拖拽且歌曲一致时返回 true（应执行 seek）', () {
      final controller = ProgressDragController();
      controller.begin(audioIdentity: 'a.mp3');
      expect(
        controller.end(currentIdentity: 'a.mp3', applySeek: true),
        isTrue,
      );
      expect(controller.isDragging, isFalse);
    });

    test('取消拖拽（applySeek=false）返回 false（不执行 seek）', () {
      final controller = ProgressDragController();
      controller.begin(audioIdentity: 'a.mp3');
      expect(
        controller.end(currentIdentity: 'a.mp3', applySeek: false),
        isFalse,
      );
      expect(controller.isDragging, isFalse);
    });

    test('歌曲变化后结束拖拽返回 false（不 seek 到错误歌曲）', () {
      final controller = ProgressDragController();
      controller.begin(audioIdentity: 'a.mp3');
      expect(
        controller.end(currentIdentity: 'b.mp3', applySeek: true),
        isFalse,
      );
    });

    test('未开始拖拽时结束返回 false', () {
      final controller = ProgressDragController();
      expect(
        controller.end(currentIdentity: 'a.mp3', applySeek: true),
        isFalse,
      );
    });

    test('切歌时取消拖拽，之后结束不再 seek', () {
      final controller = ProgressDragController();
      controller.begin(audioIdentity: 'a.mp3');
      controller.cancelOnTrackChange();
      expect(controller.isDragging, isFalse);
      expect(
        controller.end(currentIdentity: 'a.mp3', applySeek: true),
        isFalse,
      );
    });

    test('拖拽结束后可再次开始', () {
      final controller = ProgressDragController();
      controller.begin(audioIdentity: 'a.mp3');
      controller.end(currentIdentity: 'a.mp3', applySeek: true);
      expect(controller.begin(audioIdentity: 'b.mp3'), isTrue);
    });
  });
}
