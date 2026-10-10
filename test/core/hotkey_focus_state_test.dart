import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/hotkey_focus_state.dart';

void main() {
  testWidgets('visible text field blocks in-app playback hotkeys', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TextField(autofocus: true))),
    );
    await tester.pump();

    expect(isTextInputFocusedForHotkeys(), isTrue);
    expect(
      canHandleInAppPlaybackHotkey(textInputFocused: true),
      isFalse,
    );
  });

  testWidgets('offstage leftover field does not block hotkeys', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(focusNode: node)),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(isTextInputFocusedForHotkeys(), isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Offstage(offstage: true, child: TextField(focusNode: node)),
        ),
      ),
    );
    await tester.pump();
    expect(isTextInputFocusedForHotkeys(), isFalse);
  });

  testWidgets('switching sidebar tabs drops the old page text focus', (
    tester,
  ) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    var index = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: [
                  TextButton(
                    onPressed: () => setState(() => index = 1),
                    child: const Text('go'),
                  ),
                  Expanded(
                    child: DirectionalTabView(
                      index: index,
                      children: [
                        TextField(focusNode: node),
                        const Text('other'),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(node.hasFocus, isTrue);
    expect(isTextInputFocusedForHotkeys(), isTrue);

    await tester.tap(find.text('go'));
    await tester.pump();
    expect(node.hasFocus, isFalse);
    expect(isTextInputFocusedForHotkeys(), isFalse);
  });
}
