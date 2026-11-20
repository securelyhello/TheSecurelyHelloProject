import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/features/home/chat_navigation.dart';
import 'package:securelyhello/features/home/home_screen.dart';
import 'package:securelyhello/l10n/app_localizations.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';

/// Loads the bundled fonts so label widths are real, not the test font's.
Future<void> _loadFonts() async {
  const files = {
    'Inter': ['Inter-Regular', 'Inter-Medium', 'Inter-SemiBold', 'Inter-Bold'],
    'Chillax': ['Chillax-Medium', 'Chillax-Semibold'],
    'PlusJakartaSans': ['PlusJakartaSans-Medium', 'PlusJakartaSans-SemiBold', 'PlusJakartaSans-Bold'],
  };
  for (final e in files.entries) {
    final loader = FontLoader(e.key);
    for (final f in e.value) {
      final file = File('assets/fonts/$f.ttf');
      if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }
}

Widget _app(
  Widget home, {
  Locale locale = const Locale('en'),
  double textScale = 1,
  Map<String, WidgetBuilder> routes = const {},
}) {
  return MaterialApp(
    theme: AppTheme.light,
    locale: locale,
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    routes: routes,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: home,
  );
}

class _FakeSelector implements HomeTabSelector {
  final picked = <HomeTab>[];
  @override
  void select(HomeTab tab) => picked.add(tab);
}

void main() {
  setUpAll(_loadFonts);

  group('HomeTab', () {
    test('order is Chats, Find people, Calls, Settings', () {
      expect(HomeTab.values, [HomeTab.chats, HomeTab.findPeople, HomeTab.calls, HomeTab.settings]);
    });
  });

  group('HomeNavigationBar', () {
    Future<void> pump(
      WidgetTester tester, {
      Locale locale = const Locale('en'),
      double textScale = 1,
      HomeTab selected = HomeTab.chats,
      ValueChanged<HomeTab>? onSelected,
      int unread = 0,
      int requests = 0,
      int missed = 0,
    }) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(
        Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: HomeNavigationBar(
            selected: selected,
            onSelected: onSelected ?? (_) {},
            unread: unread,
            requests: requests,
            missed: missed,
          ),
        ),
        locale: locale,
        textScale: textScale,
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('has four tabs with keys and the agreed icons', (tester) async {
      await pump(tester);
      for (final k in ['tab-chats', 'tab-find-people', 'tab-calls', 'tab-settings']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      expect(find.byType(NavigationDestination), findsNWidgets(4));
      for (final icon in [
        LucideIcons.messageCircle,
        LucideIcons.userSearch,
        LucideIcons.phone,
        LucideIcons.settings,
      ]) {
        expect(find.byIcon(icon), findsOneWidget);
      }
      expect(find.text('Chats'), findsOneWidget);
      expect(find.text('Find people'), findsOneWidget);
      expect(find.text('Calls'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('tapping a tab reports the HomeTab', (tester) async {
      final picked = <HomeTab>[];
      await pump(tester, onSelected: picked.add);
      await tester.tap(find.byKey(const ValueKey('tab-find-people')));
      await tester.tap(find.byKey(const ValueKey('tab-calls')));
      await tester.tap(find.byKey(const ValueKey('tab-settings')));
      await tester.tap(find.byKey(const ValueKey('tab-chats')));
      expect(picked, [HomeTab.findPeople, HomeTab.calls, HomeTab.settings, HomeTab.chats]);
    });

    testWidgets('the selected tab follows [selected]', (tester) async {
      await pump(tester, selected: HomeTab.findPeople);
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 1);
    });

    testWidgets('badges: Chats shows unread only, Find people shows requests, Calls shows missed',
        (tester) async {
      await pump(tester, unread: 3, requests: 2, missed: 5);
      Finder badgeIn(String key) => find.descendant(
          of: find.byKey(ValueKey(key)), matching: find.byType(Badge));
      Badge badge(String key) => tester.widget<Badge>(badgeIn(key));
      expect(badge('tab-chats').isLabelVisible, isTrue);
      expect(((badge('tab-chats').label) as Text).data, '3');
      expect(((badge('tab-find-people').label) as Text).data, '2');
      expect(((badge('tab-calls').label) as Text).data, '5');
      expect(badgeIn('tab-settings'), findsNothing);
    });

    testWidgets('no badge when the counts are zero', (tester) async {
      await pump(tester);
      for (final k in ['tab-chats', 'tab-find-people', 'tab-calls']) {
        final b = tester.widget<Badge>(find.descendant(
            of: find.byKey(ValueKey(k)), matching: find.byType(Badge)));
        expect(b.isLabelVisible, isFalse, reason: k);
      }
    });

    testWidgets('large counts read 99+', (tester) async {
      await pump(tester, requests: 150);
      final b = tester.widget<Badge>(find.descendant(
          of: find.byKey(const ValueKey('tab-find-people')), matching: find.byType(Badge)));
      expect((b.label as Text).data, '99+');
    });

    for (final code in ['en', 'hi', 'gu']) {
      testWidgets('360dp, text scale 1.3, $code: four labels, no overflow', (tester) async {
        await pump(tester, locale: Locale(code), textScale: 1.3, requests: 12, unread: 120, missed: 4);
        expect(tester.takeException(), isNull);
        final l = lookupL10n(Locale(code));
        final labels = [l.tabChats, l.tabFindPeople, l.tabCalls, l.tabSettings];
        for (final label in labels) {
          final finder = find.text(label);
          expect(finder, findsOneWidget, reason: '"$label" in $code');
          final p = tester.renderObject<RenderParagraph>(finder);
          expect(p.didExceedMaxLines, isFalse, reason: '"$label" is cut off in $code');
          final fontSize = p.text.style?.fontSize ?? 12;
          expect(p.size.height, lessThan(fontSize * 1.3 * 2),
              reason: '"$label" wraps onto a second line in $code');
          // Each label stays inside the bar's width.
          final r = tester.getRect(finder);
          expect(r.left, greaterThanOrEqualTo(0));
          expect(r.right, lessThanOrEqualTo(360));
        }
        // Four equal-width destinations share the 360dp bar.
        final widths = [
          for (final k in ['tab-chats', 'tab-find-people', 'tab-calls', 'tab-settings'])
            tester.getSize(find.byKey(ValueKey(k))).width
        ];
        expect(widths.reduce((a, b) => a + b), lessThanOrEqualTo(360.5));
      });
    }

    testWidgets('narrow label also holds at 320dp in English', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(
        Scaffold(
          bottomNavigationBar: HomeNavigationBar(selected: HomeTab.chats, onSelected: (_) {}),
        ),
        textScale: 1.3,
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('HomeTabScope', () {
    testWidgets('maybeOf is null outside the home shell', (tester) async {
      HomeTabSelector? found = _FakeSelector();
      await tester.pumpWidget(_app(Builder(builder: (context) {
        found = HomeTabScope.maybeOf(context);
        return const SizedBox();
      })));
      expect(found, isNull);
    });

    testWidgets('an ancestor scope selects the tab', (tester) async {
      final fake = _FakeSelector();
      late BuildContext inner;
      await tester.pumpWidget(_app(HomeTabScope(
        current: HomeTab.chats,
        onSelect: fake.select,
        child: Builder(builder: (context) {
          inner = context;
          return const SizedBox();
        }),
      )));
      HomeTabScope.maybeOf(inner)!.select(HomeTab.findPeople);
      expect(fake.picked, [HomeTab.findPeople]);
    });

    testWidgets('a registered shell is found from a route pushed above it', (tester) async {
      final fake = _FakeSelector();
      HomeTabScope.attach(fake);
      addTearDown(() => HomeTabScope.detach(fake));
      HomeTabSelector? found;
      await tester.pumpWidget(_app(Builder(builder: (context) {
        found = HomeTabScope.maybeOf(context);
        return const SizedBox();
      })));
      expect(found, same(fake));
      HomeTabScope.detach(fake);
      await tester.pumpWidget(_app(Builder(builder: (context) {
        found = HomeTabScope.maybeOf(context);
        return const SizedBox();
      }), textScale: 1.1));
      expect(found, isNull);
    });

    testWidgets('detach ignores a selector that is no longer the active one', (tester) async {
      final a = _FakeSelector();
      final b = _FakeSelector();
      HomeTabScope.attach(a);
      HomeTabScope.attach(b);
      HomeTabScope.detach(a);
      addTearDown(() => HomeTabScope.detach(b));
      HomeTabSelector? found;
      await tester.pumpWidget(_app(Builder(builder: (context) {
        found = HomeTabScope.maybeOf(context);
        return const SizedBox();
      })));
      expect(found, same(b));
    });
  });

  group('openFindPeople', () {
    testWidgets('inside the shell it switches tab and pushes nothing', (tester) async {
      final fake = _FakeSelector();
      var pushed = false;
      await tester.pumpWidget(_app(
        HomeTabScope(
          current: HomeTab.chats,
          onSelect: fake.select,
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => openFindPeople(context),
              child: const Text('go'),
            ),
          ),
        ),
        routes: {'/add-contact': (_) {
          pushed = true;
          return const Text('add-contact route');
        }},
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(fake.picked, [HomeTab.findPeople]);
      expect(pushed, isFalse);
    });

    testWidgets('outside the shell it falls back to /add-contact', (tester) async {
      await tester.pumpWidget(_app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => openFindPeople(context),
            child: const Text('go'),
          ),
        ),
        routes: {'/add-contact': (_) => const Text('add-contact route')},
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('add-contact route'), findsOneWidget);
    });
  });

  group('l10n', () {
    test('tabFindPeople exists in en, hi and gu', () {
      expect(lookupL10n(const Locale('en')).tabFindPeople, 'Find people');
      for (final code in ['hi', 'gu']) {
        final s = lookupL10n(Locale(code)).tabFindPeople;
        expect(s.trim(), isNotEmpty);
        expect(s, isNot('Find people'));
        expect(s.runes.length, lessThanOrEqualTo(10), reason: 'tab labels stay short in $code');
      }
    });
  });
}
