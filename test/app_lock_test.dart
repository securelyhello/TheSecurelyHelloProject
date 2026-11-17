import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

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

    test('disable forgets the PIN', () async {
      await lock.setPin('2468');
      await lock.disable();
      expect(await store.readSetting('lock_hash'), isNull);
      expect(lock.locked, isFalse);
    });
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
