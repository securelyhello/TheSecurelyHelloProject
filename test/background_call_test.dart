import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:securelyhello/core/calls/call_service.dart';
import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/notifications/push_background.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';

// Security review L1 (the decrypted offer isn't kept in plain preferences)
// and L2 (only contacts ring with the app closed).
void main() {
  sqfliteFfiInit();
  TestWidgetsFlutterBinding.ensureInitialized();

  CallSignal offer({String from = 'bob', Duration age = Duration.zero, String t = 'offer'}) => CallSignal(
        from: from,
        fromDevice: 'd1',
        sentAt: DateTime.now().subtract(age),
        data: {'id': 'call1', 't': t, 'sdp': 'v=0 secret-sdp', 'video': false},
      );

  group('ringing in the background', () {
    const contacts = {'bob': 'Bob'};
    test('a fresh offer from a contact rings', () {
      expect(shouldRingInBackground(offer(), contacts: contacts), isTrue);
    });
    test('a stranger does not', () {
      expect(shouldRingInBackground(offer(from: 'mallory'), contacts: contacts), isFalse);
      expect(shouldRingInBackground(offer(), contacts: const {}), isFalse);
    });
    test('an old offer or another signal does not', () {
      expect(shouldRingInBackground(offer(age: const Duration(minutes: 5)), contacts: contacts), isFalse);
      expect(shouldRingInBackground(offer(t: 'ice'), contacts: contacts), isFalse);
    });
  });

  group('stashed offer', () {
    late Directory dir;
    late LocalStorage storage;
    late ChatService chat;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dir = Directory.systemTemp.createTempSync('sh_stash');
      storage = LocalStorage(databaseFactory: databaseFactoryFfi, baseDirectory: () async => dir.path);
      await storage.openForUser('me', encryptionKey: CryptoCore.randomBytes(32));
      chat = ChatService(
        storage: storage,
        p2p: P2PConnectionManager(),
        directory: DirectoryService(
            baseUrl: 'https://fake.invalid', tokenStore: SecureKeyStore(storage: MemorySecretStorage())),
      );
    });

    tearDown(() async {
      await storage.close();
      dir.deleteSync(recursive: true);
    });

    test('is sealed in the database, not in shared preferences', () async {
      await CallService.stashOffer(offer(), chat);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty);
      final raw = await storage.kvGet(CallService.pendingOfferKey);
      expect(raw, isNotNull);
      expect(raw, isNot(contains('secret-sdp')));
    });

    test('is taken once', () async {
      await CallService.stashOffer(offer(), chat);
      final s = await chat.takeStashedCallOffer();
      expect(s?.from, 'bob');
      expect(s?.data['sdp'], 'v=0 secret-sdp');
      expect(await chat.takeStashedCallOffer(), isNull);
    });

    test('a 1.1.0 offer left in preferences is removed unread', () async {
      SharedPreferences.setMockInitialValues({CallService.pendingOfferKey: '{"from":"bob"}'});
      expect(await chat.takeStashedCallOffer(), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(CallService.pendingOfferKey), isNull);
    });
  });
}
