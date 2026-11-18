import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:securelyhello/core/backup/chat_backup.dart';
import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/storage/local_storage.dart';

Future<LocalStorage> openStorage(String user) async {
  final dir = await Directory.systemTemp.createTemp('sh_bk_');
  final s = LocalStorage(databaseFactory: databaseFactoryFfi, baseDirectory: () async => dir.path);
  await s.openForUser(user, encryptionKey: CryptoCore.randomBytes(32));
  return s;
}

void main() {
  sqfliteFfiInit();

  group('backup key', () {
    test('25 unambiguous characters in five groups', () {
      final k = ChatBackup.newKey();
      expect(RegExp(r'^([a-km-np-z2-9]{5}-){4}[a-km-np-z2-9]{5}$').hasMatch(k), isTrue, reason: k);
      expect(ChatBackup.newKey(), isNot(k));
    });

    test('typed with spaces, capitals or no dashes still works', () {
      final k = ChatBackup.newKey();
      expect(ChatBackup.normalizeKey(k.toUpperCase().replaceAll('-', ' ')), k.replaceAll('-', ''));
      expect(ChatBackup.normalizeKey('too-short'), isNull);
      expect(ChatBackup.normalizeKey('l' * 25), isNull, reason: 'l is not in the alphabet');
    });
  });

  group('backup file', () {
    final history = {
      'messages': [
        {'id': 'm1', 'conversation_id': 'c', 'sender_id': 'c', 'content': 'hello', 'timestamp': 1}
      ],
    };

    test('opens with the right key and account only', () async {
      final key = ChatBackup.newKey();
      final file = await ChatBackup.seal(history, userId: 'me', backupKey: key);
      expect(utf8.decode(file.sublist(0, 5)), 'SHBK1');
      expect(utf8.decode(file, allowMalformed: true), isNot(contains('hello')), reason: 'encrypted');

      final back = await ChatBackup.open(file, userId: 'me', backupKey: key.toUpperCase());
      expect((back['messages'] as List).single['content'], 'hello');

      await expectLater(ChatBackup.open(file, userId: 'me', backupKey: ChatBackup.newKey()),
          throwsA(isA<BackupException>()));
      await expectLater(ChatBackup.open(file, userId: 'someone else', backupKey: key),
          throwsA(isA<BackupException>()));
      final tampered = Uint8List.fromList(file)..[file.length - 3] ^= 1;
      await expectLater(ChatBackup.open(tampered, userId: 'me', backupKey: key), throwsA(isA<BackupException>()));
      await expectLater(ChatBackup.open(Uint8List.fromList(utf8.encode('not a backup')), userId: 'me', backupKey: key),
          throwsA(isA<BackupException>()));
    });
  });

  group('history export and import', () {
    test('round trip into a fresh database; disappearing and deleted messages stay behind', () async {
      final a = await openStorage('me');
      Future<void> msg(String id, String text, {int? expiresAt}) => a.insertMessage(
          id: id,
          conversationId: 'mira',
          senderId: 'mira',
          content: text,
          timestamp: int.parse(id.substring(1)),
          status: 'read',
          isFromMe: false,
          attachment: id == 'm2' ? jsonEncode({'id': 'x', 'inline': 'FTS1:...'}) : null,
          expiresAt: expiresAt);
      await msg('m1', 'first');
      await msg('m2', 'with a file');
      await msg('m3', 'vanishes', expiresAt: DateTime.now().millisecondsSinceEpoch + 60000);
      await msg('m4', 'deleted');
      await a.tombstoneMessage('m4');
      await a.setReaction('m1', 'me', '👍', 5);
      await a.updateConversation(id: 'mira', contactUserId: 'mira', lastMessage: 'with a file', lastMessageTime: 2);

      final exported = await a.exportHistory();
      final ids = [for (final m in exported['messages'] as List) m['id']];
      expect(ids, ['m1', 'm2']);

      final b = await openStorage('me');
      expect(await b.importHistory(exported), 2);
      expect((await b.getMessage('m1'))!['content'], 'first');
      expect(jsonDecode((await b.getMessage('m2'))!['attachment'] as String)['id'], 'x');
      expect(await b.getMessage('m3'), isNull);
      expect((await b.getConversations()).single['last_message'], 'with a file');
      final raw = await b.db.query('messages', where: "id = 'm1'");
      expect(raw.single['content'], isNot(contains('first')), reason: 'sealed at rest after import');

      expect(await b.importHistory(exported), 0, reason: 'importing again changes nothing');
      await expectLater(b.importHistory({'messages': [{'id': 5}]}), throwsFormatException);
      await a.close();
      await b.close();
    });
  });
}
