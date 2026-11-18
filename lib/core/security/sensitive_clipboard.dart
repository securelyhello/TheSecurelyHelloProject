import 'dart:async';

import 'package:flutter/services.dart';

/// Copies secrets (2FA secret, recovery codes, backup keys) to the clipboard
/// and wipes them again after [clearAfter], unless the user has copied
/// something else in the meantime.
class SensitiveClipboard {
  SensitiveClipboard._();

  static const clearAfter = Duration(seconds: 60);

  static Future<void> copy(String text, {Duration after = clearAfter}) async {
    await Clipboard.setData(ClipboardData(text: text));
    Timer(after, () => unawaited(clearIfStill(text)));
  }

  /// Empties the clipboard if it still holds exactly [text].
  static Future<void> clearIfStill(String text) async {
    try {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == text) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (_) {
      // Clipboard unavailable (e.g. app in background): nothing to do.
    }
  }
}
