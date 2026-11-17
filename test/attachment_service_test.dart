import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/chat/attachment_service.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';

/// Blob store in memory: what the server keeps (ciphertext).
class FakeBlobs extends DirectoryService {
  final Map<String, Uint8List> blobs = {};
  int downloads = 0;
  FakeBlobs()
      : super(baseUrl: 'http://fake.invalid', tokenStore: SecureKeyStore(storage: MemorySecretStorage()));

  @override
  Future<String> uploadAttachment(Uint8List ciphertext) async {
    final id = '00000000-0000-4000-8000-${blobs.length.toString().padLeft(12, '0')}';
    blobs[id] = Uint8List.fromList(ciphertext);
    return id;
  }

  @override
  Future<Uint8List> downloadAttachment(String id) async {
    downloads++;
    final b = blobs[id];
    if (b == null) throw const ApiException(404, 'not_found', 'gone');
    return b;
  }
}

void main() {
  late FakeBlobs server;
  late Directory senderDir;
  late Directory receiverDir;
  late AttachmentService sender;
  late AttachmentService receiver;

  setUp(() {
    server = FakeBlobs();
    senderDir = Directory.systemTemp.createTempSync('sh_att_s');
    receiverDir = Directory.systemTemp.createTempSync('sh_att_r');
    sender = AttachmentService(directory: server, cacheDirectory: () async => senderDir.path);
    receiver = AttachmentService(directory: server, cacheDirectory: () async => receiverDir.path);
  });

  final file = Uint8List.fromList(utf8.encode('secret plans ' * 500));

  test('round trip: only ciphertext is uploaded; the receiver decrypts it', () async {
    final meta = await sender.upload(file, name: '../../etc/plans.txt');
    expect(meta['name'], 'plans.txt', reason: 'path components stripped');
    expect(meta['mime'], 'text/plain');
    expect(meta['size'], file.length);
    final blob = server.blobs[meta['id']]!;
    expect(blob.length, file.length + 40);
    expect(utf8.decode(blob, allowMalformed: true), isNot(contains('secret')));

    expect(await receiver.load(meta), file);
    expect(server.downloads, 1);
    // Cached on disk, still encrypted.
    final cached = File('${receiverDir.path}/${meta['id']}.bin').readAsBytesSync();
    expect(cached, blob);
    receiver.clearMemory();
    expect(await receiver.load(meta), file);
    expect(server.downloads, 1, reason: 'served from the disk cache');
  });

  test('a swapped blob or wrong key is detected', () async {
    final meta = await sender.upload(file, name: 'a.txt');
    final other = await sender.upload(Uint8List.fromList([1, 2, 3, 4]), name: 'b.bin');
    final swapped = {...meta, 'id': other['id']};
    await expectLater(receiver.load(swapped), throwsA(isA<AttachmentCorruptException>()));
    final wrongKey = {...meta, 'key': base64Encode(List.filled(32, 9))};
    await expectLater(receiver.load(wrongKey), throwsA(isA<AttachmentCorruptException>()));
  });

  test('size limit and helpers', () async {
    await expectLater(
        sender.upload(Uint8List(AttachmentService.maxBytes + 1), name: 'big.bin'),
        throwsA(isA<AttachmentTooLargeException>()));
    expect(AttachmentService.isImage({'mime': 'image/png'}), isTrue);
    expect(AttachmentService.isImage({'mime': 'image/svg+xml'}), isFalse);
    expect(AttachmentService.formatSize(1536), '2 KB');
    expect(AttachmentService.formatSize(3 * 1024 * 1024), '3.0 MB');
  });
}
