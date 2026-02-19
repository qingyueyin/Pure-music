import 'package:pure_music/native/bass/bass_player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('exclusive mode is blocked when EQ is enabled', (tester) async {
    final player = BassPlayer();

    player.setEQ(0, 3.0);
    final blocked = player.useExclusiveMode(true);
    expect(blocked, isFalse);

    player.setEQ(0, 0.0);
    final allowed = player.useExclusiveMode(true);
    expect(allowed, isTrue);
  });
}

