/// `latest.json` on the website: which Android build is current.
///
/// ```json
/// { "versionCode": 2, "versionName": "1.1.0",
///   "url": "https://securelyhello.thenn.in/download/securelyhello-1.1.0.apk",
///   "sha256": "…", "minSupportedVersionCode": 1, "notes": "…" }
/// ```
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
  });

  final int versionCode;
  final String versionName;
  final Uri url;

  /// Lower-case hex SHA-256 of the APK.
  final String sha256;

  /// Builds below this must update before they can be used.
  final int minSupportedVersionCode;
  final String notes;

  static const maxNotes = 2000;

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
    if (hash is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
      throw const FormatException('sha256');
    }
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.host != source.host) {
      throw const FormatException('url must be HTTPS on the manifest host');
    }
    return UpdateManifest(
      versionCode: code,
      versionName: name,
      url: uri,
      sha256: hash.toLowerCase(),
      minSupportedVersionCode: min,
      notes: notes,
    );
  }
}

enum UpdateUrgency {
  /// Up to date (or nothing known).
  none,

  /// A newer build exists; the user may update.
  available,

  /// This build is no longer supported: update before going on.
  required,
}

/// What [installed] should do given [manifest] and the server's minimum.
UpdateUrgency updateUrgency({required int installed, UpdateManifest? manifest, int? serverMinimum}) {
  final minimum = [manifest?.minSupportedVersionCode ?? 0, serverMinimum ?? 0].reduce((a, b) => a > b ? a : b);
  if (installed < minimum) return UpdateUrgency.required;
  if (manifest != null && manifest.versionCode > installed) return UpdateUrgency.available;
  return UpdateUrgency.none;
}

/// How often the app looks for an update.
const updateCheckInterval = Duration(hours: 12);

/// Whether it's time to look again. A last check in the future (clock set
/// back) counts as due.
bool shouldCheck({required DateTime? lastCheck, required DateTime now}) =>
    lastCheck == null || lastCheck.isAfter(now) || now.difference(lastCheck) >= updateCheckInterval;
