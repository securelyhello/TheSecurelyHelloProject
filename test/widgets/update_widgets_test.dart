import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/core/config/app_version.dart';
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

  Map<String, Object?> manifest({int code = 99, Object? size}) => {
        'versionCode': code,
        'versionName': '9.9.9',
        'url': 'https://securelyhello.thenn.in/download/a.apk',
        'sha256': 'a' * 64,
        'minSupportedVersionCode': 1,
        'notes': 'Stories and a new look.',
        if (size != null) 'size': size,
      };

  /// An updater for the settings section; [fetches] counts manifest requests.
  AppUpdater sectionUpdater({
    int status = 200,
    Map<String, Object?>? body,
    Future<void>? gate,
    bool enabled = true,
    void Function()? onFetch,
  }) =>
      AppUpdater(
        client: MockClient((r) async {
          onFetch?.call();
          if (gate != null) await gate;
          return http.Response(jsonEncode(body ?? manifest()), status);
        }),
        manifestUrl: source,
        enabled: enabled,
      );

  Widget section(AppUpdater? u, {String distribution = ''}) => ChangeNotifierProvider<AppUpdater?>.value(
        value: u,
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(body: SingleChildScrollView(child: AppUpdatesSection(distribution: distribution))),
        ),
      );

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

  // Security review M4.
  testWidgets('a minimum no published build meets warns without blocking', (t) async {
    final u = await updater();
    await t.pumpWidget(app(u, const Scaffold(body: CustomScrollView(slivers: [UpdateCardSliver()]))));
    await t.pumpAndSettle();
    u.serverMinimum = 3; // the manifest offers versionCode 2
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('update-blocking')), findsNothing);
    expect(find.byKey(const ValueKey('update-unsupported')), findsOneWidget);
    expect(find.text('This version is no longer supported'), findsOneWidget);
  });

  group('AppUpdatesSection (Settings)', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(AppUpdater.channel,
          (c) async {
        calls.add(c.method);
        return c.method == 'info'
            ? {'versionCode': AppVersion.code, 'versionName': AppVersion.name, 'certSha256': 'AA'}
            : null;
      });
    });

    testWidgets('shows this build\'s version and build number', (t) async {
      final u = sectionUpdater();
      await t.pumpWidget(section(u));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-version')), findsOneWidget);
      expect(find.text('Securely Hello ${AppVersion.name}'), findsOneWidget);
      expect(find.text('Build ${AppVersion.code}'), findsOneWidget);
      expect(find.textContaining('1.0.0'), findsNothing, reason: 'never the old hard-coded version');
    });

    testWidgets('before the first check it says so, and offers the check', (t) async {
      final u = sectionUpdater();
      await t.pumpWidget(section(u));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-status')), findsOneWidget);
      expect(find.text('Not checked yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('update-check')), findsOneWidget);
      expect(find.text('Check for updates'), findsOneWidget);
    });

    testWidgets('up to date, with when it last looked', (t) async {
      SharedPreferences.setMockInitialValues({});
      final u = sectionUpdater(body: manifest(code: AppVersion.code));
      await t.runAsync(u.check);
      await t.pumpWidget(section(u));
      await t.pumpAndSettle();
      expect(find.text("You're up to date \u00b7 checked just now"), findsOneWidget);
      expect(find.byKey(const ValueKey('update-now')), findsNothing);
    });

    testWidgets('up to date: how long ago, in plain words', (t) async {
      final threeHours = DateTime.now().subtract(const Duration(hours: 3)).millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({'update_last_check': threeHours});
      final u = sectionUpdater(body: manifest(code: AppVersion.code));
      await t.runAsync(u.check);
      await t.pumpWidget(section(u));
      await t.pumpAndSettle();
      expect(find.text("You're up to date \u00b7 checked 3 hours ago"), findsOneWidget);
    });

    testWidgets('tapping Check for updates forces a request even inside the 12 hours', (t) async {
      var fetches = 0;
      final u = sectionUpdater(onFetch: () => fetches++);
      await t.runAsync(u.check);
      expect(fetches, 1);
      await t.runAsync(u.check);
      expect(fetches, 1, reason: 'a normal check waits 12 hours');
      await t.pumpWidget(section(u));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const ValueKey('update-check')));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pumpAndSettle();
      expect(fetches, 2, reason: 'the button forces the check');
    });

    testWidgets('while checking: Checking... and the button is off', (t) async {
      final gate = Completer<void>();
      final u = sectionUpdater(gate: gate.future);
      await t.pumpWidget(section(u));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('update-check')));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump();
      expect(find.text('Checking\u2026'), findsOneWidget);
      expect(t.widget<ButtonStyleButton>(find.byKey(const ValueKey('update-check'))).onPressed, isNull);

      gate.complete();
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pumpAndSettle();
      expect(find.text('Checking\u2026'), findsNothing);
      expect(t.widget<ButtonStyleButton>(find.byKey(const ValueKey('update-check'))).onPressed, isNotNull);
    });

    testWidgets('an update with its size, notes and the update button', (t) async {
      final u = sectionUpdater(body: manifest(size: 90 * 1024 * 1024));
      await t.runAsync(u.check);
      await t.pumpWidget(section(u));
      await t.pumpAndSettle();
      expect(find.text('Version 9.9.9 is ready \u00b7 90.0 MB'), findsOneWidget);
      expect(find.text('Stories and a new look.'), findsOneWidget);
      expect(find.byKey(const ValueKey('update-now')), findsOneWidget);
      expect(find.text('Later'), findsNothing, reason: 'the card\'s "Later" is not part of Settings');
    });

    testWidgets('an update without a size just leaves the size out', (t) async {
      final u = sectionUpdater();
      await t.runAsync(u.check);
      await t.pumpWidget(section(u));
      await t.pumpAndSettle();
      expect(find.text('Version 9.9.9 is ready'), findsOneWidget);
    });

    testWidgets('shows the update even after "Later" was tapped on the chat card', (t) async {
      SharedPreferences.setMockInitialValues({'update_dismissed_version': 2});
      final u = sectionUpdater();
      await t.runAsync(u.check);
      await t.pumpWidget(section(u));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-now')), findsOneWidget);
    });

    testWidgets("a failed check: Couldn't check", (t) async {
      final u = sectionUpdater(status: 500);
      await t.runAsync(u.check);
      await t.pumpWidget(section(u));
      await t.pumpAndSettle();
      expect(find.text("Couldn't check \u2014 check your connection"), findsOneWidget);
      expect(find.byKey(const ValueKey('update-check')), findsOneWidget, reason: 'and you can try again');
    });

    testWidgets('an install problem is shown under the update', (t) async {
      final u = sectionUpdater();
      await t.runAsync(u.check);
      await t.pumpWidget(section(u));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('update-now')));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.pumpAndSettle();
      expect(u.error, isNotNull);
      expect(find.text(UpdateActions.message(u.error!)), findsOneWidget);
    });

    testWidgets('a build below the minimum with an update says so', (t) async {
      final u = sectionUpdater(body: {...manifest(code: AppVersion.code + 1), 'minSupportedVersionCode': AppVersion.code + 1});
      await t.runAsync(u.check);
      await t.pumpWidget(section(u));
      await t.pumpAndSettle();
      expect(find.textContaining('no longer supported'), findsWidgets);
      expect(find.byKey(const ValueKey('update-now')), findsOneWidget);
    });

    testWidgets('a minimum no published build meets: warning, no update button', (t) async {
      final u = sectionUpdater(body: manifest(code: AppVersion.code));
      await t.runAsync(u.check);
      u.serverMinimum = AppVersion.code + 5;
      await t.pumpWidget(section(u));
      await t.pumpAndSettle();
      expect(find.textContaining('no longer supported'), findsWidgets);
      expect(find.byKey(const ValueKey('update-now')), findsNothing);
    });

    testWidgets('Play builds: the version, and that Play does the updating', (t) async {
      final u = sectionUpdater(enabled: false);
      await t.pumpWidget(section(u, distribution: 'play'));
      await t.pumpAndSettle();
      expect(find.text('Securely Hello ${AppVersion.name}'), findsOneWidget);
      expect(find.text('Updates come from Google Play'), findsOneWidget);
      expect(find.byKey(const ValueKey('update-check')), findsNothing);
      expect(find.byKey(const ValueKey('update-status')), findsNothing);
    });

    testWidgets('desktop (no updater): the version and where to get new ones', (t) async {
      await t.pumpWidget(section(null));
      await t.pumpAndSettle();
      expect(find.text('Securely Hello ${AppVersion.name}'), findsOneWidget);
      expect(find.text('Get new versions at securelyhello.thenn.in'), findsOneWidget);
      expect(find.byKey(const ValueKey('update-check')), findsNothing);
    });

    testWidgets('no overflow at 360dp with large text', (t) async {
      t.view.physicalSize = const Size(360, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final u = sectionUpdater(body: manifest(size: 90 * 1024 * 1024));
      await t.runAsync(u.check);
      await t.pumpWidget(MediaQuery(
        data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(1.3)),
        child: section(u),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  });
}
