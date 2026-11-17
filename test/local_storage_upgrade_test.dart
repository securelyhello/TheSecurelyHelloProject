import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/storage/local_storage.dart';

void main() {
  sqfliteFfiInit();

  test('a v2 database (account keys, no devices) upgrades to v3 in place', () async {
    final dir = Directory.systemTemp.createTempSync('sh_upgrade');
    final path = p.join(dir.path, 'securelyhello_u1.db');
    // The schema shipped before multi-device.
    final old = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE messages (id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, '
                "sender_id TEXT NOT NULL, content TEXT NOT NULL, timestamp INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'sending', "
                "is_from_me INTEGER NOT NULL DEFAULT 0, kind TEXT NOT NULL DEFAULT 'text')");
            await db.execute('CREATE TABLE conversations (id TEXT PRIMARY KEY, contact_user_id TEXT NOT NULL, '
                'last_message TEXT, last_message_time INTEGER, unread_count INTEGER NOT NULL DEFAULT 0)');
            await db.execute('CREATE TABLE contacts_cache (user_id TEXT PRIMARY KEY, username TEXT, display_name TEXT, '
                'avatar_url TEXT, public_signing_key TEXT, public_encryption_key TEXT, '
                'is_online INTEGER NOT NULL DEFAULT 0, last_seen INTEGER)');
          },
        ));
    await old.insert('messages', {
      'id': 'm1', 'conversation_id': 'bob', 'sender_id': 'bob', 'content': 'old plaintext',
      'timestamp': 1, 'status': 'read', 'is_from_me': 0, 'kind': 'text',
    });
    await old.insert('contacts_cache', {'user_id': 'bob', 'display_name': 'Bob', 'public_signing_key': 'k', 'public_encryption_key': 'e'});
    await old.close();

    final storage = LocalStorage(databaseFactory: databaseFactoryFfi, baseDirectory: () async => dir.path);
    await storage.openForUser('u1', encryptionKey: CryptoCore.randomBytes(32));
    final msgs = await storage.getMessages('bob');
    expect(msgs.single['content'], 'old plaintext', reason: 'history survives');
    expect(msgs.single['attachment'], isNull);
    expect((await storage.getCachedContact('bob'))!['public_signing_key'], isNull,
        reason: 'account-level keys are dropped');
    expect(await storage.markEnvelopeSeen('e1'), isTrue);
    expect(await storage.markEnvelopeSeen('e1'), isFalse);
    await storage.kvSet('device_id', 'd1');
    expect(await storage.kvGet('device_id'), 'd1');
    await storage.close();
  });
}
