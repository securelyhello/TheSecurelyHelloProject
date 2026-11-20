import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/calls/call_service.dart';
import 'package:securelyhello/core/calls/call_system.dart';
import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';
import 'package:securelyhello/features/calls/call_screen.dart';

class _Notifier implements IncomingCallNotifier {
  @override
  Future<void> showIncomingCall({required String callId, required String name, required bool video}) async {}
  @override
  Future<void> cancelIncomingCall() async {}
}

// Security review H1: on a locked phone the app shows over the lock screen
// during a call; Back on the call screen must not reveal the chats.
void main() {
  const channel = MethodChannel('securelyhello/call');
  late List<MethodCall> native;
  late bool dismissed;
  late CallService calls;
  late CallSystemHolder holder;

  setUp(() {
    native = [];
    dismissed = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
      native.add(c);
      return switch (c.method) {
        'keyguardLocked' => true,
        'dismissKeyguard' => dismissed,
        _ => true,
      };
    });
    final directory =
        DirectoryService(baseUrl: 'https://fake.invalid', tokenStore: SecureKeyStore(storage: MemorySecretStorage()));
    final storage = LocalStorage();
    final chat = ChatService(storage: storage, p2p: P2PConnectionManager(), directory: directory);
    calls = CallService(chat: chat, canCall: (_) => true);
    holder = CallSystemHolder(calls, nameOf: (p) => p, notifier: _Notifier(), enabled: true);
  });

  tearDown(() {
    holder.system.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(WidgetTester t) async {
    calls.debugSetCall(ActiveCall(id: 'c1', peer: 'mira', video: false, outgoing: true)..phase = CallPhase.active);
    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<CallService?>.value(value: calls),
        Provider<CallSystemHolder?>.value(value: holder),
        ChangeNotifierProvider(
          create: (_) => ContactsProvider(
            directoryService: DirectoryService(
                baseUrl: 'https://fake.invalid', tokenStore: SecureKeyStore(storage: MemorySecretStorage())),
            localStorage: LocalStorage(),
          ),
        ),
      ],
      child: MaterialApp(
        navigatorObservers: [callRouteObserver],
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(children: [
              const Text('ALL MY CHATS'),
              TextButton(onPressed: () => showCallScreen(context), child: const Text('call')),
            ]),
          ),
        ),
      ),
    ));
    await t.tap(find.text('call'));
    await settle(t);
    expect(find.byType(CallScreen), findsOneWidget);
  }

  Future<void> back(WidgetTester t) async {
    await t.binding.handlePopRoute();
    await settle(t);
  }

  Iterable<Object?> screenStates() => native.where((m) => m.method == 'callScreen').map((m) => m.arguments);

  testWidgets('showing the call screen tells the native side', (t) async {
    await open(t);
    expect(screenStates(), [
      {'shown': true},
    ]);
  });

  testWidgets('locked: Back asks to dismiss the lock screen and stays if it is not', (t) async {
    await open(t);
    await back(t);
    expect(native.map((m) => m.method), contains('dismissKeyguard'));
    expect(find.byType(CallScreen), findsOneWidget);
    expect(find.text('ALL MY CHATS'), findsNothing);
    expect(screenStates(), [
      {'shown': true},
    ], reason: 'still over the lock screen');
  });

  testWidgets('unlocked: Back leaves, and stops showing over the lock screen first', (t) async {
    await open(t);
    dismissed = true;
    await back(t);
    expect(find.byType(CallScreen), findsNothing);
    expect(find.text('ALL MY CHATS'), findsOneWidget);
    expect(screenStates().last, {'shown': false});
    final i = native.indexWhere((m) => m.method == 'dismissKeyguard');
    final j = native.lastIndexWhere((m) => m.method == 'callScreen');
    expect(i, lessThan(j));
  });

  testWidgets('a page opened over the call screen stops showing over the lock screen', (t) async {
    await open(t);
    final nav = t.state<NavigatorState>(find.byType(Navigator));
    nav.push(MaterialPageRoute<void>(builder: (_) => const Text('a chat')));
    await settle(t);
    expect(screenStates().last, {'shown': false});
    nav.pop();
    await settle(t);
    expect(screenStates().last, {'shown': true}, reason: 'back to the call screen');
  });

  testWidgets('when the call ends the screen closes, even while locked', (t) async {
    await open(t);
    calls.debugSetCall(null);
    await settle(t);
    expect(find.byType(CallScreen), findsNothing);
    expect(screenStates().last, {'shown': false});
  });
}
