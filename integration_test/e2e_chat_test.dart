// End-to-end test against a running server (scripts/dev.sh).
//
//   scripts/dev.sh                      # terminal 1
//   flutter test integration_test -d linux [--dart-define=API_BASE_URL=...]
//
// Two complete, independent client stacks ("Alice" and "Bob") run in this one
// process: each has its own database, key store, session, WebSocket and
// WebRTC peer connection. Nothing is mocked except the OS keystore.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';

const _baseUrl =
    String.fromEnvironment('API_BASE_URL', defaultValue: 'http://127.0.0.1:8787');

class Stack {
  final String name;
  final Directory dir;
  final MemorySecretStorage secrets = MemorySecretStorage();
  late final SecureKeyStore keyStore = SecureKeyStore(storage: secrets);
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

  late final String username;
  late final String email;
  static const password = 'correct horse battery staple';

  Stack(this.name) : dir = Directory.systemTemp.createTempSync('sh_e2e_$name');

  String get id => auth.myUserId!;

  Future<void> signUp() async {
    final tag = Random.secure().nextInt(1 << 32).toRadixString(16);
    username = '${name}_$tag';
    email = '$username@example.test';
    await auth.init();
    final ok = await auth.signUp(
        email: email,
        password: password,
        username: username,
        displayName: name);
    expect(ok, isTrue, reason: auth.errorMessage);
    contacts.init();
    await startChat();
  }

  /// Signs in to [other]'s account as an additional device of it.
  Future<void> signInAs(Stack other) async {
    username = other.username;
    email = other.email;
    await auth.init();
    final ok = await auth.signIn(email: email, password: password);
    expect(ok, isTrue, reason: auth.errorMessage);
    contacts.init();
  }

  Future<void> startChat() => chat.start(
      identity: auth.identity!, myUserId: id, deviceId: auth.deviceId!);

  Future<List<Message>> messagesWith(Stack other) =>
      chat.fetchMessages(other.id);

  Future<void> dispose() async {
    await chat.stop();
    try {
      await directory.deleteAccount();
    } catch (_) {}
    await storage.close();
    await p2p.dispose();
    await directory.dispose();
    dir.deleteSync(recursive: true);
  }
}

/// Polls [check] until it returns true.
Future<void> until(FutureOr<bool> Function() check,
    {Duration timeout = const Duration(seconds: 20), required String what}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    if (await check()) return;
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for: $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Stack alice;
  late Stack bob;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    alice = Stack('alice');
    bob = Stack('bob');
  });

  tearDownAll(() async {
    await alice.dispose();
    await bob.dispose();
  });

  testWidgets('sign up, become contacts, chat P2P and via the offline relay',
      (tester) async {
    await tester.runAsync(() async {
      // ---- accounts -------------------------------------------------------
      await alice.signUp();
      await bob.signUp();
      expect(alice.auth.isAuthenticated, isTrue);
      expect(alice.id, isNot(bob.id));
      await until(() => alice.directory.isRealtimeConnected &&
          bob.directory.isRealtimeConnected,
          what: 'both sockets connected');

      // The private keys never left the device: the server knows one device
      // with the public halves and a stock of public prekeys.
      final aliceDevices = await bob.directory.getUserDevices(alice.id);
      expect(aliceDevices, hasLength(1));
      expect(aliceDevices.single['device_id'], alice.auth.deviceId);
      expect(aliceDevices.single['signing_public_key'],
          alice.auth.identity!.publicSigningKeyBase64);
      expect(aliceDevices.single['identity_public_key'],
          alice.auth.identity!.publicEncryptionKeyBase64);
      final current = await alice.directory.getCurrentDevice();
      expect(current['prekeys_remaining'], 100);
      final aliceProfile = await alice.directory.getMyProfile();
      expect(jsonEncode(aliceProfile).contains('private'), isFalse);
      expect(jsonEncode(aliceDevices).contains(base64Encode(
              alice.auth.identity!.encryptionPrivateKeyBytes)),
          isFalse);

      // ---- contact request ------------------------------------------------
      final found = await alice.directory.searchUsers(bob.username);
      expect(found.map((u) => u['user_id']), contains(bob.id));

      // Strangers cannot relay to each other.
      await expectLater(
        alice.chat.sendMessage(bob.id, 'too early').then((m) => m.status),
        completion('failed'),
      );

      final bobNotified = bob.contacts.onNewRequest.first;
      expect(await alice.contacts.sendContactRequest(bob.id), isTrue);
      expect(await bobNotified.timeout(const Duration(seconds: 10)),
          contains('new contact request'));
      await until(() => bob.contacts.receivedRequests.isNotEmpty,
          what: 'Bob sees the request');
      expect(alice.contacts.sentRequests.single.receiverId, bob.id);

      final aliceNotified = alice.contacts.onNewRequest.first;
      expect(
          await bob.contacts
              .acceptContactRequest(bob.contacts.receivedRequests.single.id),
          isTrue);
      expect(await aliceNotified.timeout(const Duration(seconds: 10)),
          contains('accepted'));
      await until(
          () =>
              alice.contacts.getContact(bob.id) != null &&
              bob.contacts.getContact(alice.id) != null,
          what: 'both contact lists updated');
      await until(() => alice.contacts.getContact(bob.id)!.isOnline,
          what: 'Alice sees Bob online');

      // ---- direct P2P link ------------------------------------------------
      // The message sent before they were contacts is retried now.
      await alice.chat.resendUnsent();
      await alice.chat.connect(bob.id);
      await until(
          () =>
              alice.p2p.hasConnectionWithPrefix('${bob.id}:') &&
              bob.p2p.hasConnectionWithPrefix('${alice.id}:'),
          timeout: const Duration(seconds: 40),
          what: 'WebRTC data channel open on both sides');

      final sent = await alice.chat.sendMessage(bob.id, 'hello bob, direct');
      expect(sent.status, 'sent');
      await until(
          () async => (await bob.messagesWith(alice))
              .any((m) => m.content == 'hello bob, direct' && !m.isFromMe),
          what: 'Bob receives the P2P message');
      // The direct message must not have touched the relay queue.
      await until(() async => (await bob.directory.fetchRelayMessages()).isEmpty,
          what: 'relay queue empty after the direct message');

      Future<String?> statusOf(Stack who, Stack peer, String id) async =>
          (await who.messagesWith(peer))
              .where((m) => m.id == id)
              .map((m) => m.status)
              .firstOrNull;

      await until(() async => await statusOf(alice, bob, sent.id) == 'delivered',
          what: 'delivered receipt');
      await bob.chat.markConversationRead(alice.id);
      await until(() async => await statusOf(alice, bob, sent.id) == 'read',
          what: 'read receipt');

      final reply = await bob.chat.sendMessage(alice.id, 'hi alice 👋');
      await until(
          () async => (await alice.messagesWith(bob))
              .any((m) => m.content == 'hi alice 👋' && !m.isFromMe),
          what: 'Alice receives the reply');
      await until(() async => await statusOf(bob, alice, reply.id) == 'delivered',
          what: 'delivered receipt for the reply');

      // ---- reply, react, edit, delete ---------------------------------------
      Future<Message?> find(Stack who, Stack peer, String id) async =>
          (await who.messagesWith(peer)).where((m) => m.id == id).firstOrNull;

      final answer = await bob.chat.sendMessage(alice.id, 'replying to that',
          replyTo: {'id': sent.id, 'from': alice.id, 'preview': 'hello bob, direct'});
      await until(() async => (await find(alice, bob, answer.id))?.replyTo?['id'] == sent.id,
          what: 'Alice sees the reply with its quote');

      await alice.chat.react(bob.id, answer.id, '❤️');
      await until(() async => (await find(bob, alice, answer.id))?.reactions[alice.id] == '❤️',
          what: "Bob sees Alice's reaction");
      await alice.chat.react(bob.id, answer.id, '');
      await until(() async => (await find(bob, alice, answer.id))?.reactions.isEmpty ?? false,
          what: 'the reaction is removed');

      expect(await alice.chat.editMessage(bob.id, sent.id, 'hello bob (edited)'), isTrue);
      await until(() async {
        final m = await find(bob, alice, sent.id);
        return m?.content == 'hello bob (edited)' && m?.editedAt != null;
      }, what: 'Bob sees the edit');
      expect(await bob.chat.editMessage(alice.id, sent.id, 'not yours'), isFalse,
          reason: "can't edit someone else's message");

      // A modified client forging an edit / delete of someone else's message
      // is ignored by the receiver.
      await bob.chat.debugSendRawAction(alice.id, 'edit', sent.id, body: 'forged');
      await bob.chat.debugSendRawAction(alice.id, 'del', sent.id);
      await Future<void>.delayed(const Duration(seconds: 2));
      expect((await find(alice, bob, sent.id))!.content, 'hello bob (edited)');
      expect((await find(alice, bob, sent.id))!.deleted, isFalse);

      expect(await alice.chat.deleteForEveryone(bob.id, sent.id), isTrue);
      await until(() async => (await find(bob, alice, sent.id))?.deleted ?? false,
          what: 'Bob sees it deleted');
      final tomb = await bob.storage.getMessage(sent.id);
      expect(tomb!['content'], '', reason: 'the text is gone, only a tombstone remains');

      // ---- disappearing messages ---------------------------------------------
      await alice.chat.setDisappearing(bob.id, 300);
      await until(() async => await bob.chat.disappearAfter(alice.id) == 300,
          what: 'Bob gets the new timer');
      expect((await bob.messagesWith(alice)).any((m) => m.isSystem && m.content.contains('5 minutes')),
          isTrue);
      final fleeting = await alice.chat.sendMessage(bob.id, 'this will self-destruct');
      expect(fleeting.expiresAt, isNotNull);
      await until(() async => (await find(bob, alice, fleeting.id))?.expiresAt != null,
          what: 'Bob gets it with an expiry');
      // Jump past the deadline on both sides, then sweep.
      for (final who in [alice, bob]) {
        await who.storage.db.update('messages', {'expires_at': 1},
            where: 'id = ?', whereArgs: [fleeting.id]);
        await who.chat.sweepExpired();
      }
      expect(await find(bob, alice, fleeting.id), isNull);
      expect(await find(alice, bob, fleeting.id), isNull);
      await bob.chat.setDisappearing(alice.id, 0);
      await until(() async => await alice.chat.disappearAfter(bob.id) == 0,
          what: 'either side can turn it off');
      final lasting = await alice.chat.sendMessage(bob.id, 'this one stays');
      expect(lasting.expiresAt, isNull);

      // ---- attachments: small ones inside the message, large ones uploaded --
      Future<Message> receivedBy(Stack who, Stack from, String id) async {
        late Message got;
        await until(() async {
          final found = (await who.messagesWith(from))
              .where((m) => m.id == id && m.hasAttachment);
          if (found.isEmpty) return false;
          got = found.first;
          return true;
        }, what: 'attachment message $id arrives');
        return got;
      }

      // Small: an FTS1 string inside the encrypted payload, no upload.
      final small = Uint8List.fromList(
          utf8.encode('quarterly-report: the numbers are fine ' * 200));
      final withSmall = await alice.chat.sendAttachment(bob.id,
          bytes: small, name: 'report-q3.txt', caption: 'see attached');
      expect(withSmall.attachment!['inline'], startsWith('FTS1|'));
      expect(withSmall.attachment!.containsKey('key'), isFalse);
      final gotSmall = await receivedBy(bob, alice, withSmall.id);
      expect(gotSmall.content, 'see attached');
      expect(gotSmall.attachment!['mime'], 'text/plain');
      expect(await bob.chat.attachments.load(gotSmall.attachment!), small);
      await expectLater(
          bob.directory.downloadAttachment(gotSmall.attachment!['id'] as String),
          throwsA(isA<ApiException>()),
          reason: 'the server never had it');

      // Large: encrypted with a fresh key and uploaded; the server holds
      // ciphertext only, without the name.
      final rnd = Random(3);
      final large = Uint8List.fromList(List.generate(300 * 1024, (_) => rnd.nextInt(256)));
      final withLarge = await alice.chat.sendAttachment(bob.id,
          bytes: large, name: 'holiday-video.bin');
      expect(withLarge.attachment!.containsKey('inline'), isFalse);
      final gotLarge = await receivedBy(bob, alice, withLarge.id);
      expect(await bob.chat.attachments.load(gotLarge.attachment!), large);
      final blob =
          await bob.directory.downloadAttachment(gotLarge.attachment!['id'] as String);
      expect(blob.length, large.length + 40);
      expect(blob.sublist(40, 1064), isNot(large.sublist(0, 1024)));
      // Tampering (wrong key) is detected.
      final tampered = Map<String, dynamic>.from(gotLarge.attachment!)
        ..['key'] = base64Encode(List.filled(32, 7));
      bob.chat.attachments.clearMemory();
      await expectLater(bob.chat.attachments.load(tampered), throwsA(anything));
      final convs = await bob.chat.fetchConversations();
      expect(convs.firstWhere((c) => c.contactUserId == alice.id).lastMessage,
          contains('holiday-video.bin'));

      // ---- offline: relay queue -------------------------------------------
      await bob.chat.stop(); // closes Bob's socket and peer connection
      await until(() => !alice.p2p.hasConnectionWithPrefix('${bob.id}:'),
          timeout: const Duration(seconds: 40),
          what: 'Alice notices the direct link is gone');
      await until(() => !(alice.contacts.getContact(bob.id)?.isOnline ?? true),
          what: 'Alice sees Bob offline');

      const secret = 'offline secret 4f9a';
      final queued = await alice.chat.sendMessage(bob.id, secret);
      expect(queued.status, 'sent');

      // What the server holds for Bob is ciphertext only.
      final waiting = await bob.directory.fetchRelayMessages();
      final mine = waiting.where((r) {
        final env = jsonDecode(r['envelope'] as String) as Map<String, dynamic>;
        return env['id'] == queued.id;
      }).toList();
      expect(mine, hasLength(1));
      final env =
          jsonDecode(mine.single['envelope'] as String) as Map<String, dynamic>;
      expect(env.keys.toSet(), {'v', 'id', 's', 'sd', 'rd', 't', 'h', 'c'});
      expect(env['v'], 3);
      expect(env['s'], alice.id);
      expect(env['sd'], alice.auth.deviceId);
      expect(env['rd'], bob.auth.deviceId);
      expect(env['h'], isNot(contains(secret)));
      expect(mine.single['envelope'], isNot(contains(secret)));
      expect(utf8.decode(base64Decode(env['c'] as String), allowMalformed: true),
          isNot(contains(secret)));
      expect(await statusOf(alice, bob, queued.id), 'sent');

      // Bob comes back: the queue is drained, decrypted and acknowledged.
      await bob.startChat();
      await until(
          () async => (await bob.messagesWith(alice))
              .any((m) => m.content == secret && !m.isFromMe),
          what: 'Bob receives the relayed message');
      await until(() async => await statusOf(alice, bob, queued.id) == 'delivered',
          what: 'delivered receipt for the relayed message');
      await until(() async => (await bob.directory.fetchRelayMessages()).isEmpty,
          what: 'relay queue acknowledged and empty');

      // Each message is stored exactly once, bodies encrypted at rest.
      final bobSide = await bob.messagesWith(alice);
      expect(bobSide.where((m) => m.content == secret), hasLength(1));
      final raw = await bob.storage.db.query('messages');
      expect(raw.every((r) => (r['content'] as String).startsWith('enc1:')),
          isTrue);

      // ---- Bob verifies Alice ------------------------------------------------
      expect(await bob.chat.verificationOf(alice.id), Verification.unverified);
      await bob.chat.markVerified(alice.id);
      expect(await bob.chat.verificationOf(alice.id), Verification.verified);

      // ---- a second device for Alice ----------------------------------------
      final laptop = Stack('alice_laptop');
      final alerts = alice.auth.deviceEvents.where((e) => e['type'] == 'device_pending').first;
      await laptop.signInAs(alice);
      expect(laptop.id, alice.id);
      expect(laptop.auth.deviceId, isNot(alice.auth.deviceId));
      // A second sign-in waits for approval: no keys are handed out for it.
      expect(laptop.auth.deviceApproved, isFalse);
      expect(laptop.auth.homeRoute, '/device-pending');
      expect(await bob.chat.devicesOf(alice.id, refresh: true), hasLength(1));
      final alert = await alerts.timeout(const Duration(seconds: 10));
      expect(alert['device_id'], laptop.auth.deviceId, reason: 'sign-in alert on the phone');
      // The phone approves it with its own key.
      final pending = (await alice.auth.listDevices())
          .firstWhere((d) => d['device_id'] == laptop.auth.deviceId);
      expect(pending['approved'], isFalse);
      expect(await alice.auth.approveDevice(pending), isTrue, reason: alice.auth.errorMessage);
      await until(() => laptop.auth.refreshDeviceApproval(), what: 'the laptop sees it is approved');
      await laptop.startChat();
      await until(
          () async => (await bob.chat.devicesOf(alice.id, refresh: true)).length == 2,
          what: "Bob sees Alice's second device");
      await until(
          () async => (await bob.messagesWith(alice))
              .any((m) => m.isSystem && m.content.contains('new device')),
          what: 'Bob is told her devices changed');

      // Her keys changed after Bob verified her: nothing goes out until he
      // checks again.
      expect(await bob.chat.verificationOf(alice.id), Verification.changed);
      await until(
          () async => (await bob.messagesWith(alice))
              .any((m) => m.isSystem && m.content.contains('sending is paused')),
          what: 'Bob is told sending is paused');
      final held = await bob.chat.sendMessage(alice.id, 'held until verified');
      expect(held.status, 'failed', reason: 'not encrypted to unverified keys');
      await Future<void>.delayed(const Duration(seconds: 1));
      expect((await alice.messagesWith(bob)).any((m) => m.id == held.id), isFalse);
      await bob.chat.markVerified(alice.id);
      expect(await bob.chat.verificationOf(alice.id), Verification.verified);
      await until(
          () async => (await laptop.messagesWith(bob)).any((m) => m.id == held.id),
          what: 'the held message goes out after verifying again');

      // Bob writes once: both of Alice's devices receive it.
      final toBoth = await bob.chat.sendMessage(alice.id, 'to all your devices');
      expect(toBoth.status, anyOf('sent', 'delivered', 'read'));
      await until(
          () async => (await laptop.messagesWith(bob))
              .any((m) => m.id == toBoth.id && !m.isFromMe),
          what: 'the laptop receives it');
      await until(
          () async => (await alice.messagesWith(bob))
              .any((m) => m.id == toBoth.id && !m.isFromMe),
          what: 'the phone receives it');

      // Alice writes from the laptop: Bob gets it, the phone gets a copy.
      final fromLaptop = await laptop.chat.sendMessage(bob.id, 'sent from my laptop');
      await until(
          () async => (await bob.messagesWith(alice))
              .any((m) => m.id == fromLaptop.id && !m.isFromMe),
          what: 'Bob receives the laptop message');
      await until(
          () async => (await alice.messagesWith(bob))
              .any((m) => m.id == fromLaptop.id && m.isFromMe),
          what: "the phone shows it as Alice's own message");

      // Reading on the laptop clears the phone's unread badge.
      await alice.chat.ensureConversation(bob.id);
      Future<int> unreadOnPhone() async => (await alice.chat.fetchConversations())
          .firstWhere((c) => c.contactUserId == bob.id)
          .unreadCount;
      expect(await unreadOnPhone(), greaterThan(0));
      await laptop.chat.markConversationRead(bob.id);
      await until(() async => await unreadOnPhone() == 0,
          what: 'read state synced to the phone');

      // Every party computes the same safety number over all devices.
      final snBob = await bob.chat.safetyNumberFor(alice.id);
      expect(snBob, isNotNull);
      expect(await alice.chat.safetyNumberFor(bob.id), snBob);
      expect(await laptop.chat.safetyNumberFor(bob.id), snBob);

      // Unlinking the laptop from the phone signs it out.
      final laptopDevice = laptop.auth.deviceId!;
      final listed = await alice.directory.listMyDevices();
      expect(listed.map((d) => d['device_id']), contains(laptopDevice));
      await alice.directory.removeDevice(laptopDevice);
      await until(() => laptop.auth.status == AuthStatus.unauthenticated,
          what: 'the unlinked laptop is signed out');
      await until(
          () async => (await bob.chat.devicesOf(alice.id, refresh: true)).length == 1,
          what: 'Bob stops encrypting to the laptop');
      await laptop.chat.stop();
      await laptop.storage.close();
      await laptop.p2p.dispose();
      await laptop.directory.dispose();

      // ---- sign out revokes the session -----------------------------------
      final oldToken = alice.directory.session!.token;
      final client = HttpClient();
      Future<int> me() async {
        final req = await client.getUrl(Uri.parse('$_baseUrl/api/me'));
        req.headers.set('Authorization', 'Bearer $oldToken');
        final res = await req.close();
        await res.drain<void>();
        return res.statusCode;
      }

      expect(await me(), 200);
      final deviceBefore = alice.auth.deviceId;
      await alice.chat.stop();
      await alice.auth.signOut();
      expect(alice.auth.status, AuthStatus.unauthenticated);
      expect(await me(), 401);
      client.close();

      // Signing back in on the same device keeps keys and history.
      expect(
          await alice.auth.signIn(email: alice.email, password: Stack.password),
          isTrue,
          reason: alice.auth.errorMessage);
      expect((await alice.messagesWith(bob)).any((m) => m.content == secret),
          isTrue);
      expect(alice.auth.deviceId, deviceBefore, reason: 'same device, same id');

      // ---- block and report -------------------------------------------------
      await alice.startChat();
      expect(await bob.contacts.reportUser(alice.id,
              reason: 'spam',
              details: 'test report',
              evidence: [
                {'from': 'reported', 'text': 'hello bob, direct', 'at': null}
              ]),
          isTrue);
      expect(await bob.contacts.blockUser(alice.id), isTrue);
      expect(bob.contacts.getContact(alice.id), isNull);
      expect(bob.contacts.blockedUsers.map((b) => b['user_id']), [alice.id]);
      await until(() async {
        await alice.contacts.loadContacts(silent: true);
        return alice.contacts.getContact(bob.id) == null;
      }, what: 'Alice loses the contact');
      final afterBlock = await alice.chat.sendMessage(bob.id, 'can you hear me?');
      expect(afterBlock.status, 'failed', reason: 'blocked: nothing gets through');
      expect(await alice.directory.searchUsers(bob.username), isEmpty);
      expect(await bob.contacts.unblockUser(alice.id), isTrue);
      expect((await alice.directory.searchUsers(bob.username)).length, 1);
    });
  }, timeout: const Timeout(Duration(minutes: 4)));
}
