import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/storage/local_storage.dart';

void main() {
  sqfliteFfiInit();

  test('a group message is as far along as its slowest recipient', () async {
    final dir = await Directory.systemTemp.createTemp('sh_gr_');
    final s = LocalStorage(databaseFactory: databaseFactoryFfi, baseDirectory: () async => dir.path);
    await s.openForUser('me', encryptionKey: CryptoCore.randomBytes(32));
    await s.insertMessage(
        id: 'm1', conversationId: 'g_x', senderId: 'me', content: 'hi', timestamp: 1, status: 'sending', isFromMe: true);

    await s.addGroupRecipients('m1', ['bob', 'carol']);
    expect(await s.groupReceipts('m1'), {'bob': 'sending', 'carol': 'sending'});
    expect(await s.applyGroupReceipt('m1', 'bob', 'sent'), 'sending', reason: 'carol not reached yet');
    expect(await s.applyGroupReceipt('m1', 'carol', 'sent'), 'sent');
    expect(await s.applyGroupReceipt('m1', 'bob', 'read'), 'sent');
    expect(await s.applyGroupReceipt('m1', 'carol', 'delivered'), 'delivered');
    expect(await s.applyGroupReceipt('m1', 'bob', 'delivered'), 'delivered');
    expect((await s.groupReceipts('m1'))['bob'], 'read', reason: 'a late receipt never lowers it');
    expect(await s.applyGroupReceipt('m1', 'mallory', 'read'), isNull, reason: 'not a recipient');

    await s.addGroupRecipients('m1', ['bob', 'dan']);
    expect((await s.groupReceipts('m1'))['bob'], 'read', reason: 'adding again keeps what we know');
    expect(await s.removeGroupRecipient('m1', 'dan'), 'delivered', reason: 'a member who left stops holding it back');

    await s.clearConversation('g_x');
    expect(await s.groupReceipts('m1'), isEmpty, reason: 'cleared with the chat');
    await s.close();
  });
}
