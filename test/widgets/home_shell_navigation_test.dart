import 'dart:async';

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
import 'package:securelyhello/features/home/chat_navigation.dart';

class _Notifier implements IncomingCallNotifier {
  @override
  Future<void> showIncomingCall({required String callId, required String name, required bool video}) async {}
  @override
  Future<void> cancelIncomingCall() async {}
}

/// Stands in for HomeScreen: the same registration, route capture through
/// [RouteProbe] and `popToShell` step, without HomeScreen's providers and tabs.
class _Shell extends StatefulWidget {
  const _Shell({required this.onBuild});
  final VoidCallback onBuild;

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> implements HomeTabSelector {
  HomeTab tab = HomeTab.chats;
  ModalRoute<dynamic>? route;

  @override
  void initState() {
    super.initState();
    HomeTabRegistry.attach(this);
  }

  @override
  void dispose() {
    HomeTabRegistry.detach(this);
    super.dispose();
  }

  @override
  void select(HomeTab next) {
    unawaited(() async {
      if (!await popToShell(context, route) || !mounted) return;
      setState(() => tab = next);
    }());
  }

  @override
  Widget build(BuildContext context) {
    widget.onBuild();
    return RouteProbe(
      onRoute: (r) => route = r,
      child: Scaffold(
        body: Column(children: [
          Text('tab: ${tab.name}'),
          Builder(builder: (ctx) => TextButton(onPressed: () => openFindPeople(ctx), child: const Text('find'))),
        ]),
      ),
    );
  }
}

void main() {
  const channel = MethodChannel('securelyhello/call');
  late bool dismissed;
  late CallService calls;
  late CallSystemHolder holder;
  var builds = 0;

  setUp(() {
    builds = 0;
    dismissed = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
      return switch (c.method) {
        'keyguardLocked' => true,
        'dismissKeyguard' => dismissed,
        _ => true,
      };
    });
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

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<NavigatorState> pumpShell(WidgetTester t) async {
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
        home: _Shell(onBuild: () => builds++),
      ),
    ));
    await settle(t);
    return t.state<NavigatorState>(find.byType(Navigator));
  }

  testWidgets('a page pushed over the shell is popped and the tab switches on openFindPeople', (t) async {
    final nav = await pumpShell(t);
    nav.push(MaterialPageRoute<void>(builder: (ctx) => Scaffold(body: Builder(builder: (c) {
          return TextButton(onPressed: () => openFindPeople(c), child: const Text('find from page'));
        }))));
    await settle(t);
    expect(find.text('find from page'), findsOneWidget);
    expect(find.text('tab: chats'), findsNothing, reason: 'covered by the page (not painted)');

    await t.tap(find.text('find from page'));
    await settle(t);
    expect(find.text('find from page'), findsNothing, reason: 'popped back to the shell');
    expect(find.text('tab: findPeople'), findsOneWidget);
  });

  testWidgets('two pages deep are both popped', (t) async {
    final nav = await pumpShell(t);
    nav.push(MaterialPageRoute<void>(builder: (_) => const Text('one')));
    nav.push(MaterialPageRoute<void>(builder: (_) => const Text('two')));
    await settle(t);
    HomeTabRegistry.current!.select(HomeTab.calls);
    await settle(t);
    expect(find.text('one'), findsNothing);
    expect(find.text('two'), findsNothing);
    expect(find.text('tab: calls'), findsOneWidget);
  });

  testWidgets('pushing and popping a page does not rebuild the shell', (t) async {
    final nav = await pumpShell(t);
    final before = builds;
    nav.push(MaterialPageRoute<void>(builder: (_) => const Text('page')));
    await settle(t);
    nav.pop();
    await settle(t);
    expect(builds, before);
  });

  testWidgets('RouteProbe reports the route it is in', (t) async {
    ModalRoute<dynamic>? seen;
    await t.pumpWidget(MaterialApp(home: RouteProbe(onRoute: (r) => seen = r, child: const Text('x'))));
    expect(seen, isNotNull);
    expect(seen!.isCurrent, isTrue);
  });

  group('over the call screen on a locked phone', () {
    Future<NavigatorState> withCallOver(WidgetTester t) async {
      final nav = await pumpShell(t);
      nav.push(MaterialPageRoute<void>(builder: (_) => const Text('people page')));
      await settle(t);
      calls.debugSetCall(ActiveCall(id: 'c1', peer: 'mira', video: false, outgoing: true)..phase = CallPhase.active);
      showCallScreen(t.element(find.text('people page')));
      await settle(t);
      expect(find.byType(CallScreen), findsOneWidget);
      return nav;
    }

    testWidgets('select does not pop the call screen or change tab until unlocked', (t) async {
      await withCallOver(t);
      HomeTabRegistry.current!.select(HomeTab.findPeople);
      await settle(t);
      expect(find.byType(CallScreen), findsOneWidget);
      expect(callScreenShowing, isTrue);
      expect(find.text('tab: findPeople'), findsNothing);
      expect(find.text('tab: chats', skipOffstage: false), findsOneWidget, reason: 'tab unchanged');
    });

    testWidgets('once unlocked it pops back to the shell and switches', (t) async {
      await withCallOver(t);
      dismissed = true;
      HomeTabRegistry.current!.select(HomeTab.findPeople);
      await settle(t);
      expect(find.byType(CallScreen), findsNothing);
      expect(find.text('people page'), findsNothing);
      expect(find.text('tab: findPeople'), findsOneWidget);
    });
  });
}
