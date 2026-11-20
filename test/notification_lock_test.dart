import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/notifications/notification_actions.dart';
import 'package:securelyhello/core/notifications/notification_service.dart';

// Security review L3: with App Lock on, Reply and Mark-as-read from a
// notification don't run until the app is unlocked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const reply = NotificationAction(NotificationActionKind.reply, 'bob', 'on my way');
  const read = NotificationAction(NotificationActionKind.markRead, 'bob');
  const decline = NotificationAction(NotificationActionKind.declineCall, 'call1');

  group('headless', () {
    test('reply and mark-read run headless only while App Lock is off', () {
      expect(headlessAllowed(reply, appLockEnabled: false), isTrue);
      expect(headlessAllowed(read, appLockEnabled: false), isTrue);
      expect(headlessAllowed(reply, appLockEnabled: true), isFalse);
      expect(headlessAllowed(read, appLockEnabled: true), isFalse);
    });
  });

  group('in the app', () {
    late NotificationService service;
    late List<NotificationAction> ran;
    late bool locked;

    setUp(() {
      service = NotificationService();
      ran = [];
      locked = true;
      service.holdActions = () => locked;
      service.onAction = (a) async => ran.add(a);
    });

    test('while locked, reply and mark-read wait for the unlock', () async {
      await service.debugRun(reply);
      await service.debugRun(read);
      expect(ran, isEmpty);
      locked = false;
      await service.runHeldActions();
      expect(ran, [reply, read]);
      // Once only.
      await service.runHeldActions();
      expect(ran, hasLength(2));
    });

    test('call actions are not held (the call screen is the gate)', () async {
      await service.debugRun(decline);
      expect(ran, [decline]);
    });

    test('unlocked: actions run straight away', () async {
      locked = false;
      await service.debugRun(reply);
      expect(ran, [reply]);
    });

    test('still locked: running held actions keeps them', () async {
      await service.debugRun(reply);
      await service.runHeldActions();
      expect(ran, isEmpty);
      locked = false;
      await service.runHeldActions();
      expect(ran, [reply]);
    });
  });
}
