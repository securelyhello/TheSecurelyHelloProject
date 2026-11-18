import 'dart:convert';
import 'dart:io';
import 'dart:math';
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
      : super(baseUrl: 'https://fake.invalid', tokenStore: SecureKeyStore(storage: MemorySecretStorage()));

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

  // Large and incompressible: too big to travel inside a message.
  final rng = Random(7);
  final file = Uint8List.fromList(List.generate(100000, (_) => rng.nextInt(256)));
  final small = Uint8List.fromList(utf8.encode('secret plans ' * 500));

  test('round trip: only ciphertext is uploaded; the receiver decrypts it', () async {
    final meta = await sender.upload(file, name: '../../etc/plans.txt');
    expect(meta['name'], 'plans.txt', reason: 'path components stripped');
    expect(meta['mime'], 'text/plain');
    expect(meta['size'], file.length);
    expect(AttachmentService.isInline(meta), isFalse);
    final blob = server.blobs[meta['id']]!;
    expect(blob.length, file.length + 40);
    expect(blob.sublist(40, 140), isNot(file.sublist(0, 100)), reason: 'ciphertext, not the file');

    expect(await receiver.load(meta), file);
    expect(server.downloads, 1);
    // Cached on disk, still encrypted.
    final cached = File('${receiverDir.path}/${meta['id']}.bin').readAsBytesSync();
    expect(cached, blob);
    receiver.clearMemory();
    expect(await receiver.load(meta), file);
    expect(server.downloads, 1, reason: 'served from the disk cache');
  });

  // Audit run 1, U4-4: a contact reusing an attachment's id could replace
  // our cached bytes or delete our cached file.
  test("another attachment with the same id can't swap or evict the cached one", () async {
    final mine = await sender.upload(file, name: 'mine.bin');
    expect(await sender.load(mine), file);
    final spoof = await receiver.upload(utf8.encode('spoofed by a contact'), name: 'x.txt');
    final forged = {...spoof, 'id': mine['id']};
    expect(utf8.decode(await sender.load(forged)), 'spoofed by a contact');
    expect(await sender.load(mine), file, reason: 'the original bytes are untouched');
    await sender.forget(forged);
    expect(File('${senderDir.path}/${mine['id']}.bin').existsSync(), isTrue,
        reason: "forgetting the forged one keeps our file");
  });

  test('small files travel inside the message: nothing is uploaded', () async {
    final meta = await sender.upload(small, name: 'notes/plans.txt');
    expect(AttachmentService.isInline(meta), isTrue);
    expect(server.blobs, isEmpty, reason: 'no server holds it');
    expect(meta['name'], 'plans.txt');
    expect(meta.containsKey('key'), isFalse);
    expect((meta['inline'] as String).startsWith('FTS1|'), isTrue);
    expect((meta['inline'] as String).length, lessThanOrEqualTo(AttachmentService.inlineMaxChars));
    expect(await receiver.load(meta), small);
    expect(server.downloads, 0);
    expect(await receiver.isAvailableOffline(meta), isTrue);

    // A corrupted inline string is rejected (size + SHA-256 in the codec).
    final s = meta['inline'] as String;
    final bad = {...meta, 'id': 'x', 'inline': '${s.substring(0, s.length - 8)}AAAAAAAA'};
    receiver.clearMemory();
    await expectLater(receiver.load(bad), throwsA(isA<AttachmentCorruptException>()));
  });

  test('the inline cutoff follows the encoded size, not the raw size', () async {
    // 40 KB of zeros compresses to almost nothing: inline.
    final zeros = await sender.upload(Uint8List(40 * 1024), name: 'zeros.bin');
    expect(AttachmentService.isInline(zeros), isTrue);
    // 40 KB of random bytes grows past 48 KB in base64: uploaded.
    final noise = await sender.upload(
        Uint8List.fromList(List.generate(40 * 1024, (_) => rng.nextInt(256))), name: 'noise.bin');
    expect(AttachmentService.isInline(noise), isFalse);
    expect(server.blobs, hasLength(1));
  });

  test('a swapped blob or wrong key is detected', () async {
    final meta = await sender.upload(file, name: 'a.txt');
    final other = await sender.upload(
        Uint8List.fromList(List.generate(90000, (_) => rng.nextInt(256))), name: 'b.bin');
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
