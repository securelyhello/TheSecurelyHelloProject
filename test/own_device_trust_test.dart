import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/crypto/device_manager.dart';
import 'package:securelyhello/core/crypto/own_device_trust.dart';

// Audit run 1 hardening: a device the server adds to our account gets no
// copies unless a device we trust signed its approval.
void main() {
  const user = 'u1';
  final phone = CryptoCore.generateIdentity();
  final laptop = CryptoCore.generateIdentity();
  final rogue = CryptoCore.generateIdentity();

  Map<String, dynamic> row(String id, dynamic identity, {String? approvedBy, String? signature}) => {
        'device_id': id,
        'signing_public_key': identity.publicSigningKeyBase64,
        'identity_public_key': identity.publicEncryptionKeyBase64,
        'approved_by': approvedBy,
        'approval_signature': signature,
      };

  String approve(dynamic by, String id, dynamic target) =>
      DeviceManager.signApproval(by, user, id, target.publicSigningKeyBase64, target.publicEncryptionKeyBase64);

  final trusted = {'phone': phone.publicSigningKeyBase64};

  test('a device approved (and signed) by a trusted one is trusted', () {
    final out = OwnDeviceTrust.evaluate(userId: user, trusted: trusted, devices: [
      row('phone', phone),
      row('laptop', laptop, approvedBy: 'phone', signature: approve(phone, 'laptop', laptop)),
    ]);
    expect(out.keys, containsAll(['phone', 'laptop']));
  });

  test('chains work in any order', () {
    final tablet = CryptoCore.generateIdentity();
    final out = OwnDeviceTrust.evaluate(userId: user, trusted: trusted, devices: [
      row('tablet', tablet, approvedBy: 'laptop', signature: approve(laptop, 'tablet', tablet)),
      row('laptop', laptop, approvedBy: 'phone', signature: approve(phone, 'laptop', laptop)),
      row('phone', phone),
    ]);
    expect(out.keys.toSet(), {'phone', 'laptop', 'tablet'});
  });

  test('a device the server merely lists, or claims approved, is not', () {
    final out = OwnDeviceTrust.evaluate(userId: user, trusted: trusted, devices: [
      row('phone', phone),
      row('rogue1', rogue),
      row('rogue2', rogue, approvedBy: 'phone', signature: base64Encode(List.filled(64, 1))),
      // A real signature, but for another device's keys.
      row('rogue3', rogue, approvedBy: 'phone', signature: approve(phone, 'laptop', laptop)),
      // Signed by a device we don't trust.
      row('rogue4', laptop, approvedBy: 'rogue1', signature: approve(rogue, 'rogue4', laptop)),
    ]);
    expect(out.keys, ['phone']);
  });

  test('a trusted device whose key changed is no longer trusted', () {
    final out = OwnDeviceTrust.evaluate(userId: user, trusted: trusted, devices: [row('phone', rogue)]);
    expect(out, isEmpty);
  });

  test('stored and read back', () {
    expect(OwnDeviceTrust.decode(OwnDeviceTrust.encode(trusted)), trusted);
    expect(OwnDeviceTrust.decode('junk'), isNull);
    expect(OwnDeviceTrust.decode(null), isNull);
  });
}
