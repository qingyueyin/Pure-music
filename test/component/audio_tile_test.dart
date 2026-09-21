import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/audio_tile.dart';

void main() {
  testWidgets(
    'leading slot keeps trailing content aligned for different index widths',
    (tester) async {
      Widget row({required String label, required Key trailKey}) {
        return Row(
          children: [
            AudioTileLeadingSlot(child: Text(label)),
            SizedBox(key: trailKey, width: 48, height: 48),
          ],
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                row(label: '03', trailKey: const Key('cover-03')),
                row(label: '13', trailKey: const Key('cover-13')),
                row(label: '20', trailKey: const Key('cover-20')),
                row(label: '1', trailKey: const Key('cover-1')),
                row(label: '100', trailKey: const Key('cover-100')),
              ],
            ),
          ),
        ),
      );

      final x03 = tester.getTopLeft(find.byKey(const Key('cover-03'))).dx;
      expect(tester.getTopLeft(find.byKey(const Key('cover-13'))).dx, x03);
      expect(tester.getTopLeft(find.byKey(const Key('cover-20'))).dx, x03);
      expect(tester.getTopLeft(find.byKey(const Key('cover-1'))).dx, x03);
      expect(tester.getTopLeft(find.byKey(const Key('cover-100'))).dx, x03);
    },
  );
}
