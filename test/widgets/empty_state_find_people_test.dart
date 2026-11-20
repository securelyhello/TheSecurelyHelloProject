import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/l10n/app_localizations.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/empty_state.dart';

Widget _app(Widget child) => MaterialApp(
      theme: AppTheme.light,
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('no chats and no contacts: the action is Find people', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_app(EmptyStateWidget.noMessages(onAction: () => taps++, findPeople: true)));
    expect(find.widgetWithText(FilledButton, 'Find people'), findsOneWidget);
    expect(find.text('Start a chat'), findsNothing);
    expect(find.byIcon(LucideIcons.userSearch), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    expect(taps, 1);
  });

  testWidgets('no chats but contacts: the action stays Start a chat', (tester) async {
    await tester.pumpWidget(_app(EmptyStateWidget.noMessages(onAction: () {})));
    expect(find.widgetWithText(FilledButton, 'Start a chat'), findsOneWidget);
  });

  testWidgets('no action when no callback is given', (tester) async {
    await tester.pumpWidget(_app(EmptyStateWidget.noMessages()));
    expect(find.byType(FilledButton), findsNothing);
  });
}
