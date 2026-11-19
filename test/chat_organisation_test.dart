import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/storage/local_storage.dart';

// 1.1: pinned and archived chats, drafts, starred and forwarded messages.
void main() {
  sqfliteFfiInit();
  late Directory dir;
  late LocalStorage storage;
  final key = CryptoCore.randomBytes(32);

  Future<void> open() async {
    storage = LocalStorage(databaseFactory: databaseFactoryFfi, baseDirectory: () async => dir.path);
    await storage.openForUser('u1', encryptionKey: key);
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sh_org');
    await open();
    await storage.updateConversation(id: 'bob', contactUserId: 'bob', lastMessage: 'hi', lastMessageTime: 1);
    await storage.insertMessage(
        id: 'm1', conversationId: 'bob', senderId: 'bob', content: 'secret plans', timestamp: 1, status: 'read', isFromMe: false);
  });

  tearDown(() async {
    await storage.close();
    dir.deleteSync(recursive: true);
  });

  Future<Map<String, dynamic>> conv() async => (await storage.getConversations()).firstWhere((c) => c['id'] == 'bob');

  test('pin and archive a chat', () async {
    expect((await conv())['pinned'], 0);
    await storage.setPinned('bob', true);
    await storage.setArchived('bob', true);
    expect((await conv())['pinned'], 1);
    expect((await conv())['archived'], 1);
    await storage.setArchived('bob', false);
    expect((await conv())['archived'], 0);
  });

  test('drafts are kept per chat and sealed at rest', () async {
    expect(await storage.getDraft('bob'), isNull);
    await storage.setDraft('bob', 'see you at');
    expect(await storage.getDraft('bob'), 'see you at');
    final raw = await storage.db.query('conversations', where: "id = 'bob'");
    expect('${raw.single['draft']}', isNot(contains('see you')));
    await storage.setDraft('bob', '  ');
    expect(await storage.getDraft('bob'), isNull, reason: 'blank clears it');
  });

  test('starred messages', () async {
    expect(await storage.getStarredMessages(), isEmpty);
    await storage.setStarred('m1', true);
    final starred = await storage.getStarredMessages();
    expect(starred.single['content'], 'secret plans', reason: 'decrypted');
    expect((await storage.getMessage('m1'))!['starred'], 1);
    await storage.setStarred('m1', false);
    expect(await storage.getStarredMessages(), isEmpty);
  });

  test('forwarded messages are marked', () async {
    await storage.insertMessage(
        id: 'm2', conversationId: 'bob', senderId: 'me', content: 'fwd', timestamp: 2, status: 'sent', isFromMe: true,
        forwarded: true);
    expect((await storage.getMessage('m2'))!['forwarded'], 1);
    expect((await storage.getMessage('m1'))!['forwarded'], 0);
  });

  test('a 1.0 database (v6) upgrades in place', () async {
    await storage.close();
    final path = p.join(dir.path, (await Directory(dir.path).list().firstWhere((f) => f.path.endsWith('.db'))).path.split('/').last);
    final raw = await databaseFactoryFfi.openDatabase(path);
    for (final c in ['pinned', 'archived', 'draft']) {
      await raw.execute('ALTER TABLE conversations DROP COLUMN $c');
    }
    await raw.execute('DROP INDEX idx_messages_starred');
    for (final c in ['starred', 'forwarded']) {
      await raw.execute('ALTER TABLE messages DROP COLUMN $c');
    }
    await raw.setVersion(6);
    await raw.close();
    await open();
    expect((await storage.getMessages('bob')).single['content'], 'secret plans', reason: 'history survives');
    await storage.setPinned('bob', true);
    expect((await conv())['pinned'], 1);
    expect((await storage.getMessage('m1'))!['starred'], 0);
  });
}
