import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// On-device notifications for new messages and contact requests.
///
/// Notifications are built here, after decryption, so names and previews
/// never pass through the server or a push provider. A notification is shown
/// when the app is in the background, or when the message is for a chat
/// that isn't on screen. Users can turn notifications off, or keep them but
/// hide the message text.
class NotificationService {
  static const _enabledPref = 'notifications_enabled';
  static const _previewPref = 'notifications_preview';
  static const _channelId = 'messages';

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;
  bool _enabled = true;
  bool _showPreview = true;

  /// Set by the app lifecycle observer.
  bool appInForeground = true;

  /// Called with the contact id when a notification is tapped.
  void Function(String contactId)? onOpenChat;

  NotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  bool get enabled => _enabled;
  bool get showPreview => _showPreview;

  /// Platforms with a notification implementation.
  static bool get supported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isLinux ||
          Platform.isWindows);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledPref) ?? true;
    _showPreview = prefs.getBool(_previewPref) ?? true;
    if (!supported) return;
    try {
      const darwin = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      _ready = await _plugin.initialize(
            settings: const InitializationSettings(
              android: AndroidInitializationSettings('@drawable/ic_stat_notify'),
              iOS: darwin,
              macOS: darwin,
              linux: LinuxInitializationSettings(defaultActionName: 'Open'),
              windows: WindowsInitializationSettings(
                appName: 'Securely Hello',
                appUserModelId: 'SecurelyHello.App',
                guid: 'b3a8f1c2-2d4e-4c7a-9f61-3e5d7a9c0b11',
              ),
            ),
            onDidReceiveNotificationResponse: (r) {
              final id = r.payload;
              if (id != null && id.isNotEmpty) onOpenChat?.call(id);
            },
          ) ??
          false;
    } catch (e) {
      debugPrint('Notifications unavailable: $e');
      _ready = false;
    }
  }

  /// Asks the OS for permission where that is required (Android 13+, Apple).
  Future<void> requestPermission() async {
    if (!_ready || !_enabled) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      await _plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
    }
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledPref, value);
    if (value) await requestPermission();
  }

  Future<void> setShowPreview(bool value) async {
    _showPreview = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_previewPref, value);
  }

  /// Decides whether a message deserves a notification. Pure, for tests.
  static bool shouldNotify({
    required bool enabled,
    required bool appInForeground,
    required String? activeConversation,
    required String conversation,
  }) =>
      enabled && (!appInForeground || activeConversation != conversation);

  /// The text shown for a message. Pure, for tests.
  static ({String title, String body}) messageText({
    required String sender,
    required String preview,
    required bool showPreview,
  }) =>
      showPreview
          ? (title: sender, body: preview.isEmpty ? 'New message' : preview)
          : (title: 'Securely Hello', body: 'New message');

  Future<void> showMessage({
    required String contactId,
    required String sender,
    required String preview,
    required String? activeConversation,
  }) async {
    if (!_ready ||
        !shouldNotify(
          enabled: _enabled,
          appInForeground: appInForeground,
          activeConversation: activeConversation,
          conversation: contactId,
        )) {
      return;
    }
    final text = messageText(sender: sender, preview: preview, showPreview: _showPreview);
    await _show(contactId.hashCode & 0x7fffffff, text.title, text.body, contactId);
  }

  Future<void> showContactRequest(String text) async {
    if (!_ready || !_enabled || appInForeground) return;
    // Names are hidden like message text when previews are off.
    await _show(1, 'Securely Hello', _showPreview ? text : 'New contact activity', '');
  }

  Future<void> _show(int id, String title, String body, String payload) async {
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        payload: payload,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Messages',
            channelDescription: 'New messages and contact requests',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          linux: LinuxNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('Showing a notification failed: $e');
    }
  }

  /// The chat was opened: clear its notification.
  Future<void> clearFor(String contactId) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id: contactId.hashCode & 0x7fffffff);
    } catch (_) {}
  }
}
