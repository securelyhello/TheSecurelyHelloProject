import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'package:securelyhello/core/networking/directory_service.dart';

/// Push wake-ups through Firebase Cloud Messaging (Android, iOS, macOS).
///
/// Optional: active only when the Firebase options are set in `.env`
/// (FIREBASE_PROJECT_ID, FIREBASE_MESSAGING_SENDER_ID, FIREBASE_API_KEY and
/// FIREBASE_ANDROID_APP_ID / FIREBASE_IOS_APP_ID) and the server has
/// FCM_SERVICE_ACCOUNT. Desktop builds don't need it: they keep a socket
/// open while running and show local notifications.
///
/// A push carries no content. When one arrives with the app open, [onWake]
/// fetches the encrypted relay queue; in the background the OS shows the
/// generic "You have a new message" and opening the app does the rest.
class PushService {
  final DirectoryService _directory;

  /// Fetch and decrypt whatever is waiting.
  final Future<void> Function() onWake;

  StreamSubscription<String>? _refresh;
  StreamSubscription<RemoteMessage>? _foreground;
  bool _started = false;

  PushService({required DirectoryService directory, required this.onWake})
      : _directory = directory;

  static String? _env(String key) {
    try {
      final v = dotenv.maybeGet(key)?.trim();
      return v == null || v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }

  /// Firebase options for this platform from `.env`, or null.
  static FirebaseOptions? optionsFromEnv() {
    if (kIsWeb) return null;
    String? appId;
    if (Platform.isAndroid) {
      appId = _env('FIREBASE_ANDROID_APP_ID');
    } else if (Platform.isIOS || Platform.isMacOS) {
      appId = _env('FIREBASE_IOS_APP_ID');
    } else {
      return null;
    }
    final apiKey = _env('FIREBASE_API_KEY');
    final sender = _env('FIREBASE_MESSAGING_SENDER_ID');
    final project = _env('FIREBASE_PROJECT_ID');
    if (appId == null || apiKey == null || sender == null || project == null) return null;
    return FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: sender,
      projectId: project,
      iosBundleId: _env('FIREBASE_IOS_BUNDLE_ID'),
    );
  }

  static bool get configured => optionsFromEnv() != null;

  /// Registers this device for wake-ups (after sign-in). Never throws.
  Future<void> start() async {
    final options = optionsFromEnv();
    if (options == null || _started) return;
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: options);
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;
      // The server sends through the FCM HTTP v1 API, whose `message.token`
      // is the classic registration token (not the installation id that
      // register()/onRegistered return for FCM direct send).
      // ignore: deprecated_member_use
      final token = await messaging.getToken();
      if (token != null) await _directory.registerPushToken(token);
      // ignore: deprecated_member_use
      _refresh = messaging.onTokenRefresh.listen((t) {
        unawaited(_directory.registerPushToken(t).catchError((Object e) {
          debugPrint('Push token refresh failed: $e');
        }));
      });
      _foreground = FirebaseMessaging.onMessage.listen((_) => unawaited(onWake()));
      _started = true;
    } catch (e) {
      debugPrint('Push unavailable: $e');
    }
  }

  /// Sign-out: stop wake-ups for this device.
  Future<void> stop() async {
    await _refresh?.cancel();
    await _foreground?.cancel();
    _refresh = null;
    _foreground = null;
    if (!_started) return;
    _started = false;
    try {
      await _directory.clearPushToken();
      // ignore: deprecated_member_use
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
  }
}
