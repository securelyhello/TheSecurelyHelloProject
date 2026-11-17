/// The QR code two people scan to verify each other.
///
/// It carries both user ids and the safety number, so a scan proves the
/// scanner's device computed the same number for the same pair.
class VerifyCode {
  static const _prefix = 'securelyhello:verify:1';

  static String encode({required String from, required String to, required String safetyNumber}) =>
      '$_prefix:$from:$to:${safetyNumber.replaceAll(' ', '')}';

  /// Checks a scanned [code] against what this device computed. [me] is our
  /// user id, [contact] the person we're verifying.
  static VerifyResult check(String code,
      {required String me, required String contact, required String safetyNumber}) {
    final parts = code.trim().split(':');
    if (parts.length != 6 || '${parts[0]}:${parts[1]}:${parts[2]}' != _prefix) {
      return VerifyResult.notACode;
    }
    if (parts[3] != contact || parts[4] != me) return VerifyResult.wrongPerson;
    return parts[5] == safetyNumber.replaceAll(' ', '')
        ? VerifyResult.match
        : VerifyResult.mismatch;
  }
}

enum VerifyResult { match, mismatch, wrongPerson, notACode }
