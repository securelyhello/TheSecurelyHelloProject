import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/features/contacts/widgets/invite_prompt.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';

// Regression: an incoming invite took over the whole phone screen. It must
// be a compact sheet that can be dismissed, with a square avatar.
void main() {
  Future<List<bool?>> open(WidgetTester t, {double textScale = 1}) async {
    t.view.physicalSize = const Size(412, 892);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final result = <bool?>[];
    await t.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => result.add(await showInviteSheet(
              context,
              userId: 'u1',
              name: 'Mira Kapoor with a really long display name that goes on',
              username: 'mira_kapoor',
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    return result;
  }

  final sheet = find.byKey(const ValueKey('invite-dialog'));

  for (final scale in [1.0, 1.3]) {
    testWidgets('is a compact sheet on a phone (text ×$scale)', (t) async {
      await open(t, textScale: scale);
      expect(sheet, findsOneWidget);
      final rect = t.getRect(sheet);
      expect(rect.height, lessThan(892 * 0.6), reason: 'must not cover the screen');
      expect(rect.bottom, closeTo(892, 1), reason: 'anchored to the bottom');
      final avatar = t.getSize(find.byType(AvatarWidget));
      expect(avatar.width, avatar.height, reason: 'avatar stays round');
      expect(avatar.width, lessThanOrEqualTo(64));
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('"Not now" dismisses it with false', (t) async {
    final result = await open(t);
    await t.tap(find.text('Not now'));
    await t.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(result, [false]);
  });

  testWidgets('tapping outside dismisses it', (t) async {
    final result = await open(t);
    await t.tapAt(const Offset(200, 40));
    await t.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(result, [null]);
  });

  testWidgets('accept returns true', (t) async {
    final result = await open(t);
    await t.tap(find.byKey(const ValueKey('invite-accept')));
    await t.pumpAndSettle();
    expect(result, [true]);
  });

  testWidgets('an avatar in a stretching slot stays square', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Center(
        child: SizedBox(
          width: 300,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: const [AvatarWidget(displayName: 'Ada L', seed: 'x')],
          ),
        ),
      ),
    ));
    final r = t.getSize(find.descendant(of: find.byType(AvatarWidget), matching: find.byType(Stack)));
    expect(r, const Size(44, 44));
  });
}
