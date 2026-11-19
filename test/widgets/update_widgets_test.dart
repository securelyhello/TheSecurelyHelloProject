import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/core/update/app_updater.dart';
import 'package:securelyhello/features/update/update_widgets.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';

void main() {
  final source = Uri.parse('https://securelyhello.thenn.in/download/latest.json');
  late List<String> calls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(AppUpdater.channel,
        (c) async {
      calls.add(c.method);
      return c.method == 'info' ? {'versionCode': 1, 'versionName': '1.0.0', 'certSha256': 'AA'} : null;
    });
  });

  Future<AppUpdater> updater({int min = 1}) async {
    final u = AppUpdater(
      client: MockClient((r) async => http.Response(
          jsonEncode({
            'versionCode': 2,
            'versionName': '1.1.0',
            'url': 'https://securelyhello.thenn.in/download/a.apk',
            'sha256': 'a' * 64,
            'minSupportedVersionCode': min,
            'notes': 'Stories and a new look.',
          }),
          200)),
      manifestUrl: source,
      enabled: true,
    );
    await u.check();
    return u;
  }

  Widget app(AppUpdater u, Widget home) => ChangeNotifierProvider<AppUpdater?>.value(
        value: u,
        child: MaterialApp(
          theme: AppTheme.dark,
          builder: (context, child) => UpdateGate(child: child!),
          home: home,
        ),
      );

  testWidgets('an available update is a card with the notes; it can be put off', (t) async {
    final u = await updater();
    await t.pumpWidget(app(u, const Scaffold(body: CustomScrollView(slivers: [UpdateCardSliver()]))));
    await t.pumpAndSettle();
    expect(find.text('Update available'), findsOneWidget);
    expect(find.textContaining('1.1.0'), findsWidgets);
    expect(find.text('Stories and a new look.'), findsOneWidget);
    expect(find.byKey(const ValueKey('update-blocking')), findsNothing, reason: 'not required');
    await t.tap(find.text('Later'));
    await t.pumpAndSettle();
    expect(find.text('Update available'), findsNothing);
  });

  testWidgets('a required update blocks the app', (t) async {
    final u = await updater(min: 2);
    await t.pumpWidget(app(u, const Scaffold(body: Text('the app'))));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('update-blocking')), findsOneWidget);
    expect(find.text('the app').hitTestable(), findsNothing);
    await t.tap(find.byKey(const ValueKey('update-now')));
    await t.pump();
    expect(u.busy || u.error != null, isTrue, reason: 'the download started');
  });

  testWidgets('the server minimum blocks too', (t) async {
    final u = await updater();
    await t.pumpWidget(app(u, const Scaffold(body: Text('the app'))));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('update-blocking')), findsNothing);
    u.serverMinimum = 2;
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('update-blocking')), findsOneWidget);
  });
}
