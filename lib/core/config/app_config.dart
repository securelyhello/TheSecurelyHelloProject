import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Launch-time configuration.
///
/// * `API_BASE_URL` — the Securely Hello server (see `server/`). Read from
///   `--dart-define=API_BASE_URL=…` first, then (desktop only) the
///   `SH_API_BASE_URL` environment variable, then `.env`. Empty values count
///   as unset. With nothing set, release builds use the production server
///   ([productionBaseUrl]); debug and profile builds use the local dev server
///   (`scripts/dev.sh`), which the Android emulator reaches as `10.0.2.2`.
/// * `SH_PROFILE` — optional profile name (environment variable on desktop,
///   or `--dart-define`). Each profile gets its own local database directory
///   and keystore entries, so two instances with different accounts can run
///   side by side on one machine:
///
///   ```
///   SH_PROFILE=alice flutter run -d linux
///   SH_PROFILE=bob   flutter run -d linux
///   ```
class AppConfig {
  AppConfig._();

  static const _definedBaseUrl = String.fromEnvironment('API_BASE_URL');
  static const _definedProfile = String.fromEnvironment('SH_PROFILE');
  static const _definedPins = String.fromEnvironment('API_CERT_PINS');

  /// Optional certificate pins for the server: comma-separated base64
  /// SHA-256 hashes of its public key (SPKI). Set at build time:
  ///
  /// ```
  /// flutter build apk --dart-define=API_CERT_PINS=<current key>,<backup key>
  /// ```
  ///
  /// `server/DEPLOY.md` shows how to compute them.
  static String get certPins {
    if (_definedPins.isNotEmpty) return _definedPins;
    try {
      return dotenv.maybeGet('API_CERT_PINS') ?? '';
    } catch (_) {
      return '';
    }
  }

  static String get apiBaseUrl {
    String? fromEnv;
    try {
      fromEnv = dotenv.maybeGet('API_BASE_URL');
    } catch (_) {
      fromEnv = null; // dotenv not loaded
    }
    // Desktop only: an environment variable wins, so a built binary can be
    // pointed at another server without rebuilding.
    String? fromProcess;
    try {
      if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        fromProcess = Platform.environment['SH_API_BASE_URL'];
      }
    } catch (_) {
      fromProcess = null;
    }
    bool isAndroid;
    try {
      isAndroid = Platform.isAndroid;
    } catch (_) {
      isAndroid = false;
    }
    return resolveBaseUrl(
      defined: _definedBaseUrl,
      fromProcess: fromProcess,
      fromEnv: fromEnv,
      isRelease: kReleaseMode,
      isAndroid: isAndroid,
    );
  }

  /// Production server, used by release builds when nothing else is set.
  static const productionBaseUrl = 'https://api.hello.thenn.in';

  /// Picks the server URL: the first non-empty of [defined] (dart-define),
  /// [fromProcess] (desktop environment variable) and [fromEnv] (`.env`),
  /// else [productionBaseUrl] in release builds or the local dev server
  /// otherwise. A trailing slash is removed. Pure, for tests.
  @visibleForTesting
  static String resolveBaseUrl({
    required String defined,
    required String? fromProcess,
    required String? fromEnv,
    required bool isRelease,
    required bool isAndroid,
  }) {
    String? pick(String? v) =>
        v != null && v.trim().isNotEmpty ? v.trim() : null;
    final raw = pick(defined) ??
        pick(fromProcess) ??
        pick(fromEnv) ??
        (isRelease
            ? productionBaseUrl
            : (isAndroid ? 'http://10.0.2.2:8787' : 'http://127.0.0.1:8787'));
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  /// Sanitised profile name, or '' for the default profile.
  static String get profile {
    var raw = _definedProfile;
    if (raw.isEmpty) {
      try {
        raw = Platform.environment['SH_PROFILE'] ?? '';
      } catch (_) {
        raw = '';
      }
    }
    return sanitizeProfile(raw);
  }

  static String sanitizeProfile(String raw) {
    final cleaned =
        raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '');
    return cleaned.length > 32 ? cleaned.substring(0, 32) : cleaned;
  }

  /// STUN servers plus an optional TURN relay from `.env`:
  ///
  /// ```
  /// TURN_URLS=turn:turn.example.com:3478,turns:turn.example.com:5349
  /// TURN_USERNAME=...
  /// TURN_CREDENTIAL=...
  /// ```
  ///
  /// TURN only relays DTLS-encrypted WebRTC traffic that is additionally
  /// NaCl-encrypted end to end, so the relay operator never sees content.
  ///
  /// Prefer setting TURN_SECRET on the server instead: the app then gets
  /// short-lived credentials (GET /api/turn) and nothing long-lived is
  /// built into it. These static ones are a fallback for other relays.
  static List<Map<String, dynamic>> iceServers(
      List<Map<String, dynamic>> stunServers) {
    final servers = [...stunServers];
    String? env(String k) {
      try {
        return dotenv.maybeGet(k);
      } catch (_) {
        return null;
      }
    }

    final turnUrls = env('TURN_URLS');
    if (turnUrls != null && turnUrls.trim().isNotEmpty) {
      servers.add({
        'urls': turnUrls
            .split(',')
            .map((u) => u.trim())
            .where((u) => u.isNotEmpty)
            .toList(),
        'username': env('TURN_USERNAME') ?? '',
        'credential': env('TURN_CREDENTIAL') ?? '',
      });
    }
    return servers;
  }
}
