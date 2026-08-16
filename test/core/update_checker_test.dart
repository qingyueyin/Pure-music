import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/update_checker.dart';

void main() {
  test('compares stable semantic versions', () {
    expect(UpdateChecker.compareSemVer('v2.3.0', '2.2.10'), greaterThan(0));
    expect(UpdateChecker.compareSemVer('2.2.1+7', 'v2.2.1+8'), 0);
  });

  test('orders prerelease identifiers by semantic-version rules', () {
    expect(UpdateChecker.compareSemVer('2.2.1', '2.2.1-rc.1'), greaterThan(0));
    expect(
      UpdateChecker.compareSemVer('2.2.1-rc.10', '2.2.1-rc.2'),
      greaterThan(0),
    );
    expect(
      UpdateChecker.compareSemVer('2.2.1-beta', '2.2.1-1'),
      greaterThan(0),
    );
  });

  test('does not treat malformed tags as updates', () {
    expect(UpdateChecker.hasNewVersion('release-next', '2.2.1'), isFalse);
    final oversizedMajor = List.filled(100, '9').join();
    expect(
      UpdateChecker.hasNewVersion('$oversizedMajor.0.0', '2.2.1'),
      isFalse,
    );
  });
}
