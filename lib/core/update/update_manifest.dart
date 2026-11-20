/// `latest.json` on the website: which Android build is current.
///
/// ```json
/// { "versionCode": 2, "versionName": "1.1.0",
///   "url": "https://securelyhello.thenn.in/download/securelyhello-1.1.0.apk",
///   "sha256": "…", "size": 91234567, "minSupportedVersionCode": 1, "notes": "…" }
/// ```
///
/// `size` (bytes) is optional, at the top level and in each `abis` entry; it
/// is only shown to the user ("90 MB"), never trusted for the download.
///
/// The download must come over HTTPS from the same host as the manifest; the
/// hash and the APK's signing certificate are checked before installing.
class UpdateManifest {
  const UpdateManifest({
    required this.versionCode,
    required this.versionName,
    required this.url,
    required this.sha256,
    required this.minSupportedVersionCode,
    required this.notes,
    this.abis = const {},
    this.size,
  });

  final int versionCode;
  final String versionName;
  final Uri url;

  /// Lower-case hex SHA-256 of the APK.
  final String sha256;

  /// Builds below this must update before they can be used.
  final int minSupportedVersionCode;
  final String notes;

  /// Smaller APKs for one CPU type each (`arm64-v8a`, `armeabi-v7a`), with
  /// the same versionCode as the universal one at [url].
  final Map<String, UpdateDownload> abis;

  /// Bytes of the universal APK at [url], when the manifest says.
  final int? size;

  static const maxNotes = 2000;

  /// The largest APK the app will take (also the largest `size` accepted).
  static const maxApkBytes = 300 * 1024 * 1024;

  /// The APK for a phone whose preferred ABI is [abi]: its own split when
  /// there is one, the universal APK otherwise.
  UpdateDownload downloadFor(String? abi) => abis[abi] ?? UpdateDownload(url, sha256, size);

  /// Throws [FormatException] for anything unexpected.
  static UpdateManifest parse(Object? json, {required Uri source}) {
    if (json is! Map) throw const FormatException('manifest is not an object');
    final code = json['versionCode'];
    final name = json['versionName'];
    final url = json['url'];
    final hash = json['sha256'];
    final min = json['minSupportedVersionCode'] ?? 0;
    final notes = json['notes'] ?? '';
    if (code is! int || code <= 0) throw const FormatException('versionCode');
    if (name is! String || name.isEmpty || name.length > 32) throw const FormatException('versionName');
    if (min is! int || min < 0 || min > code) throw const FormatException('minSupportedVersionCode');
    if (notes is! String || notes.length > maxNotes) throw const FormatException('notes');
    final universal = _download(url, hash, source, json['size']);
    final rawAbis = json['abis'] ?? const {};
    if (rawAbis is! Map || rawAbis.length > 8) throw const FormatException('abis');
    final abis = <String, UpdateDownload>{};
    for (final e in rawAbis.entries) {
      final v = e.value;
      if (e.key is! String || !RegExp(r'^[a-z0-9_-]{1,16}$').hasMatch(e.key as String) || v is! Map) {
        throw const FormatException('abis');
      }
      abis[e.key as String] = _download(v['url'], v['sha256'], source, v['size']);
    }
    return UpdateManifest(
      versionCode: code,
      versionName: name,
      url: universal.url,
      sha256: universal.sha256,
      minSupportedVersionCode: min,
      notes: notes,
      abis: abis,
      size: universal.size,
    );
  }

  static UpdateDownload _download(Object? url, Object? hash, Uri source, Object? size) {
    if (hash is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
      throw const FormatException('sha256');
    }
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.host != source.host) {
      throw const FormatException('url must be HTTPS on the manifest host');
    }
    if (size != null && (size is! int || size <= 0 || size > maxApkBytes)) {
      throw const FormatException('size');
    }
    return UpdateDownload(uri, hash.toLowerCase(), size as int?);
  }
}

/// Where an APK is and its SHA-256 (lower-case hex), and its [size] in
/// bytes when the manifest gives one.
class UpdateDownload {
  const UpdateDownload(this.url, this.sha256, [this.size]);
  final Uri url;
  final String sha256;
  final int? size;
}

enum UpdateUrgency {
  /// Up to date (or nothing known).
  none,

  /// A newer build exists; the user may update.
  available,

  /// This build is below the minimum but no published build meets it (no
  /// manifest, or one older than the minimum): a warning, not a block, so
  /// a minimum alone can't lock the user out of their chats.
  unsupported,

  /// This build is no longer supported and the manifest offers one that is:
  /// update before going on.
  required,
}

/// What [installed] should do given [manifest] and the server's minimum.
/// Blocking ([UpdateUrgency.required]) only when [manifest] offers a build
/// at or above the minimum from either source (security review M4).
UpdateUrgency updateUrgency({required int installed, UpdateManifest? manifest, int? serverMinimum}) {
  final minimum = [manifest?.minSupportedVersionCode ?? 0, serverMinimum ?? 0].reduce((a, b) => a > b ? a : b);
  if (installed < minimum) {
    return manifest != null && manifest.versionCode >= minimum ? UpdateUrgency.required : UpdateUrgency.unsupported;
  }
  if (manifest != null && manifest.versionCode > installed) return UpdateUrgency.available;
  return UpdateUrgency.none;
}

/// How often the app looks for an update.
const updateCheckInterval = Duration(hours: 12);

/// Whether it's time to look again. A last check in the future (clock set
/// back) counts as due.
bool shouldCheck({required DateTime? lastCheck, required DateTime now}) =>
    lastCheck == null || lastCheck.isAfter(now) || now.difference(lastCheck) >= updateCheckInterval;
