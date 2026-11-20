import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/crypto/device_manager.dart';
import 'package:securelyhello/core/crypto/own_device_trust.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';

/// The server's list of our devices (GET /api/users/:me/devices). It has no
/// approved_at: only approved devices are listed.
class OwnDevicesDirectory extends DirectoryService {
  OwnDevicesDirectory()
      : super(baseUrl: 'https://fake.invalid', tokenStore: SecureKeyStore(storage: MemorySecretStorage()));

  List<Map<String, dynamic>> rows = [];
  bool offline = false;

  @override
  Future<List<Map<String, dynamic>>> getUserDevices(String userId) async {
    if (offline) throw const SocketException('offline');
    return rows;
  }
}

// Security review M1: copies to and payloads from our own devices only for
// devices this device trusts, and never "everything" while unknown.
void main() {
  sqfliteFfiInit();
  const me = 'me';
  final phone = CryptoCore.generateIdentity(); // this device
  final laptop = CryptoCore.generateIdentity();
  final tablet = CryptoCore.generateIdentity();
  final rogue = CryptoCore.generateIdentity();

  Map<String, dynamic> row(String id, CryptoIdentity identity, {String? approvedBy, String? signature}) => {
        'device_id': id,
        'signing_public_key': identity.publicSigningKeyBase64,
        'identity_public_key': identity.publicEncryptionKeyBase64,
        'approved_by': approvedBy,
        'approval_signature': signature,
      };

  String approve(CryptoIdentity by, String id, CryptoIdentity target) =>
      DeviceManager.signApproval(by, me, id, target.publicSigningKeyBase64, target.publicEncryptionKeyBase64);

  late Directory dir;
  late LocalStorage storage;
  late OwnDevicesDirectory directory;
  late ChatService chat;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sh_own_trust');
    storage = LocalStorage(databaseFactory: databaseFactoryFfi, baseDirectory: () async => dir.path);
    await storage.openForUser(me, encryptionKey: CryptoCore.randomBytes(32));
    directory = OwnDevicesDirectory();
    chat = ChatService(storage: storage, p2p: P2PConnectionManager(), directory: directory);
    chat.debugUseAccount(userId: me, deviceId: 'phone', identity: phone);
  });

  tearDown(() async {
    await storage.close();
    dir.deleteSync(recursive: true);
  });

  group('ownDeviceAllowed', () {
    test('unknown trust: only this device', () {
      expect(ChatService.ownDeviceAllowed(null, deviceId: 'phone', signingKey: 'k', thisDevice: 'phone'), isTrue);
      expect(ChatService.ownDeviceAllowed(null, deviceId: 'laptop', signingKey: 'k', thisDevice: 'phone'), isFalse);
    });

    test('known trust: the device with the same signing key', () {
      final t = {'laptop': 'k1'};
      expect(ChatService.ownDeviceAllowed(t, deviceId: 'laptop', signingKey: 'k1', thisDevice: 'phone'), isTrue);
      expect(ChatService.ownDeviceAllowed(t, deviceId: 'laptop', signingKey: 'k2', thisDevice: 'phone'), isFalse);
      expect(ChatService.ownDeviceAllowed(t, deviceId: 'laptop', signingKey: null, thisDevice: 'phone'), isFalse);
      expect(ChatService.ownDeviceAllowed(t, deviceId: 'tablet', signingKey: 'k1', thisDevice: 'phone'), isFalse);
    });
  });

  test('before any check, no other device of ours is trusted (fails closed)', () {
    expect(chat.isOwnDeviceTrusted('laptop', laptop.publicSigningKeyBase64), isFalse);
  });

  test('the stored map is loaded before anything is sent', () async {
    await storage.kvSet('own_trusted', OwnDeviceTrust.encode({'laptop': laptop.publicSigningKeyBase64}));
    await chat.loadOwnTrust();
    expect(chat.isOwnDeviceTrusted('laptop', laptop.publicSigningKeyBase64), isTrue);
    expect(chat.isOwnDeviceTrusted('laptop', rogue.publicSigningKeyBase64), isFalse);
    expect(chat.isOwnDeviceTrusted('rogue', rogue.publicSigningKeyBase64), isFalse);
  });

  test('a failed refresh keeps the stored map', () async {
    await storage.kvSet('own_trusted', OwnDeviceTrust.encode({'laptop': laptop.publicSigningKeyBase64}));
    await chat.loadOwnTrust();
    directory.offline = true;
    await chat.refreshOwnTrust();
    expect(chat.isOwnDeviceTrusted('laptop', laptop.publicSigningKeyBase64), isTrue);
    expect(OwnDeviceTrust.decode(await storage.kvGet('own_trusted')), {'laptop': laptop.publicSigningKeyBase64});
  });

  test('a failed first refresh (nothing stored) still trusts nobody else', () async {
    await chat.loadOwnTrust();
    directory.offline = true;
    await chat.refreshOwnTrust();
    expect(chat.isOwnDeviceTrusted('laptop', laptop.publicSigningKeyBase64), isFalse);
  });

  test('a newly approved device becomes trusted through its approval signature', () async {
    await storage.kvSet(
        'own_trusted', OwnDeviceTrust.encode({'phone': phone.publicSigningKeyBase64}));
    await chat.loadOwnTrust();
    directory.rows = [
      row('phone', phone),
      row('laptop', laptop, approvedBy: 'phone', signature: approve(phone, 'laptop', laptop)),
      // Approved by the laptop, which is trusted only through its own signature.
      row('tablet', tablet, approvedBy: 'laptop', signature: approve(laptop, 'tablet', tablet)),
      row('rogue', rogue),
    ];
    await chat.refreshOwnTrust();
    expect(chat.isOwnDeviceTrusted('laptop', laptop.publicSigningKeyBase64), isTrue);
    expect(chat.isOwnDeviceTrusted('tablet', tablet.publicSigningKeyBase64), isTrue);
    expect(chat.isOwnDeviceTrusted('rogue', rogue.publicSigningKeyBase64), isFalse);
  });

  test('untrustedOwnDevices lists devices the server returns without approved_at', () async {
    await storage.kvSet(
        'own_trusted', OwnDeviceTrust.encode({'phone': phone.publicSigningKeyBase64}));
    await chat.loadOwnTrust();
    directory.rows = [
      row('phone', phone),
      row('laptop', laptop, approvedBy: 'phone', signature: approve(phone, 'laptop', laptop)),
      row('rogue', rogue),
    ];
    await chat.refreshOwnTrust();
    expect([for (final d in chat.untrustedOwnDevices) d['device_id']], ['rogue']);
    await chat.trustOwnDevice('rogue');
    expect(chat.untrustedOwnDevices, isEmpty);
    expect(chat.isOwnDeviceTrusted('rogue', rogue.publicSigningKeyBase64), isTrue);
  });

  test('first run (nothing stored): every listed device is trusted once the list arrives', () async {
    await chat.loadOwnTrust();
    directory.rows = [row('phone', phone), row('laptop', laptop)];
    await chat.refreshOwnTrust();
    expect(chat.isOwnDeviceTrusted('laptop', laptop.publicSigningKeyBase64), isTrue);
  });
}
