// Drives the real app UI against a running server (scripts/dev.sh) and saves
// screenshots of each screen, so the interface can be reviewed without a
// human clicking through it.
//
//   flutter test integration_test/ui_flow_test.dart -d linux \
//     --dart-define=SHOT_DIR=/some/dir
//
// "You" are a real app instance; "Mira" is a second, headless client stack in
// the same process that answers.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/connection_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';
import 'package:securelyhello/main.dart';

const _baseUrl =
    String.fromEnvironment('API_BASE_URL', defaultValue: 'http://127.0.0.1:8787');
const _shotDir = String.fromEnvironment('SHOT_DIR');

class Client {
  final Directory dir;
  late final SecureKeyStore keyStore =
      SecureKeyStore(storage: MemorySecretStorage());
  late final LocalStorage storage =
      LocalStorage(baseDirectory: () async => dir.path);
  late final DirectoryService directory =
      DirectoryService(baseUrl: _baseUrl, tokenStore: keyStore);
  final P2PConnectionManager p2p = P2PConnectionManager();
  late final ChatService chat =
      ChatService(storage: storage, p2p: p2p, directory: directory);
  late final AuthProvider auth = AuthProvider(
      directoryService: directory, localStorage: storage, keyStore: keyStore);
  late final ContactsProvider contacts = ContactsProvider(
      directoryService: directory, localStorage: storage, chatService: chat);
  late final ChatProvider chatProvider = ChatProvider(chatService: chat);
  late final ConnectionProvider connection =
      ConnectionProvider(connectionManager: p2p, chatService: chat)..init();

  Client(String name) : dir = Directory.systemTemp.createTempSync('sh_ui_$name');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('walk through the app and capture every screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final tag = Random.secure().nextInt(1 << 24).toRadixString(16);
    final me = Client('me');
    final mira = Client('mira');
    final out = Directory(_shotDir.isEmpty
        ? '${Directory.systemTemp.path}/sh_shots'
        : _shotDir)
      ..createSync(recursive: true);

    Future<void> settle([int ms = 600]) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (DateTime.now().isBefore(end)) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }

    Future<void> waitFor(Finder finder, String what, {int seconds = 20}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (finder.evaluate().isEmpty) {
        if (DateTime.now().isAfter(end)) fail('Never appeared: $what');
        await settle(100);
      }
    }

    Future<void> shot(String name) async {
      await settle(500);
      final view = tester.binding.renderViews.first;
      final layer = view.debugLayer! as OffsetLayer;
      final image = await layer.toImage(view.paintBounds);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${out.path}/$name.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    }

    void setWindow(double w, double h) {
      tester.view.physicalSize = Size(w, h);
      tester.view.devicePixelRatio = 1.0;
    }

    NavigatorState nav() => tester.state<NavigatorState>(find.byType(Navigator).first);

    await tester.runAsync(() async {
      // ---- Mira: an existing user ----------------------------------------
      await mira.auth.init();
      expect(
          await mira.auth.signUp(
              email: 'mira_$tag@example.test',
              password: 'a long enough password',
              username: 'mira_$tag',
              displayName: 'Mira Kapoor'),
          isTrue,
          reason: mira.auth.errorMessage);
      mira.contacts.init();
      await mira.chat.start(
          identity: mira.auth.identity!, myUserId: mira.auth.myUserId!);
      final miraId = mira.auth.myUserId!;

      // ---- the real app, phone-sized -------------------------------------
      setWindow(412, 892);
      me.auth
        ..addSignOutHook(me.chatProvider.reset)
        ..addSignOutHook(me.contacts.reset)
        ..addSignOutHook(() async => me.connection.reset());
      unawaited(me.auth.init());
      await tester.pumpWidget(SecurelyHelloApp(
        authProvider: me.auth,
        chatProvider: me.chatProvider,
        contactsProvider: me.contacts,
        connectionProvider: me.connection,
      ));
      await settle(800);
      await shot('01_splash');
      await waitFor(find.text('Welcome back'), 'login screen');
      await shot('02_login');

      // Wrong password shows an inline error.
      await tester.enterText(find.byType(EditableText).at(0), 'nobody_$tag@example.test');
      await tester.enterText(find.byType(EditableText).at(1), 'wrong password');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Log in'));
      await waitFor(find.text('Wrong email or password'), 'login error');
      await shot('03_login_error');

      await tester.tap(find.widgetWithText(TextButton, 'Sign up'));
      await waitFor(find.text('Create your account'), 'signup screen');
      await settle(1200); // let the login route finish animating out
      expect(find.text('Wrong email or password'), findsNothing);
      final fields = find.byType(EditableText);
      await tester.enterText(fields.at(0), 'tirth_$tag@example.test');
      await tester.enterText(fields.at(1), 'Tirth');
      await tester.enterText(fields.at(2), 'tirth_$tag');
      await tester.enterText(fields.at(3), 'a long enough password');
      await tester.enterText(fields.at(4), 'a long enough password');
      await settle(1200);
      await shot('04_signup_filled');
      await tester.ensureVisible(find.widgetWithText(ElevatedButton, 'Sign up'));
      await tester.tap(find.widgetWithText(ElevatedButton, 'Sign up'));
      await waitFor(find.text('Search chats'), 'home screen after sign up');
      await settle(1500);
      await shot('05_home_empty');

      // ---- find Mira and send a request ----------------------------------
      unawaited(nav().pushNamed('/add-contact'));
      await waitFor(find.text('Search by username'), 'add-contact screen');
      await shot('06_find_people_empty');
      await tester.enterText(find.byType(EditableText).first, 'mira_$tag');
      await waitFor(find.text('Mira Kapoor'), 'search result');
      await shot('07_find_people_result');
      expect(await me.contacts.sendContactRequest(miraId), isTrue);
      await shot('08_find_people_requested');

      // Mira accepts from her device.
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (mira.contacts.receivedRequests.isEmpty) {
        if (DateTime.now().isAfter(deadline)) fail('Mira never got the request');
        await settle(100);
      }
      expect(
          await mira.contacts
              .acceptContactRequest(mira.contacts.receivedRequests.single.id),
          isTrue);
      await settle(1500);
      await shot('09_request_accepted_snackbar');
      nav().pop();
      await settle(600);

      // ---- messages arrive while the list is showing ---------------------
      await mira.chat.sendMessage(me.auth.myUserId!, 'Hey! Got your request 🙂');
      await mira.chat.sendMessage(
          me.auth.myUserId!, 'Is this the new encrypted app you mentioned?');
      await waitFor(find.textContaining('encrypted app you mentioned'),
          'chat list preview');
      await shot('10_chats_unread');

      // ---- open the chat --------------------------------------------------
      await tester.tap(find.text('Mira Kapoor').first);
      await waitFor(find.textContaining('Got your request'), 'chat screen');
      await settle(1500);
      await shot('11_chat_incoming');

      await me.chatProvider.sendMessage(miraId,
          'Yes! Messages go straight between our devices. The server only '
          'introduces us: https://api.hello.thenn.in');
      await me.chatProvider.sendMessage(miraId, 'Nothing readable is stored there.');
      await settle(1200);
      await mira.chat.markConversationRead(me.auth.myUserId!);
      await settle(1200);
      await shot('12_chat_sent_and_read');

      mira.chat.sendTyping(me.auth.myUserId!, true);
      await tester.enterText(find.byType(EditableText).last, 'Want to verify our safety number?');
      await settle(900);
      await shot('13_chat_typing_and_composer');
      await tester.enterText(find.byType(EditableText).last, '');
      mira.chat.sendTyping(me.auth.myUserId!, false);

      // Contact info / safety number.
      await tester.tap(find.text('Mira Kapoor').first);
      await settle(1500);
      await shot('14_contact_info');
      nav().pop();
      await settle(500);
      nav().pop(); // back to the list
      await settle(700);

      // ---- other tabs -----------------------------------------------------
      await shot('15_chats_read');
      await tester.tap(find.text('Contacts').last);
      await settle(900);
      await shot('16_contacts');
      await tester.tap(find.text('Settings').last);
      await settle(900);
      await shot('17_settings');

      // ---- wide window: two panes ----------------------------------------
      setWindow(1280, 800);
      await settle(900);
      await tester.tap(find.text('Chats').last, warnIfMissed: false);
      await settle(700);
      await shot('18_wide_no_chat');
      await tester.tap(find.text('Mira Kapoor').first);
      await settle(1500);
      await shot('19_wide_chat_open');

      // ---- clean up -------------------------------------------------------
      for (final c in [me, mira]) {
        await c.chat.stop();
        try {
          await c.directory.deleteAccount();
        } catch (_) {}
        await c.storage.close();
        c.dir.deleteSync(recursive: true);
      }
    });
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
