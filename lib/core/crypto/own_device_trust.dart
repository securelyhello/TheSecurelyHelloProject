import 'dart:convert';
import 'dart:typed_data';

import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/crypto/device_manager.dart';

/// Which devices of our own account this device trusts with copies of what
/// we send (audit run 1: "the app doesn't check device-approval
/// signatures").
///
/// A device is trusted when it was already trusted (with the same signing
/// key), or when the server shows it approved by a trusted device AND that
/// device's signature over [DeviceManager.approvalMessage] checks out. A
/// device the server merely lists (say, one a compromised server inserted)
/// gets nothing until the user confirms it here.
abstract final class OwnDeviceTrust {
  /// Device id → signing key of the devices trusted after looking at
  /// [devices] (the server's list of our devices, with approved_by and
  /// approval_signature) given [trusted] so far.
  static Map<String, String> evaluate({
    required String userId,
    required Map<String, String> trusted,
    required List<Map<String, dynamic>> devices,
  }) {
    final byId = {for (final d in devices) d['device_id'] as String: d};
    // Keep trusted devices that are still there with the same key.
    final out = <String, String>{
      for (final e in trusted.entries)
        if (byId[e.key]?['signing_public_key'] == e.value) e.key: e.value,
    };
    var changed = true;
    while (changed) {
      changed = false;
      for (final d in devices) {
        final id = d['device_id'] as String;
        if (out.containsKey(id)) continue;
        final approver = d['approved_by'];
        final sig = d['approval_signature'];
        final approverKey = approver is String ? out[approver] : null;
        if (approverKey == null || sig is! String) continue;
        if (_signed(approverKey, sig,
            DeviceManager.approvalMessage(userId, id, d['signing_public_key'] as String, d['identity_public_key'] as String))) {
          out[id] = d['signing_public_key'] as String;
          changed = true;
        }
      }
    }
    return out;
  }

  static bool _signed(String signingKeyB64, String signatureB64, String message) {
    try {
      final sig = base64Decode(signatureB64);
      if (sig.length != 64) return false;
      final signed = Uint8List.fromList([...sig, ...utf8.encode(message)]);
      return CryptoCore.verify(signed, base64Decode(signingKeyB64));
    } on FormatException {
      return false;
    }
  }

  static String encode(Map<String, String> trusted) => jsonEncode(trusted);

  static Map<String, String>? decode(String? raw) {
    if (raw == null) return null;
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }
}
