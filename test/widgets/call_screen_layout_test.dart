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
import 'package:securelyhello/shared/theme/app_theme.dart';

class _Notifier implements IncomingCallNotifier {
  @override
  Future<void> showIncomingCall({required String callId, required String name, required bool video}) async {}
  @override
  Future<void> cancelIncomingCall() async {}
}

/// The call screen has to fit short windows (landscape phones, split screen)
/// without a RenderFlex overflow, and keep its buttons reachable.
void main() {
  const channel = MethodChannel('securelyhello/call');
  late CallService calls;
  late CallSystemHolder holder;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (c) async => c.method == 'keyguardLocked' ? false : true);
    final directory =
        DirectoryService(baseUrl: 'https://fake.invalid', tokenStore: SecureKeyStore(storage: MemorySecretStorage()));
    final chat = ChatService(storage: LocalStorage(), p2p: P2PConnectionManager(), directory: directory);
    calls = CallService(chat: chat, canCall: (_) => true);
    holder = CallSystemHolder(calls, nameOf: (p) => p, notifier: _Notifier(), enabled: true);
  });

  tearDown(() {
    holder.system.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> pump(WidgetTester t, Size size, ActiveCall call, {double textScale = 1}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    calls.debugSetCall(call);
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
        theme: AppTheme.dark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(body: TextButton(onPressed: () => showCallScreen(context), child: const Text('call'))),
        ),
      ),
    ));
    await t.tap(find.text('call'));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(CallScreen), findsOneWidget);
  }

  ActiveCall active({bool video = false}) =>
      ActiveCall(id: 'c1', peer: 'mira', video: video, outgoing: true)..phase = CallPhase.active;
  ActiveCall ringing({bool video = true}) => ActiveCall(id: 'c2', peer: 'mira', video: video, outgoing: false);

  const sizes = {
    'landscape phone 800x360': Size(800, 360),
    'split screen 360x360': Size(360, 360),
    'very short 640x300': Size(640, 300),
    'portrait phone 360x800': Size(360, 800),
  };

  for (final e in sizes.entries) {
    testWidgets('${e.key}: an active voice call lays out without overflow and End is on screen', (t) async {
      await pump(t, e.value, active());
      expect(t.takeException(), isNull);
      final end = t.getRect(find.byKey(const ValueKey('call-hangup')));
      expect(end.bottom, lessThanOrEqualTo(e.value.height));
      expect(end.right, lessThanOrEqualTo(e.value.width));
    });

    testWidgets('${e.key}: an incoming video call keeps Decline and Accept on screen', (t) async {
      await pump(t, e.value, ringing());
      expect(t.takeException(), isNull);
      for (final k in ['call-decline', 'call-accept']) {
        final r = t.getRect(find.byKey(ValueKey(k)));
        expect(r.bottom, lessThanOrEqualTo(e.value.height), reason: k);
        expect(r.top, greaterThanOrEqualTo(0), reason: k);
      }
    });
  }

  testWidgets('800x360 at text scale 1.3 still does not overflow', (t) async {
    await pump(t, const Size(800, 360), active(), textScale: 1.3);
    expect(t.takeException(), isNull);
  });

  testWidgets('landscape: the name and status are still shown', (t) async {
    await pump(t, const Size(800, 360), active());
    expect(find.byKey(const ValueKey('call-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-status')), findsOneWidget);
    final name = t.getRect(find.byKey(const ValueKey('call-name')));
    expect(name.top, greaterThanOrEqualTo(0));
  });
}
