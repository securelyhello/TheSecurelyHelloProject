import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/core/calls/call_system.dart';
import 'package:securelyhello/core/notifications/notification_model.dart';

export 'package:securelyhello/core/notifications/notification_model.dart' show MuteRules;

/// What a notification action asks for.
enum NotificationActionKind { reply, markRead, acceptCall, declineCall }

/// A Reply or Mark-as-read tapped on a message notification.
class NotificationAction {
  const NotificationAction(this.kind, this.chatId, [this.text = '']);
  final NotificationActionKind kind;
  final String chatId;
  final String text;

  Map<String, String> toMessage() => {'k': kind.name, 'c': chatId, 't': text};

  static NotificationAction? fromMessage(Object? m) {
    if (m is! Map) return null;
    final kind = NotificationActionKind.values.where((k) => k.name == m['k']).firstOrNull;
    final chat = m['c'];
    if (kind == null || chat is! String || chat.isEmpty) return null;
    return NotificationAction(kind, chat, (m['t'] as String?) ?? '');
  }

  /// From a plugin response; null for a plain tap.
  static NotificationAction? fromResponse(NotificationResponse r) {
    final chat = r.payload;
    if (chat == null || chat.isEmpty) return null;
    switch (r.actionId) {
      case NotificationService.replyAction:
        final text = (r.input ?? '').trim();
        return text.isEmpty ? null : NotificationAction(NotificationActionKind.reply, chat, text);
      case NotificationService.markReadAction:
        return NotificationAction(NotificationActionKind.markRead, chat);
      case NotificationService.acceptCallAction:
        return NotificationAction(NotificationActionKind.acceptCall, chat);
      case NotificationService.declineCallAction:
        return NotificationAction(NotificationActionKind.declineCall, chat);
    }
    return null;
  }
}

/// On-device notifications for messages, contact requests and the system.
///
/// Built here, after decryption, so names and previews never pass through
/// the server or a push provider. By default a notification says only
/// "New message"; users can show the sender and text. Message
/// notifications are grouped per chat in MessagingStyle with the sender's
/// photo, carry Reply and Mark-as-read actions (which work without opening
/// the app, see notification_actions.dart), and a summary with the unread
/// count drives the launcher badge. Chats can be muted.
class NotificationService implements IncomingCallNotifier {
  static const _enabledPref = 'notifications_enabled';
  static const _oldPreviewPref = 'notifications_preview';
  static const _showContentPref = 'notifications_show_content';
  static const _soundPref = 'notifications_sound';
  static const _mutesPref = 'notification_mutes';

  /// Android channels. Message channels carry the sound in their id (a
  /// channel's sound can't change after it is created).
  static const callsChannel = 'calls';
  static const requestsChannel = 'requests';
  static const systemChannel = 'system';
  static const _groupKey = 'securelyhello.messages';

  static const replyAction = 'reply';
  static const markReadAction = 'mark_read';
  static const acceptCallAction = 'call_accept';
  static const declineCallAction = 'call_decline';

  /// The port the main isolate listens on for actions handled in the
  /// background.
  static const portName = 'securelyhello_notification_actions';

  /// Sounds that come with the app (android/app/src/main/res/raw).
  static const sounds = ['default', 'chime', 'pop', 'bell', 'none'];

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;
  bool _enabled = true;
  bool _showContent = false;
  String _sound = 'default';
  MuteRules _mutes = MuteRules();
  final NotificationInbox _inbox = NotificationInbox();
  ReceivePort? _port;

  /// Set by the app lifecycle observer.
  bool appInForeground = true;

  /// A push arrived while the app runs in the background (fetch the queue).
  void Function()? onWake;

  /// Called with the contact id when a notification is tapped.
  void Function(String contactId)? onOpenChat;

  /// Handles a Reply / Mark-as-read. Until it is set (before sign-in, or
  /// while locked) actions wait in [_pending].
  Future<void> Function(NotificationAction action)? _onAction;
  final List<NotificationAction> _pending = [];

  NotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  bool get enabled => _enabled;

  /// Whether notifications show the sender and text (off by default).
  bool get showPreview => _showContent;
  String get sound => _sound;
  MuteRules get mutes => _mutes;

  set onAction(Future<void> Function(NotificationAction action)? handler) {
    _onAction = handler;
    if (handler == null) return;
    final waiting = List.of(_pending);
    _pending.clear();
    for (final a in waiting) {
      unawaited(_run(a));
    }
  }

  /// Platforms with a notification implementation.
  static bool get supported =>
      !kIsWeb &&
      (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isLinux || Platform.isWindows);

  String get _messagesChannel => 'messages_$_sound';
  String get _groupsChannel => 'groups_$_sound';

  Future<void> init({void Function(NotificationResponse)? backgroundHandler}) async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledPref) ?? true;
    // 1.0 showed previews unless turned off; 1.1 hides them unless turned on
    // (a choice made in 1.0 is kept).
    _showContent = prefs.getBool(_showContentPref) ?? (prefs.getBool(_oldPreviewPref) ?? false);
    _sound = sounds.contains(prefs.getString(_soundPref)) ? prefs.getString(_soundPref)! : 'default';
    _mutes = MuteRules.decode(prefs.getString(_mutesPref))..prune(DateTime.now());
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
            onDidReceiveNotificationResponse: _onResponse,
            onDidReceiveBackgroundNotificationResponse: backgroundHandler,
          ) ??
          false;
      await _createChannels();
    } catch (e) {
      debugPrint('Notifications unavailable: $e');
      _ready = false;
    }
    _listenForBackgroundActions();
  }

  /// Actions handled on a background isolate are passed here while the app
  /// runs, so the open database and sessions are used.
  void _listenForBackgroundActions() {
    if (kIsWeb) return;
    _port?.close();
    IsolateNameServer.removePortNameMapping(portName);
    final port = ReceivePort();
    IsolateNameServer.registerPortWithName(port.sendPort, portName);
    port.listen((m) {
      if (m is Map && m['k'] == 'wake') {
        onWake?.call();
        return;
      }
      final a = NotificationAction.fromMessage(m);
      if (a != null) unawaited(_run(a));
    });
    _port = port;
  }

  void _onResponse(NotificationResponse r) {
    final action = NotificationAction.fromResponse(r);
    if (action != null) {
      unawaited(_run(action));
      return;
    }
    final id = r.payload;
    if (id != null && id.isNotEmpty) onOpenChat?.call(id);
  }

  /// True while App Lock covers the app: Reply and Mark-as-read wait
  /// (in memory) until [runHeldActions] after the unlock.
  bool Function()? holdActions;
  final List<NotificationAction> _held = [];

  static bool _lockGated(NotificationAction a) =>
      a.kind == NotificationActionKind.reply || a.kind == NotificationActionKind.markRead;

  /// The app was unlocked: run what was held.
  Future<void> runHeldActions() async {
    if (holdActions?.call() ?? false) return;
    final waiting = List.of(_held);
    _held.clear();
    for (final a in waiting) {
      await _run(a);
    }
  }

  @visibleForTesting
  Future<void> debugRun(NotificationAction a) => _run(a);

  Future<void> _run(NotificationAction a) async {
    if (_lockGated(a) && (holdActions?.call() ?? false)) {
      _held.add(a);
      return;
    }
    final handler = _onAction;
    if (handler == null) {
      _pending.add(a);
      return;
    }
    try {
      await handler(a);
      switch (a.kind) {
        case NotificationActionKind.markRead:
          await clearFor(a.chatId);
        case NotificationActionKind.reply:
          await _showReplied(a);
        case NotificationActionKind.acceptCall:
        case NotificationActionKind.declineCall:
          await cancelIncomingCall();
      }
    } catch (e) {
      debugPrint('Notification action failed: $e');
    }
  }

  Future<void> _createChannels() async {
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    final sound = _sound == 'default' || _sound == 'none' ? null : RawResourceAndroidNotificationSound(_sound);
    for (final (id, name, desc) in [
      (_messagesChannel, 'Messages', 'New messages in your chats'),
      (_groupsChannel, 'Group messages', 'New messages in groups'),
    ]) {
      await android.createNotificationChannel(AndroidNotificationChannel(id, name,
          description: desc, importance: Importance.high, sound: sound, playSound: _sound != 'none'));
    }
    await android.createNotificationChannel(const AndroidNotificationChannel(callsChannel, 'Incoming calls',
        description: 'Rings for voice and video calls',
        importance: Importance.max,
        sound: UriAndroidNotificationSound('content://settings/system/ringtone'),
        audioAttributesUsage: AudioAttributesUsage.notificationRingtone));
    await android.createNotificationChannel(const AndroidNotificationChannel(requestsChannel, 'Contact requests',
        description: 'People who want to chat with you', importance: Importance.defaultImportance));
    await android.createNotificationChannel(const AndroidNotificationChannel(systemChannel, 'App and account',
        description: 'Updates, new devices and security notices', importance: Importance.low));
    // Message channels for other sounds, and 1.0's, go.
    for (final s in sounds.where((s) => s != _sound)) {
      await android.deleteNotificationChannel(channelId: 'messages_$s');
      await android.deleteNotificationChannel(channelId: 'groups_$s');
    }
    await android.deleteNotificationChannel(channelId: 'messages');
  }

  /// Asks the OS for permission where that is required (Android 13+, Apple).
  Future<void> requestPermission() async {
    if (!_ready || !_enabled) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      await _plugin
          .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
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
    _showContent = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showContentPref, value);
  }

  Future<void> setSound(String value) async {
    if (!sounds.contains(value) || value == _sound) return;
    _sound = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_soundPref, value);
    if (_ready) await _createChannels();
  }

  /// Mutes [chatId] for [duration] (null: until unmuted).
  Future<void> mute(String chatId, Duration? duration) async {
    _mutes.mute(chatId, duration, DateTime.now());
    await _saveMutes();
    await clearFor(chatId);
  }

  Future<void> unmute(String chatId) async {
    _mutes.unmute(chatId);
    await _saveMutes();
  }

  bool isMuted(String chatId) => _mutes.isMuted(chatId, DateTime.now());

  Future<void> _saveMutes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_mutesPref, _mutes.encode());
  }

  /// Decides whether a message deserves a notification. Pure, for tests.
  static bool shouldNotify({
    required bool enabled,
    required bool appInForeground,
    required String? activeConversation,
    required String conversation,
    bool muted = false,
  }) =>
      enabled && !muted && (!appInForeground || activeConversation != conversation);

  /// The text shown for a message. Pure, for tests.
  static ({String title, String body}) messageText({
    required String sender,
    required String preview,
    required bool showPreview,
    String? group,
  }) =>
      messageNotificationText(sender: sender, preview: preview, showPreview: showPreview, group: group);

  /// A new message in [contactId]'s chat (a contact or a group).
  Future<void> showMessage({
    required String contactId,
    required String sender,
    required String preview,
    required String? activeConversation,
    String? senderId,
    String? groupName,
    Uint8List? senderPhoto,
    DateTime? time,
  }) async {
    if (!_ready ||
        !shouldNotify(
          enabled: _enabled,
          appInForeground: appInForeground,
          activeConversation: activeConversation,
          conversation: contactId,
          muted: isMuted(contactId),
        )) {
      return;
    }
    final at = time ?? DateTime.now();
    final lines = _inbox.add(
        contactId, NotificationLine(sender: sender, senderId: senderId ?? contactId, text: preview, time: at));
    await _postChat(contactId, lines, groupName: groupName, photo: senderPhoto);
    await _postSummary();
  }

  final Map<String, Uint8List?> _photos = {};
  final Map<String, String?> _groupNames = {};

  Future<void> _postChat(String chatId, List<NotificationLine> lines,
      {String? groupName, Uint8List? photo, bool silent = false}) async {
    if (photo != null) _photos[lines.last.senderId] = photo;
    if (groupName != null) _groupNames[chatId] = groupName;
    final group = _groupNames[chatId];
    final last = lines.last;
    final text = messageText(sender: last.sender, preview: last.text, showPreview: _showContent, group: group);
    final count = _inbox.countFor(chatId);
    StyleInformation? style;
    if (_showContent) {
      style = MessagingStyleInformation(
        const Person(name: 'You', key: 'me'),
        conversationTitle: group,
        groupConversation: group != null,
        messages: [
          for (final l in lines)
            Message(
              l.text.isEmpty ? 'New message' : l.text,
              l.time,
              l.senderId == 'me'
                  ? null
                  : Person(
                      key: l.senderId,
                      name: l.sender,
                      icon: _photos[l.senderId] == null ? null : ByteArrayAndroidIcon(_photos[l.senderId]!),
                    ),
            ),
        ],
      );
    } else if (count > 1) {
      style = const DefaultStyleInformation(false, false);
    }
    final body = !_showContent && count > 1 ? '$count new messages' : text.body;
    try {
      await _plugin.show(
        id: NotificationIds.chat(chatId),
        title: text.title,
        body: body,
        payload: chatId,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            group == null ? _messagesChannel : _groupsChannel,
            group == null ? 'Messages' : 'Group messages',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.message,
            styleInformation: style,
            groupKey: _groupKey,
            number: count,
            silent: silent,
            onlyAlertOnce: silent,
            playSound: _sound != 'none',
            visibility: _showContent ? NotificationVisibility.private : NotificationVisibility.secret,
            actions: const [
              AndroidNotificationAction(
                replyAction,
                'Reply',
                inputs: [AndroidNotificationActionInput(label: 'Message')],
                semanticAction: SemanticAction.reply,
                cancelNotification: false,
              ),
              AndroidNotificationAction(markReadAction, 'Mark as read', semanticAction: SemanticAction.markAsRead),
            ],
          ),
          iOS: DarwinNotificationDetails(threadIdentifier: chatId, badgeNumber: _inbox.total),
          macOS: DarwinNotificationDetails(threadIdentifier: chatId, badgeNumber: _inbox.total),
          linux: const LinuxNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('Showing a notification failed: $e');
    }
  }

  /// Android groups the chats under one summary with the unread count.
  Future<void> _postSummary() async {
    if (!Platform.isAndroid) return;
    final total = _inbox.total;
    if (total == 0) {
      await _cancel(NotificationIds.summary);
      return;
    }
    final chats = _inbox.chats;
    try {
      await _plugin.show(
        id: NotificationIds.summary,
        title: 'Securely Hello',
        body: chats == 1 ? '$total new messages' : '$total new messages in $chats chats',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _messagesChannel,
            'Messages',
            groupKey: _groupKey,
            setAsGroupSummary: true,
            number: total,
            silent: true,
            styleInformation: InboxStyleInformation(const [], summaryText: '$total new messages'),
          ),
        ),
      );
    } catch (e) {
      debugPrint('Summary notification failed: $e');
    }
  }

  /// After a reply from the notification: the chat's notification shows it
  /// (Android expects the notification to be updated) without alerting.
  Future<void> _showReplied(NotificationAction a) async {
    if (!_ready) return;
    final lines = _inbox.add(a.chatId, NotificationLine(sender: 'You', senderId: 'me', text: a.text, time: DateTime.now()));
    await _postChat(a.chatId, lines, silent: true);
  }

  /// Reply or Mark-as-read with the app closed while App Lock is on: not
  /// done without the unlock (security review L3). Tapping opens the chat.
  Future<void> showUnlockToReply(String chatId) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: NotificationIds.chat(chatId),
        title: 'Securely Hello',
        body: 'Unlock Securely Hello to reply',
        payload: chatId,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            systemChannel,
            'App and account',
            importance: Importance.low,
            visibility: NotificationVisibility.private,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Unlock notice failed: $e');
    }
  }

  Future<void> showContactRequest(String text) async {
    if (!_ready || !_enabled || appInForeground) return;
    try {
      await _plugin.show(
        id: NotificationIds.request,
        title: 'Securely Hello',
        // Names are hidden like message text unless content is shown.
        body: _showContent ? text : 'New contact activity',
        payload: '',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(requestsChannel, 'Contact requests',
              category: AndroidNotificationCategory.social),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          linux: LinuxNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('Showing a notification failed: $e');
    }
  }

  /// A call ringing: full screen on a locked phone (where Android allows
  /// it), otherwise a heads-up notification, with Accept and Decline. It
  /// rings until answered (insistent) and follows Do Not Disturb's rules
  /// for calls. Names are shown only with "Show message text" on.
  @override
  Future<void> showIncomingCall({required String callId, required String name, required bool video}) async {
    if (!_ready || !_enabled) return;
    final kind = video ? 'video call' : 'voice call';
    try {
      await _plugin.show(
        id: NotificationIds.call,
        title: _showContent ? name : 'Securely Hello',
        body: 'Incoming $kind',
        payload: callId,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            callsChannel,
            'Incoming calls',
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.call,
            fullScreenIntent: true,
            ongoing: true,
            autoCancel: false,
            visibility: NotificationVisibility.public,
            timeoutAfter: 60000,
            audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
            additionalFlags: Int32List.fromList([4]), // FLAG_INSISTENT: keeps ringing
            actions: const [
              AndroidNotificationAction(declineCallAction, 'Decline', semanticAction: SemanticAction.delete),
              AndroidNotificationAction(acceptCallAction, 'Answer', showsUserInterface: true),
            ],
          ),
          iOS: const DarwinNotificationDetails(interruptionLevel: InterruptionLevel.timeSensitive),
          macOS: const DarwinNotificationDetails(),
          linux: const LinuxNotificationDetails(urgency: LinuxNotificationUrgency.critical),
        ),
      );
    } catch (e) {
      debugPrint('Incoming-call notification failed: $e');
    }
  }

  @override
  Future<void> cancelIncomingCall() => _cancel(NotificationIds.call);

  /// The chat was opened (or marked read): clear its notification.
  Future<void> clearFor(String contactId) async {
    _inbox.clear(contactId);
    if (!_ready) return;
    await _cancel(NotificationIds.chat(contactId));
    await _postSummary();
  }

  Future<void> _cancel(int id) async {
    try {
      await _plugin.cancel(id: id);
    } catch (_) {}
  }
}
