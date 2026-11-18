import 'dart:convert';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter/foundation.dart';

/// Solves the server's signup / reset-e-mail challenge: find a nonce so that
/// SHA-256("securelyhello-pow|purpose|challenge|nonce") starts with [bits]
/// zero bits (matches server/src/spam.js). Runs off the UI thread.
class ProofOfWork {
  static Future<String> solve(String purpose, String challenge, int bits) =>
      bits <= 0 ? Future.value('0') : compute(_solve, (purpose, challenge, bits));

  static int leadingZeroBits(List<int> digest) {
    var n = 0;
    for (final b in digest) {
      if (b == 0) {
        n += 8;
        continue;
      }
      var x = b;
      while (x & 0x80 == 0) {
        n++;
        x <<= 1;
      }
      return n;
    }
    return n;
  }

  static String _solve((String, String, int) task) {
    final (purpose, challenge, bits) = task;
    final prefix = utf8.encode('securelyhello-pow|$purpose|$challenge|');
    for (var nonce = 0;; nonce++) {
      final digest = hash.sha256.convert([...prefix, ...utf8.encode('$nonce')]).bytes;
      if (leadingZeroBits(digest) >= bits) return '$nonce';
    }
  }
}
