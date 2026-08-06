import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_source_view.dart';

class _FakeHotKeyManager extends HotKeyManagerPlatform {
  @override
  Stream<Map<Object?, Object?>> get onKeyEventReceiver => const Stream.empty();

  @override
  Future<void> register(HotKey hotKey) async {}

  @override
  Future<void> unregister(HotKey hotKey) async {}

  @override
  Future<void> unregisterAll() async {}
}

void main() {
  setUpAll(() {
    HotKeyManagerPlatform.instance = _FakeHotKeyManager();
  });

  Audio makeAudio() => Audio(
        'Test Song',
        'Test Artist',
        'Test Album',
        null,
        1,
        240,
        240,
        44100,
        'C:/music/test.mp3',
        0,
        0,
        null,
      );

  Future<void> pumpDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: ManualLyricSearchDialog(audio: makeAudio())),
        ),
      ),
    );
  }

  /// 轮询等待搜索结束（spinner 消失），最多 45 秒
  Future<void> waitSearchDone(WidgetTester tester) async {
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 250));
      if (tester.widgetList(find.byType(CircularProgressIndicator)).isEmpty) {
        return;
      }
    }
    fail('搜索在 45 秒内未完成，spinner 一直存在');
  }

  testWidgets('修改关键词后点击搜索必须重新进入搜索状态', (tester) async {
    await pumpDialog(tester);
    // 首次自动搜索完成（结果区 spinner 消失）
    await waitSearchDone(tester);

    // 修改输入框文本后点击搜索按钮
    await tester.enterText(find.byType(TextField), '不同关键词');
    await tester.pump();
    await tester.tap(find.byTooltip('搜索'));
    await tester.pump();

    // 核心断言：点击后必须重新进入搜索状态（spinner 出现）
    // 复现窗口：若点击无反应，此处 findsNothing
    expect(
      find.byType(CircularProgressIndicator),
      findsWidgets,
      reason: '点击搜索后应进入加载状态，而不是无反应',
    );

    // 搜索最终应结束（spinner 消失），不能一直转圈
    await waitSearchDone(tester);
  });

  testWidgets('切换来源 tab 应触发搜索且最终结束，不能一直转圈', (tester) async {
    await pumpDialog(tester);
    await waitSearchDone(tester);

    // 点击“网易”tab 切换来源
    await tester.tap(find.text('网易'));
    await tester.pump();

    expect(
      find.byType(CircularProgressIndicator),
      findsWidgets,
      reason: '切换来源后应立即进入搜索状态',
    );

    await waitSearchDone(tester);
  });
}