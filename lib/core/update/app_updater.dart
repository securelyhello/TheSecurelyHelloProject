import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/core/networking/app_trust.dart';
import 'package:securelyhello/core/update/update_manifest.dart';

/// Why an update didn't install.
enum UpdateError {
  /// The download failed or was cut short.
  network,

  /// The file isn't the one the manifest describes.
  hashMismatch,

  /// The APK isn't signed with this app's key.
  certificateMismatch,

  /// The APK is another app, or not newer than this one.
  wrongPackage,

  /// The user hasn't allowed this app to install apps yet; the settings
  /// screen was opened.
  needsPermission,

  /// Android refused the install.
  installFailed,
}

/// The in-app updater for builds distributed as an APK (not through Play).
///
/// Checks [manifestUrl] on start and then at most every 12 hours, over HTTPS
/// only. Downloads the APK, verifies its SHA-256 and that it is signed with
/// the same certificate as the installed app (and, in release builds, the
/// release key), then hands it to Android's PackageInstaller.
///
/// Off in Play Store builds (`--dart-define=DISTRIBUTION=play`), where Play
/// handles updates and its policy forbids self-updating.
class AppUpdater extends ChangeNotifier {
  AppUpdater({
    http.Client? client,
    Uri? manifestUrl,
    bool? enabled,
    Future<Directory> Function()? downloadDir,
    this.pinnedCertSha256 = _defaultPin,
  })  : _client = client ?? IOClient(AppTrust.httpClient()),
        manifestUrl = manifestUrl ?? Uri.parse(defaultManifestUrl),
        enabled = enabled ?? defaultEnabled,
        _downloadDir = downloadDir ?? getTemporaryDirectory;

  static const channel = MethodChannel('securelyhello/updater');

  static const _distribution = String.fromEnvironment('DISTRIBUTION');
  static const defaultManifestUrl = String.fromEnvironment('UPDATE_MANIFEST_URL',
      defaultValue: 'https://securelyhello.thenn.in/download/latest.json');

  /// SHA-256 of the release signing certificate (also on the website).
  static const releaseCertSha256 =
      '78:8E:E6:48:86:1E:AF:80:39:49:6C:23:42:64:79:39:93:04:D5:F9:A3:C6:34:63:79:5A:4A:C2:5E:11:B6:E1';
  static const String? _defaultPin = kReleaseMode ? releaseCertSha256 : null;

  /// Android APK builds only; never in Play Store builds.
  static bool get defaultEnabled => !kIsWeb && Platform.isAndroid && _distribution != 'play';

  static const _lastCheckKey = 'update_last_check';
  static const _manifestKey = 'update_manifest';
  static const _maxManifestBytes = 64 * 1024;
  static const _maxApkBytes = 300 * 1024 * 1024;

  final http.Client _client;
  final Uri manifestUrl;
  final bool enabled;
  final Future<Directory> Function() _downloadDir;

  /// Every APK must be signed with this certificate (null: only the
  /// installed app's certificate is compared, as in debug builds).
  final String? pinnedCertSha256;

  UpdateManifest? _manifest;
  Map<String, Object?>? _installed;
  int? _serverMinimum;
  bool _busy = false;
  double _progress = 0;
  UpdateError? _error;
  bool _lastCheckFailed = false;

  UpdateManifest? get manifest => _manifest;
  int? get installedVersionCode => _installed?['versionCode'] as int?;
  bool get busy => _busy;

  /// Download progress, 0–1.
  double get progress => _progress;
  UpdateError? get error => _error;
  bool get lastCheckFailed => _lastCheckFailed;

  /// The server's minimum (from /api/config).
  set serverMinimum(int? v) {
    if (v == _serverMinimum) return;
    _serverMinimum = v;
    notifyListeners();
  }

  UpdateUrgency get urgency {
    final installed = installedVersionCode;
    if (!enabled || installed == null) return UpdateUrgency.none;
    return updateUrgency(installed: installed, manifest: _manifest, serverMinimum: _serverMinimum);
  }

  /// Looks for an update if 12 hours have passed (or [force]). Never throws.
  Future<void> check({bool force = false}) async {
    if (!enabled) return;
    try {
      _installed ??= await _native('info');
      final prefs = await SharedPreferences.getInstance();
      if (_manifest == null) {
        final saved = prefs.getString(_manifestKey);
        if (saved != null) {
          try {
            _manifest = UpdateManifest.parse(jsonDecode(saved), source: manifestUrl);
          } on FormatException {
            await prefs.remove(_manifestKey);
          }
        }
      }
      final last = prefs.getInt(_lastCheckKey);
      final now = DateTime.now();
      if (!force && !shouldCheck(lastCheck: last == null ? null : DateTime.fromMillisecondsSinceEpoch(last), now: now)) {
        notifyListeners();
        return;
      }
      if (manifestUrl.scheme != 'https') {
        debugPrint('Update manifest must be HTTPS; not checking');
        return;
      }
      final res = await _client.get(manifestUrl).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200 || res.bodyBytes.length > _maxManifestBytes) {
        throw HttpException('manifest: HTTP ${res.statusCode}');
      }
      final m = UpdateManifest.parse(jsonDecode(utf8.decode(res.bodyBytes)), source: manifestUrl);
      _manifest = m;
      _lastCheckFailed = false;
      await prefs.setString(_manifestKey, utf8.decode(res.bodyBytes));
      await prefs.setInt(_lastCheckKey, now.millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('Update check failed: $e');
      _lastCheckFailed = true;
    }
    notifyListeners();
  }

  /// Downloads the update, checks it and starts the install (Android then
  /// asks the user to confirm). Sets [error] when it can't.
  Future<void> downloadAndInstall() async {
    final m = _manifest;
    if (!enabled || m == null || _busy) return;
    _busy = true;
    _error = null;
    _progress = 0;
    notifyListeners();
    File? file;
    var keep = false;
    try {
      _installed ??= await _native('info');
      final dir = await _downloadDir();
      file = File('${dir.path}/securelyhello-${m.versionCode}.apk');
      if (!(file.existsSync() && await _sha256Of(file) == m.sha256)) {
        if (!await _download(m, file)) return;
      }
      _progress = 1;
      notifyListeners();

      final apk = await _native('apkInfo', {'path': file.path});
      final ownPackage = _installed?['packageName'] as String? ?? 'securelyhello.thenn.in';
      if (apk['packageName'] != ownPackage || (apk['versionCode'] as int? ?? 0) <= (installedVersionCode ?? 0)) {
        _error = UpdateError.wrongPackage;
        return;
      }
      final cert = _normalCert(apk['certSha256'] as String?);
      final ownCert = _normalCert(_installed?['certSha256'] as String?);
      final pin = pinnedCertSha256 == null ? null : _normalCert(pinnedCertSha256);
      if (cert.isEmpty || cert != ownCert || (pin != null && cert != pin)) {
        _error = UpdateError.certificateMismatch;
        return;
      }
      if (await channel.invokeMethod<bool>('canInstall') != true) {
        keep = true; // the user comes back from settings and taps again
        _error = UpdateError.needsPermission;
        await channel.invokeMethod<void>('openInstallSettings');
        return;
      }
      keep = true;
      if (await channel.invokeMethod<bool>('install', {'path': file.path}) != true) {
        _error = UpdateError.installFailed;
      }
    } on PlatformException catch (e) {
      debugPrint('Update install failed: $e');
      _error = UpdateError.installFailed;
    } catch (e) {
      debugPrint('Update download failed: $e');
      _error ??= UpdateError.network;
    } finally {
      if (!keep && file != null && file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
      _busy = false;
      notifyListeners();
    }
  }

  /// Streams the APK to [file], hashing as it goes. False (with [error]
  /// set) when it isn't the file the manifest describes.
  Future<bool> _download(UpdateManifest m, File file) async {
    final res = await _client.send(http.Request('GET', m.url)).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw HttpException('APK: HTTP ${res.statusCode}');
    final total = res.contentLength;
    if (total != null && total > _maxApkBytes) throw const HttpException('APK too large');
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    final out = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in res.stream.timeout(const Duration(seconds: 60))) {
        received += chunk.length;
        if (received > _maxApkBytes) throw const HttpException('APK too large');
        hasher.add(chunk);
        out.add(chunk);
        if (total != null && total > 0) {
          _progress = (received / total).clamp(0, 0.99);
          notifyListeners();
        }
      }
    } finally {
      await out.close();
    }
    hasher.close();
    if (digest.value.toString() != m.sha256) {
      _error = UpdateError.hashMismatch;
      return false;
    }
    return true;
  }

  static Future<String> _sha256Of(File f) async => (await sha256.bind(f.openRead()).first).toString();

  static String _normalCert(String? s) => (s ?? '').replaceAll(':', '').toUpperCase();

  static Future<Map<String, Object?>> _native(String method, [Object? args]) async =>
      Map<String, Object?>.from(await channel.invokeMethod<Map<Object?, Object?>>(method, args) ?? const {});

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
