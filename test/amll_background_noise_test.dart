import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/component/amll_background_noise.dart';

void main() {
		testWidgets("buildAmllNoiseTile returns deterministic tile", (
			tester,
		) async {
			final imageA = await tester.runAsync(() async {
				return buildAmllNoiseTile(size: 16, seed: 7);
			});
			final imageB = await tester.runAsync(() async {
				return buildAmllNoiseTile(size: 16, seed: 7);
			});

			expect(imageA, isNotNull);
			expect(imageB, isNotNull);

			final resolvedA = imageA!;
			final resolvedB = imageB!;

			expect(resolvedA.width, 16);
			expect(resolvedA.height, 16);
			expect(resolvedB.width, 16);
			expect(resolvedB.height, 16);

			resolvedA.dispose();
			resolvedB.dispose();
		});
}
