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
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/features/chat/widgets/voice_note.dart';
import 'package:securelyhello/core/calls/call_service.dart';
import 'package:securelyhello/core/invites/invites.dart';
import 'package:securelyhello/core/media/voice.dart';
import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/connection_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';
import 'package:securelyhello/features/chat/widgets/conversation_tile.dart';
import 'package:securelyhello/main.dart';
import 'package:securelyhello/l10n/app_localizations.dart';
import 'package:securelyhello/core/stories/story_service.dart';
import 'package:securelyhello/features/stories/story_composer.dart';
import 'package:securelyhello/shared/theme/locale_controller.dart';
import 'package:securelyhello/shared/theme/theme_controller.dart';

const _baseUrl =
    String.fromEnvironment('API_BASE_URL', defaultValue: 'http://127.0.0.1:8787');
const _shotDir = String.fromEnvironment('SHOT_DIR');

/// Where the server writes e-mails (MAIL_TRANSPORT=file, MAIL_FILE_DIR).
const _mailDir = String.fromEnvironment('MAIL_DIR', defaultValue: '/tmp/sh_mail');

/// A 600×400 gradient "photo", PNG-encoded.
Future<Uint8List> renderTestPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const size = Size(600, 400);
  canvas.drawRect(
    Offset.zero & size,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF2E1A47), Color(0xFFE8618C), Color(0xFFFFC371)],
      ).createShader(Offset.zero & size),
  );
  canvas.drawCircle(const Offset(300, 300), 90, Paint()..color = const Color(0xFFFFE29F));
  canvas.drawRect(const Rect.fromLTWH(0, 300, 600, 100), Paint()..color = const Color(0xFF1B2440));
  final image = await recorder.endRecording().toImage(600, 400);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// The newest 6-digit code e-mailed to [to], or null.
String? latestCode(String to) {
  final dir = Directory(_mailDir);
  if (!dir.existsSync()) return null;
  final files = dir.listSync().whereType<File>().toList()
    ..sort((a, b) => b.path.compareTo(a.path));
  for (final f in files) {
    final mail = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    if ((mail['to'] as String).toLowerCase() == to.toLowerCase()) {
      return RegExp(r'\b(\d{6})\b').firstMatch(mail['text'] as String)?.group(1);
    }
  }
  return null;
}

/// Every account in this test uses it (deleting one needs it again).
const _password = 'a long enough password';

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
      directoryService: directory, localStorage: storage);
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
    final sam = Client('sam');
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
              password: _password,
              username: 'mira_$tag',
              displayName: 'Mira Kapoor'),
          isTrue,
          reason: mira.auth.errorMessage);
      mira.contacts.init();
      await mira.chat.start(
          identity: mira.auth.identity!,
          myUserId: mira.auth.myUserId!,
          deviceId: mira.auth.deviceId!);
      final miraId = mira.auth.myUserId!;

      // ---- the real app, phone-sized -------------------------------------
      setWindow(412, 892);
      me.auth
        ..addSignOutHook(me.chatProvider.reset)
        ..addSignOutHook(me.contacts.reset)
        ..addSignOutHook(() async => me.connection.reset());
      unawaited(me.auth.init());
      // Dark for the walkthrough (the site uses these); light at the end.
      final theme = ThemeController();
      await theme.set(ThemeMode.dark);
      final language = LocaleController();
      await language.set(const Locale('en'));
      // No capture devices on the test machine; the call still connects.
      final myCalls = CallService(
          chat: me.chat, canCall: (u) => me.contacts.getContact(u) != null, media: const NoCallMedia());
      final miraCalls = CallService(
          chat: mira.chat, canCall: (u) => mira.contacts.getContact(u) != null, media: const NoCallMedia());
      final myStories = StoryService(chat: me.chat, directory: me.directory, storage: me.storage);
      await tester.pumpWidget(SecurelyHelloApp(
        authProvider: me.auth,
        chatProvider: me.chatProvider,
        contactsProvider: me.contacts,
        connectionProvider: me.connection,
        profiles: me.chat.profiles,
        calls: myCalls,
        theme: theme,
        language: language,
        stories: myStories,
      ));
      await settle(800);
      await shot('01_splash');
      // First launch: the welcome pages.
      await waitFor(find.byKey(const ValueKey('welcome-next')), 'welcome screen');
      await settle(600);
      await shot('01b_welcome');
      await tester.tap(find.byKey(const ValueKey('welcome-next')));
      await settle(700);
      await tester.tap(find.byKey(const ValueKey('welcome-next')));
      await settle(700);
      await shot('01c_welcome_last');
      await tester.tap(find.byKey(const ValueKey('welcome-login')));
      await waitFor(find.text('Welcome back'), 'login screen');
      expect(Theme.of(tester.element(find.text('Welcome back'))).brightness, Brightness.dark,
          reason: 'the chosen theme reaches the app');
      await shot('02_login');

      // Wrong password shows an inline error.
      await tester.enterText(find.byType(EditableText).at(0), 'nobody_$tag@example.test');
      await tester.enterText(find.byType(EditableText).at(1), 'wrong password');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Log in'));
      await waitFor(find.text('Wrong email or password'), 'login error');
      await shot('03_login_error');

      // Forgot password: a two-step flow behind the login screen.
      await tester.tap(find.byKey(const ValueKey('forgot-password')));
      await waitFor(find.text('Reset your password'), 'forgot-password screen');
      await settle(800);
      await shot('03b_forgot_password');
      nav().pop();
      await settle(800);

      await tester.tap(find.widgetWithText(TextButton, 'Sign up'));
      await waitFor(find.text('Create your account'), 'signup screen');
      await settle(1200); // let the login route finish animating out
      expect(find.text('Wrong email or password'), findsNothing);
      final fields = find.byType(EditableText);
      await tester.enterText(fields.at(0), 'tirth_$tag@example.test');
      await tester.enterText(fields.at(1), 'Tirth');
      await tester.enterText(fields.at(2), 'tirth_$tag');
      await tester.enterText(fields.at(3), _password);
      await tester.enterText(fields.at(4), _password);
      await settle(1200);
      await shot('04_signup_filled');
      await tester.ensureVisible(find.widgetWithText(ElevatedButton, 'Sign up'));
      await tester.tap(find.widgetWithText(ElevatedButton, 'Sign up'));
      // With e-mail configured the app asks for the code we were sent.
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (find.text('Check your inbox').evaluate().isEmpty &&
          find.text('Search chats').evaluate().isEmpty) {
        if (DateTime.now().isAfter(end)) fail('Never left the sign-up screen');
        await settle(100);
      }
      if (find.text('Check your inbox').evaluate().isNotEmpty) {
        await settle(800);
        await shot('04b_verify_email');
        final code = latestCode('tirth_$tag@example.test');
        expect(code, isNotNull, reason: 'server must run with MAIL_TRANSPORT=file');
        await tester.enterText(find.byType(EditableText).first, code!);
      }
      await waitFor(find.text('Search chats'), 'home screen after sign up');
      expect(me.auth.emailVerified || latestCode('tirth_$tag@example.test') == null, isTrue);
      await settle(1500);
      await shot('05_home_empty');

      // ---- find Mira and send a request ----------------------------------
      await tester.tap(find.byKey(const ValueKey('tab-find-people')));
      await waitFor(find.text('Search by username'), 'Find people tab');
      await shot('06_find_people_empty');
      await tester.tap(find.byKey(const ValueKey('find-invite')));
      await waitFor(find.byKey(const ValueKey('invite-qr')), 'invite screen with QR code');
      await settle(800);
      await shot('06b_invite');
      nav().pop();
      await settle(600);
      await tester.enterText(find.byKey(const ValueKey('find-people-search')), 'mira_$tag');
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
      await tester.tap(find.byKey(const ValueKey('tab-chats')));
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

      // ---- reply, reactions, edit, delete ------------------------------------
      final myMsgs = await me.chat.fetchMessages(miraId);
      final link = myMsgs.firstWhere((m) => m.content.contains('introduces us'));
      final nothing = myMsgs.firstWhere((m) => m.content.startsWith('Nothing readable'));
      await mira.chat.react(me.auth.myUserId!, link.id, '👍');
      await mira.chat.sendMessage(me.auth.myUserId!, 'So even the server operator can’t read this?',
          replyTo: {'id': nothing.id, 'from': me.auth.myUserId!, 'preview': nothing.content});
      await me.chat.react(miraId, nothing.id, '🙏');
      await me.chat.editMessage(miraId, link.id,
          'Yes! Messages go straight between our devices. The server only introduces us.');
      final oops = await me.chat.sendMessage(miraId, 'wrong chat, sorry');
      await me.chat.deleteForEveryone(miraId, oops.id);
      final rEnd = DateTime.now().add(const Duration(seconds: 15));
      while (find.byKey(const ValueKey('reactions')).evaluate().length < 2 ||
          find.textContaining('server operator').evaluate().isEmpty) {
        if (DateTime.now().isAfter(rEnd)) fail('reactions / reply never shown');
        await settle(200);
      }
      await settle(1200);
      await shot('12c_reply_react_edit_delete');

      // ---- encrypted attachments: a photo and a document -------------------
      final photo = await renderTestPng();
      await mira.chat.sendAttachment(me.auth.myUserId!,
          bytes: photo, name: 'sunset.png', caption: 'From the trip ☀️');
      await mira.chat.sendAttachment(me.auth.myUserId!,
          bytes: Uint8List.fromList(List.generate(48000, (i) => i % 251)),
          name: 'itinerary.pdf');
      await waitFor(find.byKey(const ValueKey('composer-attach')), 'attach button');
      final imgEnd = DateTime.now().add(const Duration(seconds: 20));
      while (find.byType(Image).evaluate().isEmpty ||
          find.textContaining('itinerary.pdf').evaluate().isEmpty) {
        if (DateTime.now().isAfter(imgEnd)) fail('attachments never shown');
        await settle(200);
      }
      await settle(1500);
      await shot('12b_chat_attachments');

      // ---- a voice note ----------------------------------------------------
      final wave = [for (var i = 0; i < 48; i++) 6 + ((i * 7) % 23)];
      await mira.chat.sendVoiceNote(me.auth.myUserId!,
          VoiceClip(Uint8List.fromList(List.generate(20000, (i) => i % 251)), const Duration(seconds: 14), wave));
      await waitFor(find.byType(VoiceNoteView), 'voice note bubble');
      await settle(1200);
      await shot('12d_voice_note');

      mira.chat.sendTyping(me.auth.myUserId!, true);
      await tester.enterText(find.byType(EditableText).last, 'Want to verify our safety number?');
      await settle(900);
      await shot('13_chat_typing_and_composer');
      await tester.enterText(find.byType(EditableText).last, '');
      mira.chat.sendTyping(me.auth.myUserId!, false);

      // ---- Mira calls -------------------------------------------------------
      await mira.contacts.loadContacts();
      await miraCalls.start(me.auth.myUserId!);
      await waitFor(find.byKey(const ValueKey('call-accept')), 'incoming call screen');
      await settle(800);
      await shot('13b_incoming_call');
      await tester.tap(find.byKey(const ValueKey('call-accept')));
      final callEnd = DateTime.now().add(const Duration(seconds: 20));
      while (myCalls.call?.phase != CallPhase.active || miraCalls.call?.phase != CallPhase.active) {
        if (DateTime.now().isAfter(callEnd)) fail('the call never connected');
        await settle(100);
      }
      await settle(2200);
      await shot('13c_call_active');
      expect(find.byKey(const ValueKey('call-no-media')), findsOneWidget, reason: 'says why there is no audio');
      await tester.tap(find.byKey(const ValueKey('call-hangup')));
      await waitFor(find.textContaining('Incoming voice call · 0:0'), 'the call record in the chat', seconds: 15);
      expect(find.byKey(const ValueKey('call-hangup')), findsNothing, reason: 'the call screen closed');
      await settle(800);

      // Contact info / safety number.
      await tester.tap(find.text('Mira Kapoor').first);
      await settle(1500);
      await shot('14_contact_info');
      await tester.ensureVisible(find.byKey(const ValueKey('contact-report')));
      await settle(400);
      await tester.tap(find.byKey(const ValueKey('contact-report')));
      await waitFor(find.byKey(const ValueKey('report-send')), 'report dialog');
      await settle(600);
      await shot('14b_report_dialog');
      await tester.tap(find.text('Cancel'));
      await settle(600);
      nav().pop();
      await settle(500);
      nav().pop(); // back to the list
      await settle(700);

      await shot('15_chats_read');

      // ---- a group with Mira and Sam, who don't know each other ------------
      await sam.auth.init();
      expect(
          await sam.auth.signUp(
              email: 'sam_$tag@example.test',
              password: _password,
              username: 'sam_$tag',
              displayName: 'Sam Okafor'),
          isTrue,
          reason: sam.auth.errorMessage);
      sam.contacts.init();
      await sam.chat.start(
          identity: sam.auth.identity!, myUserId: sam.auth.myUserId!, deviceId: sam.auth.deviceId!);
      await sam.contacts.acceptInvite(inviteTokenFrom((await me.contacts.createInvite())['url'] as String)!);
      await me.contacts.loadContacts();

      await tester.tap(find.byTooltip('New chat'));
      await waitFor(find.byKey(const ValueKey('new-group')), 'people');
      await settle(600);
      await tester.tap(find.byKey(const ValueKey('new-group')));
      await waitFor(find.byKey(const ValueKey('group-name')), 'new group screen');
      await settle(600);
      final create = find.byKey(const ValueKey('group-create'));
      expect(tester.widget<FilledButton>(create).onPressed, isNull, reason: 'needs a name and members');
      await tester.enterText(find.byKey(const ValueKey('group-name')), 'Weekend trip');
      await tester.tap(find.byKey(ValueKey('pick-mira_$tag')));
      await tester.tap(find.byKey(ValueKey('pick-sam_$tag')));
      await settle(600);
      await shot('15b_new_group');
      await tester.tap(create);
      await waitFor(find.byKey(const ValueKey('group-header')), 'the new group chat');
      final groupId = me.chatProvider.groups.single.conversationId;
      for (final c in [mira, sam]) {
        final gEnd = DateTime.now().add(const Duration(seconds: 15));
        while (c.chat.groupOf(groupId) == null) {
          if (DateTime.now().isAfter(gEnd)) fail('${c == mira ? 'Mira' : 'Sam'} never got the group');
          await settle(100);
        }
      }
      await mira.chat.sendMessage(groupId, 'I can drive on Saturday 🚗');
      await sam.chat.sendMessage(groupId, 'Great, I’ll bring snacks');
      await waitFor(find.textContaining('bring snacks'), 'group messages');
      await me.chatProvider.sendMessage(groupId, 'Perfect. Leaving at 9?');
      await settle(1500);
      await shot('15c_group_chat');
      expect(find.text('Sam Okafor'), findsWidgets, reason: 'sender names on group bubbles');

      await tester.tap(find.byKey(const ValueKey('group-header')));
      await waitFor(find.byKey(const ValueKey('group-info-name')), 'group info');
      await settle(1000);
      await shot('15d_group_info');
      expect(find.byKey(ValueKey('member-${mira.auth.myUserId}')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-add')), findsOneWidget, reason: 'we are the admin');
      nav().pop();
      await settle(600);
      nav().pop();
      await settle(800);

      // ---- people (behind "New chat") and the Calls tab ---------------------
      await tester.tap(find.byTooltip('New chat'));
      await waitFor(find.byKey(const ValueKey('new-group')), 'people');
      await settle(800);
      await shot('16_people');
      nav().pop();
      await settle(700);
      await tester.tap(find.text('Calls').last);
      await waitFor(find.byKey(const ValueKey('calls-list')), 'call history');
      await settle(900);
      await shot('16b_calls');

      // ---- stories ----------------------------------------------------------
      final miraStories = StoryService(chat: mira.chat, directory: mira.directory, storage: mira.storage);
      await miraStories.start(miraId, deviceId: mira.auth.deviceId!);
      await miraStories.postText('Sunset walk by the lake 🌅', StoryComposer.colors.first, contacts: [me.auth.myUserId!]);
      await tester.tap(find.text('Chats').last);
      await settle(600);
      final storyEnd = DateTime.now().add(const Duration(seconds: 20));
      while (find.byKey(ValueKey('story-owner-$miraId')).evaluate().isEmpty) {
        if (DateTime.now().isAfter(storyEnd)) fail("Mira's story never showed");
        await myStories.refresh();
        await settle(300);
      }
      await settle(600);
      await shot('16c_stories_row');
      await tester.tap(find.byKey(ValueKey('story-owner-$miraId')));
      await waitFor(find.byKey(const ValueKey('story-viewer')), 'story viewer');
      await settle(1200);
      await shot('16d_story_viewer');
      await tester.tap(find.byTooltip('Close'));
      await settle(900);
      await tester.tap(find.byKey(const ValueKey('my-story')));
      await waitFor(find.byKey(const ValueKey('story-new-text')), 'new story sheet');
      await settle(500);
      await tester.tap(find.byKey(const ValueKey('story-new-text')));
      await waitFor(find.byKey(const ValueKey('story-text')), 'story composer');
      await tester.enterText(find.byKey(const ValueKey('story-text')), 'Trying out stories ✨');
      await settle(700);
      await shot('16e_story_composer');
      await tester.tap(find.byKey(const ValueKey('story-post')));
      await settle(1500);
      expect(myStories.mine, hasLength(1), reason: 'my story was posted');

      // ---- message search ---------------------------------------------------
      await tester.tap(find.byTooltip(L10n.of(tester.element(find.text('Chats').last)).moreOptions).first);
      await settle(500);
      await tester.tap(find.text('Search messages'));
      await waitFor(find.byKey(const ValueKey('message-search')), 'message search');
      await tester.enterText(find.byKey(const ValueKey('message-search')), 'encrypted');
      await settle(1500);
      await shot('16f_message_search');
      nav().pop();
      await settle(700);
      await tester.tap(find.text('Calls').last);
      await settle(500);
      await tester.tap(find.text('Settings').last);
      await settle(900);
      await shot('17_settings');
      await tester.dragUntilVisible(find.byKey(const ValueKey('settings-app-lock')),
          find.byType(ListView).last, const Offset(0, -250));
      await settle(600);
      await shot('17c_settings_security');
      await tester.dragUntilVisible(find.byKey(const ValueKey('settings-2fa')),
          find.byType(ListView).last, const Offset(0, -250));
      await tester.tap(find.byKey(const ValueKey('settings-2fa')));
      await waitFor(find.byKey(const ValueKey('2fa-start')), 'two-step verification screen');
      await settle(600);
      await shot('17d_two_step');
      nav().pop();
      await settle(600);
      await tester.dragUntilVisible(find.byKey(const ValueKey('settings-backup')),
          find.byType(ListView).last, const Offset(0, 250));
      await tester.ensureVisible(find.byKey(const ValueKey('settings-backup')));
      await settle(400);
      await tester.tap(find.byKey(const ValueKey('settings-backup')));
      await waitFor(find.byKey(const ValueKey('backup-export')), 'backup screen');
      await tester.tap(find.byKey(const ValueKey('backup-export')));
      await waitFor(find.byKey(const ValueKey('backup-key')), 'backup key dialog');
      final continueButton = find.byKey(const ValueKey('backup-continue'));
      expect(tester.widget<FilledButton>(continueButton).onPressed, isNull,
          reason: 'blocked until the key is saved');
      await tester.tap(find.byKey(const ValueKey('backup-key-written')));
      await settle(400);
      expect(tester.widget<FilledButton>(continueButton).onPressed, isNotNull);
      await shot('17e_backup_key');
      await tester.tap(find.text('Cancel'));
      await settle(500);
      nav().pop();
      await settle(600);
      unawaited(nav().pushNamed('/devices'));
      await waitFor(find.text('This device'), 'linked devices screen');
      await settle(800);
      await shot('17b_linked_devices');
      nav().pop();
      await settle(700);
      await tester.dragUntilVisible(find.byKey(const ValueKey('settings-account')),
          find.byType(ListView).last, const Offset(0, -300));
      await tester.ensureVisible(find.byKey(const ValueKey('settings-account')));
      await settle(400);
      await tester.tap(find.byKey(const ValueKey('settings-account')));
      await waitFor(find.byKey(const ValueKey('account-export')), 'account screen');
      await settle(700);
      await shot('17f_account');
      nav().pop();
      await settle(700);

      // ---- wide window: two panes ----------------------------------------
      setWindow(1280, 800);
      await settle(900);
      await tester.tap(find.text('Chats').last, warnIfMissed: false);
      await settle(700);
      await shot('18_wide_no_chat');
      await tester.tap(find.widgetWithText(ConversationTile, 'Mira Kapoor').first);
      await settle(1500);
      await shot('19_wide_chat_open');

      // ---- the light theme -------------------------------------------------
      await theme.set(ThemeMode.light);
      await settle(900);
      expect(Theme.of(tester.element(find.text('Chats').first)).brightness, Brightness.light);
      await shot('20_light_wide_chat');
      setWindow(412, 892);
      await settle(900);
      await shot('21_light_chat');

      // ---- Hindi -------------------------------------------------------------
      await language.set(const Locale('hi'));
      nav().popUntil((r) => r.isFirst);
      await settle(1200);
      expect(find.text('चैट'), findsWidgets, reason: 'tab labels follow the language');
      await shot('22_hindi_chats');
      await language.set(const Locale('gu'));
      await settle(1000);
      expect(find.text('ચૅટ'), findsWidgets, reason: 'Gujarati');
      await shot('23_gujarati_chats');
      await language.set(const Locale('hi'));
      await settle(600);

      // ---- stress: long names and messages, big text, small and big screens
      // Any overflow or layout error here fails the test. Shots are named
      // zz_* so the website build skips them.
      const longName = 'Mira Kapoor-Venkataraghavan Subramaniam, Longname Society'; // 56 of 64
      expect(await mira.auth.updateDisplayName(longName), isTrue, reason: mira.auth.errorMessage);
      await me.contacts.loadContacts();
      final longText = List.filled(40, 'This is a long message that wraps over many lines.').join(' ');
      await mira.chat.sendMessage(me.auth.myUserId!, longText);
      await mira.chat.sendMessage(me.auth.myUserId!,
          'https://example.test/${'unbroken-path-segment-' * 8}?q=${'x' * 60}');
      await mira.chat.sendMessage(me.auth.myUserId!, '🎉🔐👋🏽🧑🏽‍💻' * 12);
      Future<void> tapTab(IconData icon) async {
        await tester.tap(find.byIcon(icon).last, warnIfMissed: false);
        await settle(700);
      }

      Future<void> stressPass(String tag) async {
        nav().popUntil((r) => r.isFirst);
        await settle(900);
        await tapTab(LucideIcons.messageCircle);
        await waitFor(find.text(longName), 'long name in the chat list');
        await shot('zz_${tag}_chats');
        await tester.tap(find.widgetWithText(ConversationTile, longName).first);
        await settle(1500);
        await shot('zz_${tag}_chat');
        // The keyboard is up: the composer must stay visible above it.
        final composer = find.byKey(const ValueKey('composer-attach'));
        await waitFor(composer, 'composer');
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await settle(700);
        final bottom = tester.getRect(composer).bottom;
        expect(bottom, lessThanOrEqualTo(tester.view.physicalSize.height / tester.view.devicePixelRatio - 300),
            reason: 'composer hidden behind the keyboard ($tag)');
        await shot('zz_${tag}_chat_keyboard');
        tester.view.resetViewInsets();
        await settle(500);
        nav().popUntil((r) => r.isFirst);
        await settle(700);
        await tapTab(LucideIcons.phone);
        await shot('zz_${tag}_calls');
        await tapTab(LucideIcons.settings);
        await shot('zz_${tag}_settings');
        await tapTab(LucideIcons.messageCircle);
      }

      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      setWindow(360, 640); // a small phone
      await stressPass('small_hi_light_text13');
      await language.set(const Locale('en'));
      await theme.set(ThemeMode.dark);
      setWindow(412, 892);
      await stressPass('phone_en_dark_text13');
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      setWindow(1280, 800);
      await settle(900);
      await tapTab(LucideIcons.messageCircle);
      await tester.tap(find.widgetWithText(ConversationTile, longName).first);
      await settle(1500);
      await shot('zz_wide_long_name');
      setWindow(412, 892);
      await settle(900);

      // ---- clean up -------------------------------------------------------
      for (final c in [me, mira]) {
        await c.chat.stop();
        try {
          await c.directory.deleteAccount(currentPassword: _password);
        } catch (_) {}
        await c.storage.close();
        c.dir.deleteSync(recursive: true);
      }
    });
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
