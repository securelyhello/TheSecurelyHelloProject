import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Launch-time configuration.
///
/// * `API_BASE_URL` — the Securely Hello server (see `server/`). Read from
///   `--dart-define=API_BASE_URL=…` first, then `.env`. Defaults to the local
///   dev server (`scripts/dev.sh`); the Android emulator reaches the host as
///   `10.0.2.2`.
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
    final raw = _definedBaseUrl.isNotEmpty
        ? _definedBaseUrl
        : fromProcess?.trim().isNotEmpty == true
            ? fromProcess!.trim()
            : (fromEnv?.trim().isNotEmpty == true
            ? fromEnv!.trim()
            : (Platform.isAndroid
                ? 'http://10.0.2.2:8787'
                : 'http://127.0.0.1:8787'));
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
