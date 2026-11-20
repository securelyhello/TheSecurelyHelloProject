import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/l10n/app_localizations.dart';
import 'package:securelyhello/core/security/app_lock.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';
import 'package:securelyhello/features/security/lock_screen.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('pbkdf2 matches the RFC 7914 PBKDF2-HMAC-SHA256 vector', () {
    final out = pbkdf2(utf8.encode('passwd'), utf8.encode('salt'), 1, 64);
    expect(
        hex(out),
        '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc'
        '49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783');
  });

  group('AppLockService', () {
    late SecureKeyStore store;
    late AppLockService lock;

    setUp(() async {
      store = SecureKeyStore(storage: MemorySecretStorage());
      lock = AppLockService(store: store);
      await lock.init();
    });

    test('screenshots can be blocked per chat, and it is remembered', () async {
      expect(lock.isChatSecure('bob'), isFalse);
      await lock.setChatSecure('bob', true);
      await lock.setChatSecure('carol', true);
      await lock.setChatSecure('carol', false);
      final again = AppLockService(store: store);
      await again.init();
      expect(again.isChatSecure('bob'), isTrue);
      expect(again.isChatSecure('carol'), isFalse);
      await again.chatOpened('bob');
      await again.chatOpened(null);
    });

    test('off by default; PIN turns it on and is stored only as a hash', () async {
      expect(lock.enabled, isFalse);
      expect(lock.locked, isFalse);
      await lock.setPin('2468');
      expect(lock.enabled, isTrue);
      final raw = await store.readSetting('lock_hash');
      expect(raw, isNot(contains('2468')));

      final again = AppLockService(store: store);
      await again.init();
      expect(again.locked, isTrue, reason: 'a fresh start is locked');
      expect(await again.unlockWithPin('0000'), isFalse);
      expect(await again.unlockWithPin('2468'), isTrue);
      expect(again.locked, isFalse);
      expect(again.failures, 0);
    });

    test('wrong PINs back off after five tries', () async {
      await lock.setPin('2468');
      lock.lockNow();
      for (var i = 0; i < 5; i++) {
        expect(await lock.unlockWithPin('1111'), isFalse);
      }
      expect(lock.retryIn, greaterThan(const Duration(seconds: 25)));
      expect(await lock.unlockWithPin('2468'), isFalse, reason: 'refused while waiting');
    });

    test('erases after ten failures when asked to', () async {
      var wiped = false;
      lock.onWipe = () async => wiped = true;
      await lock.setPin('2468');
      await lock.setWipeOnFailures(true);
      await store.writeSetting('lock_failures', '9');
      final reloaded = AppLockService(store: store)..onWipe = lock.onWipe;
      await reloaded.init();
      expect(await reloaded.unlockWithPin('1111'), isFalse);
      expect(wiped, isTrue);
      expect(reloaded.enabled, isFalse);
    });

    test('the back-off survives a restart', () async {
      await lock.setPin('2468');
      await store.writeSetting('lock_failures', '6');
      final a = AppLockService(store: store);
      await a.init();
      expect(await a.unlockWithPin('0000'), isFalse);
      expect(a.retryIn, greaterThan(const Duration(seconds: 60)));
      final restarted = AppLockService(store: store);
      await restarted.init();
      expect(restarted.retryIn, greaterThan(const Duration(seconds: 60)),
          reason: 'restarting the app must not reset the wait');
      expect(await restarted.unlockWithPin('2468'), isFalse);
    });

    test('the wipe keeps the app locked and is finished after a restart', () async {
      final wipeStarted = Completer<void>();
      final release = Completer<void>();
      await lock.setPin('2468');
      await lock.setWipeOnFailures(true);
      await store.writeSetting('lock_failures', '9');
      final a = AppLockService(store: store)
        ..onWipe = () async {
          wipeStarted.complete();
          await release.future; // slow network, or the app gets killed here
        };
      await a.init();
      final attempt = a.unlockWithPin('0000');
      await wipeStarted.future;
      expect(a.locked, isTrue, reason: 'still locked while erasing');

      // Killed mid-wipe: the next start is locked and finishes the wipe.
      var resumed = false;
      final next = AppLockService(store: store)..onWipe = () async => resumed = true;
      await next.init();
      expect(next.locked, isTrue);
      await next.resumePendingWipe();
      expect(resumed, isTrue);
      expect(next.enabled, isFalse, reason: 'PIN forgotten only after the wipe');

      release.complete();
      await attempt;
    });

    test('locks after the background timeout and covers the screen', () async {
      await lock.setPin('2468');
      await lock.setTimeout(0);
      lock.onLifecycle(AppLifecycleState.paused);
      expect(lock.obscured, isTrue);
      expect(lock.locked, isTrue);
      await lock.unlockWithPin('2468');

      await lock.setTimeout(300);
      lock.onLifecycle(AppLifecycleState.inactive);
      lock.onLifecycle(AppLifecycleState.resumed);
      expect(lock.locked, isFalse, reason: 'back within 5 minutes');
      expect(lock.obscured, isFalse);
    });

    test('phones cover the screen as soon as the app is inactive', () {
      final phone = AppLockService(store: store, desktop: false);
      phone.onLifecycle(AppLifecycleState.inactive);
      expect(phone.obscured, isTrue, reason: 'the app switcher must show nothing');
      phone.onLifecycle(AppLifecycleState.resumed);
      expect(phone.obscured, isFalse);
    });

    test('an unfocused desktop window stays readable; a hidden one is covered', () {
      final desk = AppLockService(store: store, desktop: true);
      desk.onLifecycle(AppLifecycleState.inactive);
      expect(desk.obscured, isFalse, reason: 'inactive on desktop = lost focus, still on screen');
      desk.onLifecycle(AppLifecycleState.hidden);
      expect(desk.obscured, isTrue);
      desk.onLifecycle(AppLifecycleState.resumed);
      expect(desk.obscured, isFalse);
    });

    test('an unfocused desktop window still counts towards the lock timeout', () async {
      final desk = AppLockService(store: store, desktop: true);
      await desk.setPin('2468');
      await desk.setTimeout(0);
      desk.onLifecycle(AppLifecycleState.inactive);
      expect(desk.locked, isTrue);
    });

    test('disable forgets the PIN', () async {
      await lock.setPin('2468');
      await lock.disable();
      expect(await store.readSetting('lock_hash'), isNull);
      expect(lock.locked, isFalse);
    });
  });

  testWidgets('while locked the app is hidden from screen readers and the keyboard',
      (tester) async {
    final store = SecureKeyStore(storage: MemorySecretStorage());
    final setup = AppLockService(store: store);
    await tester.runAsync(() => setup.setPin('2468'));
    final lock = AppLockService(store: store);
    await tester.runAsync(lock.init);
    var sent = 0;
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: lock,
      child: MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        builder: (context, child) => AppLockGate(child: child!),
        home: Scaffold(
          body: Column(children: [
            const Text('SECRET CHAT TEXT'),
            ElevatedButton(onPressed: () => sent++, child: const Text('Send secret')),
          ]),
        ),
      ),
    ));
    expect(find.bySemanticsLabel('SECRET CHAT TEXT'), findsNothing);
    expect(find.bySemanticsLabel('Send secret'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sent, 0);
    handle.dispose();
  });

  testWidgets('the gate covers the app until the PIN is entered', (tester) async {
    final store = SecureKeyStore(storage: MemorySecretStorage());
    final setup = AppLockService(store: store);
    await tester.runAsync(() => setup.setPin('2468'));
    final lock = AppLockService(store: store);
    await tester.runAsync(lock.init);

    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: lock,
      child: MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        builder: (context, child) => AppLockGate(child: child!),
        home: const Scaffold(body: Text('secret chat')),
      ),
    ));
    expect(find.byType(LockScreen), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('lock-pin')), '2468');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('lock-unlock')));
      for (var i = 0; i < 50 && lock.locked; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    await tester.pump();
    expect(find.byType(LockScreen), findsNothing);
    expect(find.text('secret chat'), findsOneWidget);
  });
}
