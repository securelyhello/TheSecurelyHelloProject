// Regression tests for app findings of security audit run 1
// (docs/security-audit/run-1/REPORT.md).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/storage/local_storage.dart';

void main() {
  sqfliteFfiInit();

  test('U4-3: a contact\'s clock is kept within the delivery window', () {
    final now = DateTime(2026, 11, 18, 12);
    final ms = now.millisecondsSinceEpoch;
    expect(ChatService.arrivalTime(ms - 1000, now: now), ms - 1000);
    expect(ChatService.arrivalTime(ms - const Duration(days: 30).inMilliseconds, now: now),
        ms - const Duration(hours: 25).inMilliseconds,
        reason: 'a backdated edit lands at most 25 h back');
    expect(ChatService.arrivalTime(ms + const Duration(days: 1).inMilliseconds, now: now),
        ms + const Duration(minutes: 5).inMilliseconds);
  });

  test('U4-5: text that looks sealed is sealed too', () async {
    final dir = await Directory.systemTemp.createTemp('sh_seal_');
    final storage = LocalStorage(databaseFactory: databaseFactoryFfi, baseDirectory: () async => dir.path);
    await storage.openForUser('me', encryptionKey: CryptoCore.randomBytes(32));
    await storage.insertMessage(
      id: 'm1',
      conversationId: 'c',
      senderId: 'c',
      content: 'enc1:my bank PIN is 1234',
      timestamp: 1,
      status: 'received',
      isFromMe: false,
    );
    final raw = await storage.db.query('messages', where: 'id = ?', whereArgs: ['m1']);
    expect(raw.single['content'], isNot(contains('my bank PIN')));
    final read = await storage.getMessage('m1');
    expect(read!['content'], 'enc1:my bank PIN is 1234');
    await storage.close();
    await dir.delete(recursive: true);
  });
}
