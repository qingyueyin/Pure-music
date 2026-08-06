import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_music/page/settings_page/create_issue.dart';

void main() {
  testWidgets('issue reporting is enabled and opens the issue page', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/settings',
      routes: <RouteBase>[
        GoRoute(
          path: '/settings',
          builder: (context, state) => const Scaffold(body: CreateIssueTile()),
          routes: <RouteBase>[
            GoRoute(
              path: 'issue',
              builder: (context, state) => const Text('issue-page'),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(enableIssueReporting, isTrue);
    expect(button.onPressed, isNotNull);

    await tester.tap(find.text('创建问题'));
    await tester.pumpAndSettle();
    expect(find.text('issue-page'), findsOneWidget);
  });
}
