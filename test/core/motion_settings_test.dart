import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/settings.dart';

void main() {
  tearDown(() async {
    await AppSettings.readFromSettingsMapForTest({
      'Version': 'test',
      'EnableStackedScrollEffect': true,
    });
  });

  test('motion settings default to enabled', () async {
    await AppSettings.readFromSettingsMapForTest({'Version': 'test'});

    expect(AppSettings.instance.enableStackedScrollEffect, isTrue);
    expect(AppSettings.instance.enableContentTransitionMotion, isTrue);
    expect(AppSettings.instance.enableInteractiveSurfaceMotion, isTrue);
    expect(AppSettings.instance.enableDetailHeaderCollapseMotion, isTrue);
    expect(AppSettings.instance.enableDataTransitionMotion, isTrue);
  });

  test('legacy scroll setting migrates related motion settings', () async {
    await AppSettings.readFromSettingsMapForTest({
      'Version': 'test',
      'EnableStackedScrollEffect': false,
    });

    expect(AppSettings.instance.enableStackedScrollEffect, isFalse);
    expect(AppSettings.instance.enableContentTransitionMotion, isTrue);
    expect(AppSettings.instance.enableInteractiveSurfaceMotion, isFalse);
    expect(AppSettings.instance.enableDetailHeaderCollapseMotion, isFalse);
    expect(AppSettings.instance.enableDataTransitionMotion, isFalse);
  });

  test('explicit motion settings override legacy fallback', () async {
    await AppSettings.readFromSettingsMapForTest({
      'Version': 'test',
      'EnableStackedScrollEffect': false,
      'EnableContentTransitionMotion': false,
      'EnableInteractiveSurfaceMotion': true,
      'EnableDetailHeaderCollapseMotion': true,
      'EnableDataTransitionMotion': true,
    });

    expect(AppSettings.instance.enableContentTransitionMotion, isFalse);
    expect(AppSettings.instance.enableInteractiveSurfaceMotion, isTrue);
    expect(AppSettings.instance.enableDetailHeaderCollapseMotion, isTrue);
    expect(AppSettings.instance.enableDataTransitionMotion, isTrue);
  });
}
