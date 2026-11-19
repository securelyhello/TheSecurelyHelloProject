import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/core/update/app_updater.dart';
import 'package:securelyhello/core/update/update_manifest.dart';

final source = Uri.parse('https://securelyhello.thenn.in/download/latest.json');
final apkBytes = utf8.encode('pretend this is an APK ' * 1000);
final apkSha = sha256.convert(apkBytes).toString();

Map<String, dynamic> manifestJson({
  int versionCode = 2,
  String url = 'https://securelyhello.thenn.in/download/securelyhello-1.1.0.apk',
  String? hash,
  int min = 1,
}) =>
    {
      'versionCode': versionCode,
      'versionName': '1.1.0',
      'url': url,
      'sha256': hash ?? apkSha,
      'minSupportedVersionCode': min,
      'notes': 'Stories, a new look and faster hang-ups.',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('manifest', () {
    test('parses a good one', () {
      final m = UpdateManifest.parse(manifestJson(), source: source);
      expect(m.versionCode, 2);
      expect(m.versionName, '1.1.0');
      expect(m.url.path, '/download/securelyhello-1.1.0.apk');
      expect(m.sha256, apkSha);
      expect(m.minSupportedVersionCode, 1);
      expect(m.notes, contains('Stories'));
    });

    test('refuses anything that is not HTTPS from our own site', () {
      for (final url in [
        'http://securelyhello.thenn.in/download/x.apk',
        'https://evil.example/download/x.apk',
        'https://securelyhello.thenn.in.evil.example/x.apk',
        'ftp://securelyhello.thenn.in/x.apk',
        'not a url',
      ]) {
        expect(() => UpdateManifest.parse(manifestJson(url: url), source: source), throwsFormatException,
            reason: url);
      }
    });

    test('refuses malformed fields', () {
      for (final bad in [
        manifestJson(hash: 'abc'),
        manifestJson(hash: 'Z' * 64),
        manifestJson(versionCode: 0),
        manifestJson(min: 3), // min above the version itself
        {...manifestJson(), 'versionCode': '2'},
        {...manifestJson(), 'notes': 'x' * 5000},
        {...manifestJson()}..remove('sha256'),
      ]) {
        expect(() => UpdateManifest.parse(bad, source: source), throwsFormatException, reason: '$bad');
      }
    });

    test('upper-case hashes are accepted and normalised', () {
      expect(UpdateManifest.parse(manifestJson(hash: apkSha.toUpperCase()), source: source).sha256, apkSha);
    });
  });

  group('what to do', () {
    final m = UpdateManifest.parse(manifestJson(versionCode: 5, min: 3), source: source);
    test('version compare', () {
      expect(updateUrgency(installed: 5, manifest: m), UpdateUrgency.none);
      expect(updateUrgency(installed: 6, manifest: m), UpdateUrgency.none, reason: 'newer than published');
      expect(updateUrgency(installed: 4, manifest: m), UpdateUrgency.available);
      expect(updateUrgency(installed: 3, manifest: m), UpdateUrgency.available);
      expect(updateUrgency(installed: 2, manifest: m), UpdateUrgency.required, reason: 'below minSupported');
    });
    test('the server can raise the minimum', () {
      expect(updateUrgency(installed: 4, manifest: m, serverMinimum: 5), UpdateUrgency.required);
      expect(updateUrgency(installed: 4, manifest: null, serverMinimum: 5), UpdateUrgency.required,
          reason: 'even when the manifest could not be fetched');
      expect(updateUrgency(installed: 4, manifest: null), UpdateUrgency.none);
    });
    test('checks at most every 12 hours', () {
      final t = DateTime(2026, 11, 19, 10);
      expect(shouldCheck(lastCheck: null, now: t), isTrue);
      expect(shouldCheck(lastCheck: t.subtract(const Duration(hours: 11)), now: t), isFalse);
      expect(shouldCheck(lastCheck: t.subtract(const Duration(hours: 12)), now: t), isTrue);
      expect(shouldCheck(lastCheck: t.add(const Duration(hours: 3)), now: t), isTrue,
          reason: 'a clock set back must not stop checks');
    });
  });

  group('updater', () {
    late Directory dir;
    late List<MethodCall> nativeCalls;
    late Map<String, Object?> native;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dir = await Directory.systemTemp.createTemp('sh_update_');
      nativeCalls = [];
      native = {
        'info': {'versionCode': 1, 'versionName': '1.0.0', 'certSha256': 'AA:BB'},
        'apkInfo': {'packageName': 'securelyhello.thenn.in', 'versionCode': 2, 'certSha256': 'AA:BB'},
        'canInstall': true,
        'install': true,
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppUpdater.channel, (call) async {
        nativeCalls.add(call);
        return native[call.method];
      });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppUpdater.channel, null);
      await dir.delete(recursive: true);
    });

    AppUpdater updater({Map<String, dynamic>? manifest, List<int>? apk, int status = 200}) {
      final client = MockClient((r) async {
        if (r.url == source) return http.Response(jsonEncode(manifest ?? manifestJson()), status);
        if (r.url.path.endsWith('.apk')) return http.Response.bytes(apk ?? apkBytes, 200);
        return http.Response('', 404);
      });
      return AppUpdater(
        client: client,
        manifestUrl: source,
        enabled: true,
        downloadDir: () async => dir,
        pinnedCertSha256: null,
      );
    }

    test('finds an update and remembers when it looked', () async {
      final u = updater();
      await u.check();
      expect(u.urgency, UpdateUrgency.available);
      expect(u.manifest!.versionName, '1.1.0');
      // A restart within 12 hours doesn't fetch again but still knows.
      final again = MockClient((_) async => fail('checked again within 12 h'));
      final u2 = AppUpdater(client: again, manifestUrl: source, enabled: true, downloadDir: () async => dir);
      await u2.check();
      expect(u2.urgency, UpdateUrgency.available);
    });

    test('downloads, verifies and installs', () async {
      final u = updater();
      await u.check();
      final progress = <double>[];
      u.addListener(() => progress.add(u.progress));
      await u.downloadAndInstall();
      expect(u.error, isNull);
      expect(progress.last, 1.0);
      expect(nativeCalls.map((c) => c.method), containsAllInOrder(['apkInfo', 'canInstall', 'install']));
      final installed = nativeCalls.firstWhere((c) => c.method == 'install');
      expect(File((installed.arguments as Map)['path'] as String).readAsBytesSync(), apkBytes);
    });

    test('a wrong hash is refused and the file deleted', () async {
      final u = updater(apk: utf8.encode('tampered'));
      await u.check();
      await u.downloadAndInstall();
      expect(u.error, UpdateError.hashMismatch);
      expect(nativeCalls.where((c) => c.method == 'install'), isEmpty);
      expect(dir.listSync(), isEmpty);
    });

    test('an APK signed by someone else is refused', () async {
      native['apkInfo'] = {'packageName': 'securelyhello.thenn.in', 'versionCode': 2, 'certSha256': 'CC:DD'};
      final u = updater();
      await u.check();
      await u.downloadAndInstall();
      expect(u.error, UpdateError.certificateMismatch);
      expect(nativeCalls.where((c) => c.method == 'install'), isEmpty);
      expect(dir.listSync(), isEmpty);
    });

    test('a different app or an older version is refused', () async {
      native['apkInfo'] = {'packageName': 'com.other', 'versionCode': 2, 'certSha256': 'AA:BB'};
      var u = updater();
      await u.check();
      await u.downloadAndInstall();
      expect(u.error, UpdateError.wrongPackage);

      native['apkInfo'] = {'packageName': 'securelyhello.thenn.in', 'versionCode': 1, 'certSha256': 'AA:BB'};
      u = updater();
      await u.check(force: true);
      await u.downloadAndInstall();
      expect(u.error, UpdateError.wrongPackage);
    });

    test('the release certificate is pinned', () async {
      final client = MockClient((r) async => r.url == source
          ? http.Response(jsonEncode(manifestJson()), 200)
          : http.Response.bytes(apkBytes, 200));
      final u = AppUpdater(
          client: client, manifestUrl: source, enabled: true, downloadDir: () async => dir, pinnedCertSha256: 'EE:FF');
      await u.check();
      await u.downloadAndInstall();
      expect(u.error, UpdateError.certificateMismatch,
          reason: 'installed and downloaded agree, but neither is the release key');
    });

    test('asks for the "install unknown apps" permission', () async {
      native['canInstall'] = false;
      final u = updater();
      await u.check();
      await u.downloadAndInstall();
      expect(u.error, UpdateError.needsPermission);
      expect(nativeCalls.map((c) => c.method), contains('openInstallSettings'));
    });

    test('network trouble is an error, not a crash', () async {
      final u = updater(status: 500);
      await u.check();
      expect(u.urgency, UpdateUrgency.none);
      expect(u.lastCheckFailed, isTrue);
    });

    test('a manifest URL that is not HTTPS is never fetched', () async {
      final u = AppUpdater(
          client: MockClient((_) async => fail('fetched over plain HTTP')),
          manifestUrl: Uri.parse('http://securelyhello.thenn.in/download/latest.json'),
          enabled: true,
          downloadDir: () async => dir);
      await u.check();
      expect(u.urgency, UpdateUrgency.none);
    });

    test('disabled (Play Store builds, other platforms): does nothing', () async {
      final u = AppUpdater(
          client: MockClient((_) async => fail('no network when disabled')),
          manifestUrl: source,
          enabled: false,
          downloadDir: () async => dir);
      await u.check(force: true);
      u.serverMinimum = 99;
      expect(u.urgency, UpdateUrgency.none, reason: 'Play handles updates');
    });

    test('a server minimum makes the update required', () async {
      final u = updater();
      await u.check();
      u.serverMinimum = 2;
      expect(u.urgency, UpdateUrgency.required);
    });
  });
}
