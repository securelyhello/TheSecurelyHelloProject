import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';

void main() {
  sqfliteFfiInit();

  late Directory dir;
  late LocalStorage storage;
  late ChatService chat;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sh_verify');
    storage = LocalStorage(databaseFactory: databaseFactoryFfi, baseDirectory: () async => dir.path);
    await storage.openForUser('me', encryptionKey: CryptoCore.randomBytes(32));
    chat = ChatService(
      storage: storage,
      p2p: P2PConnectionManager(),
      directory: DirectoryService(
          baseUrl: 'https://fake.invalid',
          tokenStore: SecureKeyStore(storage: MemorySecretStorage())),
    );
  });

  tearDown(() async {
    await storage.close();
    dir.deleteSync(recursive: true);
  });

  test('a contact never verified is unverified', () async {
    expect(await chat.verificationOf('bob'), Verification.unverified);
  });

  test('a pinned contact with no known devices is not reported as verified', () async {
    // Something was pinned, but no keys are available to check it against
    // (empty device list from the server, or sessions not started yet).
    await storage.kvSet('verified:bob', ChatService.keySetDigest(const []));
    expect(await chat.verificationOf('bob'), Verification.unverified);
    await storage.kvSet('verified:bob', 'some-earlier-digest');
    expect(await chat.verificationOf('bob'), Verification.unverified);
  });

  test('the pin is kept so verification comes back with the same keys', () async {
    await storage.kvSet('verified:bob', 'some-earlier-digest');
    await chat.verificationOf('bob');
    expect(await storage.kvGet('verified:bob'), 'some-earlier-digest');
  });
}
