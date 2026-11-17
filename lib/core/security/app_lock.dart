import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, BuildContext;
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/storage/secure_key_store.dart';

/// PBKDF2-HMAC-SHA256 (RFC 8018).
Uint8List pbkdf2(List<int> password, List<int> salt, int iterations, int length) {
  final mac = hash.Hmac(hash.sha256, password);
  final out = BytesBuilder();
  for (var block = 1; out.length < length; block++) {
    var u = mac.convert([
      ...salt,
      block >> 24,
      (block >> 16) & 0xff,
      (block >> 8) & 0xff,
      block & 0xff,
    ]).bytes;
    final t = List<int>.from(u);
    for (var i = 1; i < iterations; i++) {
      u = mac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    out.add(t);
  }
  return Uint8List.fromList(out.toBytes().sublist(0, length));
}

class _PinCheck {
  final String pin;
  final List<int> salt;
  final int iterations;
  const _PinCheck(this.pin, this.salt, this.iterations);
}

Uint8List _derive(_PinCheck c) => pbkdf2(utf8.encode(c.pin), c.salt, c.iterations, 32);

/// Locks the app behind a PIN (and optionally biometrics), and keeps its
/// screen private.
///
/// The PIN is never stored: only a PBKDF2 hash with a random salt, in the
/// platform keystore. Wrong PINs get growing delays; optionally the local
/// data is erased after [wipeAfter] failures. The lock guards the UI; data
/// at rest is already encrypted with a keystore key.
class AppLockService extends ChangeNotifier {
  static const iterations = 120000;
  static const wipeAfter = 10;
  static const timeoutChoices = [0, 60, 300, 1800];
  static const _screenChannel = MethodChannel('securelyhello/screen');

  final SecureKeyStore _store;
  final LocalAuthentication _auth;

  /// Called with the user's consent to erase local data after too many
  /// failures (signs out and deletes this account's database).
  Future<void> Function()? onWipe;

  AppLockService({required SecureKeyStore store, LocalAuthentication? auth})
    : _store = store,
      _auth = auth ?? LocalAuthentication();

  bool _enabled = false;
  bool _locked = false;
  bool _biometrics = false;
  bool _wipeOnFailures = false;
  bool _screenSecurity = true;
  bool _incognitoKeyboard = true;
  int _timeout = 60;
  int _failures = 0;
  DateTime? _lockedUntil;
  DateTime? _backgroundSince;
  bool _obscured = false;

  bool get enabled => _enabled;
  bool get locked => _enabled && _locked;
  bool get useBiometrics => _biometrics;
  bool get wipeOnFailures => _wipeOnFailures;
  bool get screenSecurity => _screenSecurity;
  bool get incognitoKeyboard => _incognitoKeyboard;
  int get timeoutSeconds => _timeout;
  int get failures => _failures;

  /// The app is not in the foreground and screen security is on: the UI
  /// should be covered so the app switcher shows nothing.
  bool get obscured => _screenSecurity && _obscured;

  /// Wait this long before the next PIN attempt (zero if none).
  Duration get retryIn {
    final until = _lockedUntil;
    if (until == null) return Duration.zero;
    final d = until.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  static String timeoutLabel(int s) => switch (s) {
    0 => 'Immediately',
    60 => 'After 1 minute',
    300 => 'After 5 minutes',
    1800 => 'After 30 minutes',
    _ => 'After ${s ~/ 60} minutes',
  };

  Future<void> init() async {
    _enabled = await _store.readSetting('lock_hash') != null;
    _biometrics = await _store.readSetting('lock_bio') == '1';
    _wipeOnFailures = await _store.readSetting('lock_wipe') == '1';
    _screenSecurity = await _store.readSetting('screen_secure') != '0';
    _incognitoKeyboard = await _store.readSetting('incognito_kb') != '0';
    _timeout = int.tryParse(await _store.readSetting('lock_timeout') ?? '') ?? 60;
    _failures = int.tryParse(await _store.readSetting('lock_failures') ?? '') ?? 0;
    _locked = _enabled;
    await _applyScreenFlag();
    notifyListeners();
  }

  /// Turns the lock on with [pin] (at least 4 digits or characters).
  Future<void> setPin(String pin) async {
    if (pin.length < 4) throw ArgumentError('PIN too short');
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final derived = await compute(_derive, _PinCheck(pin, salt, iterations));
    await _store.writeSetting(
      'lock_hash',
      jsonEncode({'salt': base64Encode(salt), 'hash': base64Encode(derived), 'iter': iterations}),
    );
    await _setFailures(0);
    _enabled = true;
    _locked = false;
    notifyListeners();
  }

  Future<void> disable() async {
    await _store.deleteSetting('lock_hash');
    await _store.deleteSetting('lock_bio');
    _enabled = false;
    _biometrics = false;
    _locked = false;
    notifyListeners();
  }

  /// Checks [pin]. Returns true and unlocks on success.
  Future<bool> unlockWithPin(String pin) async {
    if (!_enabled) return true;
    if (retryIn > Duration.zero) return false;
    final raw = await _store.readSetting('lock_hash');
    if (raw == null) return true;
    final rec = jsonDecode(raw) as Map<String, dynamic>;
    final derived = await compute(
      _derive,
      _PinCheck(pin, base64Decode(rec['salt'] as String), rec['iter'] as int),
    );
    final expected = base64Decode(rec['hash'] as String);
    var diff = derived.length ^ expected.length;
    for (var i = 0; i < min(derived.length, expected.length); i++) {
      diff |= derived[i] ^ expected[i];
    }
    if (diff == 0) {
      await _setFailures(0);
      _locked = false;
      notifyListeners();
      return true;
    }
    await _setFailures(_failures + 1);
    if (_wipeOnFailures && _failures >= wipeAfter) {
      await disable();
      await onWipe?.call();
      return false;
    }
    // 5 free tries, then 30 s, 1 min, 2 min … capped at 30 min.
    if (_failures >= 5) {
      final secs = min(1800, 30 * pow(2, _failures - 5).toInt());
      _lockedUntil = DateTime.now().add(Duration(seconds: secs));
    }
    notifyListeners();
    return false;
  }

  Future<void> _setFailures(int n) async {
    _failures = n;
    if (n == 0) _lockedUntil = null;
    await _store.writeSetting('lock_failures', '$n');
  }

  Future<bool> biometricsAvailable() async {
    if (kIsWeb ||
        !(Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows)) {
      return false;
    }
    try {
      return await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  Future<bool> unlockWithBiometrics() async {
    if (!_enabled || !_biometrics || !await biometricsAvailable()) return false;
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock Securely Hello',
        biometricOnly: true,
      );
      if (ok) {
        _locked = false;
        await _setFailures(0);
        notifyListeners();
      }
      return ok;
    } on PlatformException {
      return false;
    }
  }

  Future<void> setUseBiometrics(bool v) async {
    _biometrics = v;
    await _store.writeSetting('lock_bio', v ? '1' : '0');
    notifyListeners();
  }

  Future<void> setWipeOnFailures(bool v) async {
    _wipeOnFailures = v;
    await _store.writeSetting('lock_wipe', v ? '1' : '0');
    notifyListeners();
  }

  Future<void> setTimeout(int seconds) async {
    _timeout = seconds;
    await _store.writeSetting('lock_timeout', '$seconds');
    notifyListeners();
  }

  Future<void> setScreenSecurity(bool v) async {
    _screenSecurity = v;
    await _store.writeSetting('screen_secure', v ? '1' : '0');
    await _applyScreenFlag();
    notifyListeners();
  }

  Future<void> setIncognitoKeyboard(bool v) async {
    _incognitoKeyboard = v;
    await _store.writeSetting('incognito_kb', v ? '1' : '0');
    notifyListeners();
  }

  /// Feed app lifecycle changes in: covers the screen in the background and
  /// locks after the timeout.
  void onLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final since = _backgroundSince;
      _backgroundSince = null;
      if (_enabled && since != null && DateTime.now().difference(since).inSeconds >= _timeout) {
        _locked = true;
      }
      _obscured = false;
    } else {
      _backgroundSince ??= DateTime.now();
      _obscured = true;
      if (_enabled && _timeout == 0) _locked = true;
    }
    notifyListeners();
  }

  /// Locks now (e.g. from the menu).
  void lockNow() {
    if (!_enabled) return;
    _locked = true;
    notifyListeners();
  }

  /// Android: FLAG_SECURE blocks screenshots, screen recording and the
  /// recent-apps thumbnail. Other platforms rely on [obscured].
  Future<void> _applyScreenFlag() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _screenChannel.invokeMethod<void>('setSecure', _screenSecurity);
    } on MissingPluginException {
      // Older native shell; the in-app cover still applies.
    } on PlatformException {
      // Same.
    }
  }
}

/// Whether text fields should ask the keyboard not to learn (on by default,
/// also when no lock service is provided, e.g. in widget tests).
bool incognitoKeyboard(BuildContext context) {
  try {
    return Provider.of<AppLockService>(context, listen: false).incognitoKeyboard;
  } on ProviderNotFoundException {
    return true;
  }
}
