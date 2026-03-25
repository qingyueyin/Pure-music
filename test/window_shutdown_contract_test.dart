import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('窗口关闭链会等待原生与订阅清理完成', () async {
    final playService =
        await File('lib/play_service/play_service.dart').readAsString();
    final playbackService =
        await File('lib/play_service/playback_service.dart').readAsString();
    final titleBar = await File('lib/component/title_bar.dart').readAsString();

    expect(playService, contains('Future<void> close() async {'));
    expect(playService, contains('await playbackService.close();'));

    expect(playbackService, contains('Future<void> close() async {'));
    expect(playbackService, contains('await _playerStateStreamSub.cancel();'));
    expect(playbackService, contains('await _positionStreamSub.cancel();'));
    expect(playbackService, isNot(contains('_smtcEventStreamSub.cancel()')));
    expect(playbackService, isNot(contains('_smtc.close()')));

    expect(
      titleBar,
      contains(
        "await _runShutdownStep('play_service_close', () => PlayService.instance.close());",
      ),
    );
    expect(titleBar, isNot(contains('.timeout(const Duration(seconds: 2))')));
  });
}
