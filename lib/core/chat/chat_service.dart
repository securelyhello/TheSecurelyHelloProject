import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:securelyhello/core/backup/chat_backup.dart';
import 'package:securelyhello/core/chat/attachment_service.dart';
import 'package:securelyhello/core/chat/group_state.dart';
import 'package:securelyhello/core/chat/profile_service.dart';
import 'package:securelyhello/core/media/voice.dart';
import 'package:securelyhello/core/chat/wire_protocol.dart';
import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/crypto/device_manager.dart';
import 'package:securelyhello/core/crypto/ratchet.dart';
import 'package:securelyhello/core/crypto/session_manager.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/storage/local_storage.dart';

part 'chat_groups.dart';

// Domain models

/// Local representation of a chat message.
class Message {
  final String id;

  /// The contact's user id for a 1:1 chat; `g_<uuid>` for a group.
  final String conversationId;
  final String senderId;

  /// Decrypted text (may be empty when there is an attachment).
  final String content;

  final DateTime timestamp;

  /// Outgoing: `sending`, `sent`, `delivered`, `read`, `failed`.
  /// Incoming: `received` or `read`.
  final String status;

  final bool isFromMe;

  /// `text` for chat messages, `system` for local notices.
  final String kind;

  /// Attachment metadata (see `AttachmentService`), if any.
  final Map<String, dynamic>? attachment;

  /// The message this one replies to: `{id, from, preview}`.
  final Map<String, dynamic>? replyTo;

  /// When the sender last edited it.
  final DateTime? editedAt;

  /// Deleted for everyone (a tombstone).
  final bool deleted;

  /// Reactions: user id → emoji.
  final Map<String, String> reactions;

  /// When this message disappears (disappearing messages), if ever.
  final DateTime? expiresAt;

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.content,
    required this.timestamp,
    required this.status,
    required this.isFromMe,
    this.kind = 'text',
    this.attachment,
    this.replyTo,
    this.editedAt,
    this.deleted = false,
    this.reactions = const {},
    this.expiresAt,
  });

  bool get isSystem => kind == 'system';

  Message withReactions(Map<String, String> r) => Message(
        id: id,
        conversationId: conversationId,
        senderId: senderId,
        content: content,
        timestamp: timestamp,
        status: status,
        isFromMe: isFromMe,
        kind: kind,
        attachment: attachment,
        replyTo: replyTo,
        editedAt: editedAt,
        deleted: deleted,
        reactions: r,
        expiresAt: expiresAt,
      );
  bool get hasAttachment => attachment != null;

  factory Message.fromMap(Map<String, dynamic> map) {
    Map<String, dynamic>? json(String? raw) {
      if (raw == null) return null;
      try {
        return Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (_) {
        return null;
      }
    }

    final attachment = json(map['attachment'] as String?);
    final edited = map['edited_at'] as int?;
    final expires = map['expires_at'] as int?;
    return Message(
      id: map['id'] as String,
      conversationId: map['conversation_id'] as String,
      senderId: map['sender_id'] as String,
      content: map['content'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      status: map['status'] as String,
      isFromMe: (map['is_from_me'] as int) == 1,
      kind: map['kind'] as String? ?? 'text',
      attachment: attachment,
      replyTo: json(map['reply_to'] as String?),
      editedAt: edited == null ? null : DateTime.fromMillisecondsSinceEpoch(edited),
      deleted: (map['deleted'] as int? ?? 0) == 1,
      expiresAt: expires == null ? null : DateTime.fromMillisecondsSinceEpoch(expires),
    );
  }
}

/// Local representation of a conversation list entry.
class Conversation {
  final String id;
  final String contactUserId;
  final String? lastMessage;
  final DateTime? lastMessageTime;
  final int unreadCount;

  const Conversation({
    required this.id,
    required this.contactUserId,
    this.lastMessage,
    this.lastMessageTime,
    this.unreadCount = 0,
  });

  factory Conversation.fromMap(Map<String, dynamic> map) {
    return Conversation(
      id: map['id'] as String,
      contactUserId: map['contact_user_id'] as String,
      lastMessage: map['last_message'] as String?,
      lastMessageTime: map['last_message_time'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['last_message_time'] as int)
          : null,
      unreadCount: (map['unread_count'] as int?) ?? 0,
    );
  }
}

/// A peer started or stopped typing.
class TypingEvent {
  final String contactId;
  final bool isTyping;
  const TypingEvent(this.contactId, this.isTyping);
}

/// One in-flight WebRTC handshake with one device of a contact.
class _Negotiation {
  final String userId;
  final String deviceId;
  final bool isCaller;
  final String sessionId;
  bool answerApplied = false;

  /// Our offer / answer has been sent, so our ICE candidates may follow.
  bool descriptionSent = false;

  /// The peer connection exists, so their ICE candidates can be applied.
  bool peerReady = false;
  Timer? timeout;
  final List<Map<String, dynamic>> pendingLocalIce = [];
  final List<Map<String, dynamic>> pendingRemoteIce = [];

  _Negotiation(this.userId, this.deviceId,
      {required this.isCaller, required this.sessionId});

  String get address => '$userId:$deviceId';
}

/// Splits a P2P address `user:device`.
({String userId, String deviceId}) _splitAddress(String address) {
  final i = address.indexOf(':');
  return (userId: address.substring(0, i), deviceId: address.substring(i + 1));
}

// ChatService

/// Orchestrates end-to-end encrypted messaging between devices.
///
/// A message to a contact is encrypted separately for each of their devices
/// with that device's Double Ratchet session (forward secrecy), and copied
/// to each of our own other devices as a `sync` payload. Per device, the
/// envelope goes:
/// 1. over the WebRTC data channel with that device, if one is open;
/// 2. otherwise into that device's relay queue on the server (ciphertext
///    only, 24 h expiry), while a P2P connection is negotiated in the
///    background.
class ChatService {
  static const _negotiationTimeout = Duration(seconds: 30);
  static const _receiptDebounce = Duration(milliseconds: 300);

  final LocalStorage _storage;
  final P2PConnectionManager _p2p;
  final DirectoryService _directory;
  final DeviceManager _devices;
  late final AttachmentService attachments = AttachmentService(
      directory: _directory, cacheDirectory: _storage.attachmentsDir);
  final _uuid = const Uuid();

  CryptoIdentity? _identity;
  String? _myUserId;
  String? _myDeviceId;
  SessionManager? _sessions;
  bool _started = false;
  String? _activeConversationId;

  /// When `false`, incoming messages are only acknowledged as delivered.
  bool sendReadReceipts = true;

  /// Keyed by P2P address (`user:device`).
  final Map<String, _Negotiation> _negotiations = {};
  final Set<String> _handledOfferSessions = {};
  final Set<String> _directLinks = {};
  Future<void> _relayChain = Future.value();
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  /// Groups by conversation id, and public names of group members who
  /// aren't contacts (see chat_groups.dart).
  final Map<String, GroupState> _groups = {};
  final Map<String, Map<String, String>> _memberNames = {};

  // Batched outgoing receipts: contactId (or contactId|groupId) → status → ids.
  final Map<String, Map<ReceiptStatus, Set<String>>> _pendingReceipts = {};
  final Map<String, Timer> _receiptTimers = {};

  bool _draining = false;
  bool _drainAgain = false;
  bool _resending = false;

  final StreamController<String> _conversationChangedController =
      StreamController<String>.broadcast();
  final StreamController<Message> _onMessageReceivedController =
      StreamController<Message>.broadcast();
  final StreamController<TypingEvent> _typingController =
      StreamController<TypingEvent>.broadcast();
  final StreamController<String> _devicesChangedController =
      StreamController<String>.broadcast();

  ChatService({
    required LocalStorage storage,
    required P2PConnectionManager p2p,
    required DirectoryService directory,
    DeviceManager? deviceManager,
  })  : _storage = storage,
        _p2p = p2p,
        _directory = directory,
        _devices = deviceManager ??
            DeviceManager(storage: storage, directory: directory);

  /// Emits a contact id whenever that conversation's messages or metadata
  /// changed (new message, status update, system notice…).
  Stream<String> get onConversationChanged =>
      _conversationChangedController.stream;

  /// Emits each newly received chat message.
  Stream<Message> get onMessageReceived => _onMessageReceivedController.stream;

  /// Emits typing indicators from peers.
  Stream<TypingEvent> get onTyping => _typingController.stream;

  /// Emits a user id when that user's (or our own) devices changed.
  Stream<String> get onDevicesChanged => _devicesChangedController.stream;

  /// Call signaling (offers, answers, ICE, hang-ups), decrypted. See
  /// CallService.
  Stream<CallSignal> get onCallSignal => _callSignals.stream;
  final _callSignals = StreamController<CallSignal>.broadcast();

  /// Sends call signaling [data] to [userId] end to end, to [devices] only
  /// if given. The SDP inside carries the media's DTLS fingerprints, so it
  /// must not travel any other way.
  Future<bool> sendCallSignal(String userId, Map<String, dynamic> data, {Set<String>? devices}) async {
    final me = _requireUserId();
    return _deliver(
      userId,
      WirePayload.call(from: me, to: userId, timestampMs: DateTime.now().millisecondsSinceEpoch, call: data),
      onlyDevices: devices,
    );
  }

  /// Adds a call record ("Missed voice call", ...) to the chat with
  /// [contactId] on this device.
  Future<void> addCallNotice(String contactId, String text) async {
    await _storage.insertSystemMessage(contactId, text, id: _uuid.v4());
    await _storage.updateConversation(
        id: contactId,
        contactUserId: contactId,
        lastMessage: text,
        lastMessageTime: DateTime.now().millisecondsSinceEpoch);
    _changed(contactId);
  }

  bool get isStarted => _started;
  String? get myUserId => _myUserId;
  String? get myDeviceId => _myDeviceId;
  CryptoIdentity? get identity => _identity;
  DeviceManager get deviceManager => _devices;

  // Lifecycle

  /// Starts messaging for the signed-in user on this device.  Idempotent
  /// per user.  [deviceId] is the id the device registered with.
  Future<void> start({
    required CryptoIdentity identity,
    required String myUserId,
    required String deviceId,
  }) async {
    if (_started && _myUserId == myUserId && _myDeviceId == deviceId) return;
    await stop();

    _identity = identity;
    _myUserId = myUserId;
    _myDeviceId = deviceId;
    _sessions = SessionManager(
      storage: _storage,
      directory: _directory,
      identity: identity,
      myUserId: myUserId,
      myDeviceId: deviceId,
      onDevicesChanged: _onDeviceListChanged,
    );

    _subscriptions
      ..add(_directory.signals.listen(_onSignal))
      ..add(_directory.signalErrors.listen(_onSignalError))
      ..add(_directory.relayPushes.listen(_onRelayPush))
      ..add(_directory.realtimeState.listen(_onRealtimeState))
      ..add(_directory.presenceEvents.listen(_onPresence))
      ..add(_directory.contactEvents.listen(_onContactEvent))
      ..add(_directory.prekeysLow.listen((_) => unawaited(_devices.topUp())))
      ..add(_p2p.onIceCandidate.listen(_onLocalIceCandidate))
      ..add(_p2p.onConnectionStateChange.listen(_onConnectionStateChange))
      ..add(_p2p.onDataChannelMessage
          .listen((e) => _handleIncomingBytes(e.contactId, e.data)));

    _started = true;
    unawaited(_refreshTurn());
    await profiles.load();
    await _loadGroups();
    _sweeper = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(sweepExpired()));
    unawaited(sweepExpired());

    // Opens the socket; if we are offline it keeps retrying on its own and
    // `_onRealtimeState(true)` picks up from there.
    await _directory.startRealtime();
    await drainRelayQueue();
    unawaited(resendUnsent());
    unawaited(_storage.pruneSeenEnvelopes(DateTime.now()
        .subtract(const Duration(days: 30))
        .millisecondsSinceEpoch));
  }

  /// The socket is (back) up: collect what we missed, push what was stuck,
  /// and bring the open chat's direct link back.
  void _onRealtimeState(bool up) {
    if (!up || !_started) return;
    unawaited(drainRelayQueue().then((_) => resendUnsent()));
    unawaited(sendProfileIfNeeded(const []));
    final active = _activeConversationId;
    if (active != null) unawaited(connect(active));
  }

  void _onPresence(PresenceEvent event) {
    // They just came online and we are looking at their chat: go direct.
    if (event.online && _activeConversationId == event.userId) {
      unawaited(connect(event.userId));
    }
  }

  void _onContactEvent(ContactEvent event) {
    final userId = event.userId;
    if (userId == null) return;
    if (event.type == 'devices_changed') {
      unawaited(_sessions
          ?.devices(userId, refresh: true)
          // A new device of theirs gets our profile photo too.
          .then<void>((_) => sendProfileIfNeeded(const []))
          .catchError((Object e) => debugPrint('Device refresh failed: $e')));
    } else if (event.type == 'contact_removed') {
      for (final neg in _negotiations.values.toList()) {
        if (neg.userId == userId) unawaited(_abandon(neg, notifyPeer: false));
      }
      unawaited(_p2p.closeConnectionsWithPrefix('$userId:'));
    }
  }

  void _onDeviceListChanged(String userId, DeviceListChange change) {
    if (!_devicesChangedController.isClosed) {
      _devicesChangedController.add(userId);
    }
    if (userId == _myUserId) return;
    for (final d in change.removed) {
      unawaited(_p2p.closeConnection('$userId:$d'));
    }
    unawaited(_noteDevicesChanged(userId, change));
  }

  /// Stops everything for the current user (sign-out / account switch).
  Future<void> stop() async {
    _started = false;
    profiles.reset();
    _profileTargets.clear();
    _profileChecked.clear();
    _groups.clear();
    _memberNames.clear();
    _sweeper?.cancel();
    _sweeper = null;
    _turnTimer?.cancel();
    _turnTimer = null;
    _p2p.setServerTurn(null);
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();

    for (final neg in _negotiations.values) {
      neg.timeout?.cancel();
    }
    _negotiations.clear();
    _handledOfferSessions.clear();
    _directLinks.clear();

    for (final t in _receiptTimers.values) {
      t.cancel();
    }
    _receiptTimers.clear();
    _pendingReceipts.clear();

    await _p2p.closeAll();
    await _directory.stopRealtime();

    _identity = null;
    _myUserId = null;
    _myDeviceId = null;
    _sessions = null;
    _activeConversationId = null;
    attachments.clearMemory();
  }

  /// Tells the service which chat is on screen, so incoming messages there
  /// are marked read immediately.
  void setActiveConversation(String? contactId) {
    _activeConversationId = contactId;
  }

  // Queries

  Future<List<Conversation>> fetchConversations() async {
    final rows = await _storage.getConversations();
    return rows.map(Conversation.fromMap).toList();
  }

  Future<List<Message>> fetchMessages(
    String contactId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final rows =
        await _storage.getMessages(contactId, limit: limit, offset: offset);
    final messages = rows.map(Message.fromMap).toList();
    final reactions = await _storage.reactionsFor([for (final m in messages) m.id]);
    return [
      for (final m in messages)
        reactions[m.id] == null ? m : m.withReactions(reactions[m.id]!)
    ];
  }

  Future<Message?> getMessage(String id) async {
    final row = await _storage.getMessage(id);
    return row == null ? null : Message.fromMap(row);
  }

  /// Ensures a (possibly empty) conversation row exists for [contactId].
  Future<void> ensureConversation(String contactId) async {
    await _storage.updateConversation(id: contactId, contactUserId: contactId);
  }

  Future<void> clearConversation(String contactId) async {
    await _storage.clearConversation(contactId);
    _changed(contactId);
  }

  /// Deletes a chat from this device. For a group we're still in, leaves it
  /// first, or its messages would bring the chat back.
  Future<void> deleteConversation(String contactId) async {
    if (_groups[contactId]?.isMember(_requireUserId()) ?? false) await leaveGroup(contactId);
    await _storage.deleteConversation(contactId);
    _changed(contactId);
  }

  /// Profile photos and "about" lines (ours and our contacts').
  late final ProfileService profiles = ProfileService(storage: _storage);

  /// Changes our profile and sends it to our other devices and [contactIds].
  Future<void> setMyProfile(List<String> contactIds,
      {Uint8List? photo, bool removePhoto = false, String? about}) async {
    final me = _requireUserId();
    final p = await profiles.setMine(me, photo: photo, removePhoto: removePhoto, about: about);
    _profileTargets.addAll(contactIds);
    await _deliver(me, WirePayload.profile(
        from: me, to: me, timestampMs: DateTime.now().millisecondsSinceEpoch, profile: p),
        relayOnly: true);
    await sendProfileIfNeeded(contactIds);
  }

  /// Everyone our profile goes to (the contacts list); kept so a reconnect
  /// or a contact's new device can catch up without the UI asking.
  final Set<String> _profileTargets = {};
  Future<void>? _profileSync;
  bool _profileSyncAgain = false;

  /// Sends our current profile to every device of [contactIds] that doesn't
  /// have it yet. Profile updates always go through the relay: it stores
  /// them until the device collects them, whereas a write to a direct link
  /// that is about to drop is lost with nothing to retry it.
  ///
  /// With [replace], [contactIds] is the whole contacts list.
  Future<void> sendProfileIfNeeded(List<String> contactIds, {bool replace = false}) {
    if (replace) _profileTargets.clear();
    _profileTargets.addAll(contactIds);
    if (_profileSync != null) {
      _profileSyncAgain = true;
      return _profileSync!;
    }
    return _profileSync = () async {
      try {
        do {
          _profileSyncAgain = false;
          await _sendProfileOnce(_profileTargets.toList());
        } while (_profileSyncAgain);
      } finally {
        _profileSync = null;
      }
    }();
  }

  Future<void> _sendProfileOnce(List<String> contactIds) async {
    final me = _myUserId;
    final sessions = _sessions;
    if (me == null || sessions == null || !_started) return;
    final p = await profiles.mine(me);
    if (p == null) return;
    final v = p['v'] as int;
    for (final id in contactIds) {
      if (id == me) continue;
      try {
        final devices = (await sessions.devices(id)).map((d) => d.deviceId);
        final need = await profiles.devicesNeeding(id, v, devices, resendAfter: profileResendAfter);
        if (need.isEmpty) continue;
        final ok = await _deliver(id, WirePayload.profile(
            from: me, to: id, timestampMs: DateTime.now().millisecondsSinceEpoch, profile: p),
            onlyDevices: need, relayOnly: true);
        if (ok) await profiles.markSent(id, v, need);
      } catch (e) {
        debugPrint('Profile to $id not sent: $e');
      }
    }
  }

  /// How long a queued profile counts as on its way; see
  /// [ProfileService.resendAfter].
  @visibleForTesting
  Duration profileResendAfter = ProfileService.resendAfter;

  final Map<String, DateTime> _profileChecked = {};

  /// [contactId] is active: if one of their devices may have missed our
  /// profile (it sat in the relay longer than the relay keeps things), send
  /// it again. At most every few minutes per contact.
  void _heardFrom(String contactId) {
    if (!_profileTargets.contains(contactId)) return;
    final last = _profileChecked[contactId];
    final now = DateTime.now();
    final every = profileResendAfter < const Duration(minutes: 5)
        ? profileResendAfter
        : const Duration(minutes: 5);
    if (last != null && now.difference(last) < every) return;
    _profileChecked[contactId] = now;
    unawaited(_sendProfileOnce([contactId]));
  }

  /// Tells the device that sent us version `v` of a profile that we have it
  /// (or a newer one), so it stops re-sending. A receipt for an id that is
  /// no message: 1.0 apps ignore it.
  Future<void> _ackProfile(String contactId, String device, Map<String, dynamic> profile) async {
    final v = profile['v'];
    final me = _myUserId;
    if (v is! int || me == null) return;
    try {
      await _deliver(contactId, WirePayload.receipt(
          from: me, to: contactId, timestampMs: DateTime.now().millisecondsSinceEpoch,
          ids: [ProfileService.ackId(v)], status: ReceiptStatus.delivered),
          onlyDevices: {device});
    } catch (e) {
      debugPrint('Profile acknowledgement to $contactId not sent: $e');
    }
  }

  /// Fires with the number of messages added when history arrives from
  /// another of our devices.
  Stream<int> get onHistoryImported => _historyImported.stream;
  final _historyImported = StreamController<int>.broadcast();

  /// Sends our chats to our other devices (e.g. one just approved). The
  /// archive is uploaded encrypted; its key goes end to end. Returns how
  /// many messages it carried.
  Future<int> sendHistoryToMyDevices() async {
    final me = _requireUserId();
    // A device approved a moment ago isn't in our cached list yet.
    await devicesOf(me, refresh: true);
    final history = await _storage.exportHistory();
    final bytes = ChatBackup.packTransfer(history);
    final meta = await attachments.upload(bytes, name: 'history.json.gz', mime: 'application/gzip');
    await _deliver(me, WirePayload.history(me: me, timestampMs: DateTime.now().millisecondsSinceEpoch, archive: meta));
    return (history['messages'] as List).length;
  }

  /// Exports our chats into an encrypted backup file sealed with [backupKey].
  Future<Uint8List> exportBackup(String backupKey) async =>
      ChatBackup.seal(await _storage.exportHistory(), userId: _requireUserId(), backupKey: backupKey);

  /// Restores a backup file; returns how many messages were added.
  Future<int> restoreBackup(Uint8List file, String backupKey) async {
    final history = await ChatBackup.open(file, userId: _requireUserId(), backupKey: backupKey);
    return _importHistory(history);
  }

  Future<void> _importHistoryFrom(Map<String, dynamic> meta) async {
    try {
      final bytes = await attachments.load(meta);
      final added = await _importHistory(ChatBackup.unpackTransfer(bytes));
      if (!_historyImported.isClosed) _historyImported.add(added);
      await attachments.forget(meta);
    } catch (e) {
      debugPrint('History transfer failed: $e');
    }
  }

  Future<int> _importHistory(Map<String, dynamic> history) async {
    final added = await _storage.importHistory(history);
    await _mergeGroups(history);
    await profiles.load();
    for (final c in await _storage.getConversations()) {
      _changed(c['id'] as String);
    }
    return added;
  }

  /// Device keys of [userId] (for ourselves: every device, this one first).
  Future<List<DeviceKeys>> devicesOf(String userId, {bool refresh = false}) async {
    final sessions = _sessions;
    if (sessions == null) return const [];
    if (refresh) await sessions.devices(userId, refresh: true);
    return sessions.allDeviceKeys(userId);
  }

  /// The 60-digit safety number shared with [contactId]. It covers every
  /// device of both people, so it changes whenever either adds a device.
  Future<String?> safetyNumberFor(String contactId) async {
    final me = _myUserId;
    if (me == null || _sessions == null || GroupState.isGroup(contactId)) return null;
    try {
      final mine = await devicesOf(me);
      final theirs = await devicesOf(contactId);
      if (theirs.isEmpty) return null;
      return CryptoCore.safetyNumber(
        myUserId: me,
        myDeviceKeys: [for (final d in mine) '${d.signingKey}|${d.identityKey}'],
        theirUserId: contactId,
        theirDeviceKeys: [
          for (final d in theirs) '${d.signingKey}|${d.identityKey}'
        ],
      );
    } catch (e) {
      debugPrint('Safety number unavailable: $e');
      return null;
    }
  }

  /// A digest of [devices]' keys: what verifying a contact pins.
  static String keySetDigest(List<DeviceKeys> devices) {
    final keys = [for (final d in devices) '${d.signingKey}|${d.identityKey}']..sort();
    return CryptoCore.toBase64(Kdf.sha256(Uint8List.fromList(utf8.encode(keys.join(',')))));
  }

  /// Whether [contactId] is verified, and whether their keys changed since.
  Future<Verification> verificationOf(String contactId) async {
    if (GroupState.isGroup(contactId)) return Verification.unverified;
    final pinned = await _storage.kvGet('verified:$contactId');
    if (pinned == null) return Verification.unverified;
    final current = await devicesOf(contactId);
    // No keys to check the pin against: unknown, so never shown (or trusted)
    // as verified. The pin stays, so the same keys verify again later.
    if (current.isEmpty) return Verification.unverified;
    return keySetDigest(current) == pinned ? Verification.verified : Verification.changed;
  }

  /// Pins [contactId]'s current keys after the user compared safety numbers
  /// (or scanned the QR code).
  ///
  /// [comparedNumber] is the safety number the user compared or scanned.
  /// The keys are fetched again and must still give that number; otherwise
  /// something changed in between and the user has to compare again
  /// (audit run 1, U4-2).
  Future<void> markVerified(String contactId, {required String comparedNumber}) async {
    final current = await devicesOf(contactId, refresh: true);
    if (current.isEmpty) throw StateError('No keys for $contactId');
    final now = await safetyNumberFor(contactId);
    String digits(String s) => s.replaceAll(RegExp(r'\D'), '');
    if (now == null || digits(now) != digits(comparedNumber)) {
      throw const SafetyNumberChangedException();
    }
    await _storage.kvSet('verified:$contactId', keySetDigest(current));
    _changed(contactId);
    unawaited(resendUnsent());
  }

  /// Drops verification: after a key change the user chose to trust the new
  /// keys without comparing again, or they want to unverify.
  Future<void> clearVerified(String contactId) async {
    await _storage.kvDelete('verified:$contactId');
    _changed(contactId);
    unawaited(resendUnsent());
  }

  // Sending

  /// Stores a message locally and delivers it to [contactId]'s devices (and
  /// a copy to our own other devices).
  Future<Message> sendMessage(
    String contactId,
    String plaintext, {
    Map<String, dynamic>? attachment,
    Map<String, dynamic>? replyTo,
  }) async {
    final me = _requireUserId();
    final id = _uuid.v4();
    final now = DateTime.now();
    final attachmentJson = attachment == null ? null : jsonEncode(attachment);
    final reply = replyTo == null ? null : _replyRef(replyTo);
    final timer = await _storage.disappearAfter(contactId);
    final expiresAt = timer > 0 ? now.millisecondsSinceEpoch + timer * 1000 : null;

    await _storage.insertMessage(
      id: id,
      conversationId: contactId,
      senderId: me,
      content: plaintext,
      timestamp: now.millisecondsSinceEpoch,
      status: 'sending',
      isFromMe: true,
      attachment: attachmentJson,
      replyTo: reply == null ? null : jsonEncode(reply),
      expiresAt: expiresAt,
    );
    await _storage.updateConversation(
      id: contactId,
      contactUserId: contactId,
      lastMessage: previewText(plaintext, attachment),
      lastMessageTime: now.millisecondsSinceEpoch,
    );
    _changed(contactId);

    final status = await _transmitMessage(contactId, id, plaintext,
        now.millisecondsSinceEpoch, attachment, reply, timer > 0 ? timer : null);
    _changed(contactId);

    unawaited(_syncToOwnDevices(WirePayload.sentSync(
      me: me,
      conversation: contactId,
      messageId: id,
      timestampMs: now.millisecondsSinceEpoch,
      body: plaintext,
      attachment: attachment == null ? null : _wireAttachment(attachment),
      reply: reply,
      expireSeconds: timer > 0 ? timer : null,
    )));

    if (!GroupState.isGroup(contactId) && !_p2p.hasConnectionWithPrefix('$contactId:')) {
      unawaited(connect(contactId));
    }

    return Message(
      id: id,
      conversationId: contactId,
      senderId: me,
      content: plaintext,
      timestamp: now,
      status: status,
      isFromMe: true,
      attachment: attachment,
      replyTo: reply,
      expiresAt: expiresAt == null ? null : DateTime.fromMillisecondsSinceEpoch(expiresAt),
    );
  }

  /// A reply reference: id, author and a short preview.
  static Map<String, dynamic> _replyRef(Map<String, dynamic> r) {
    final preview = (r['preview'] as String? ?? '');
    return {
      'id': r['id'],
      'from': r['from'],
      'preview': preview.length > 120 ? '${preview.substring(0, 120)}…' : preview,
    };
  }

  // Reactions, edits, deletion

  /// Own messages can be edited or deleted for everyone this long after
  /// sending (enforced by every receiving device).
  static const editWindow = Duration(hours: 24);

  static bool canEdit(Message m) =>
      m.isFromMe &&
      !m.deleted &&
      !m.isSystem &&
      DateTime.now().difference(m.timestamp) < editWindow;

  /// Sets our reaction to [messageId] ('' removes it).
  Future<void> react(String contactId, String messageId, String emoji) async {
    final me = _requireUserId();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _storage.setReaction(messageId, me, emoji, now);
    _changed(contactId);
    await _sendAction(contactId, PayloadKind.react, messageId, emoji: emoji);
  }

  /// Replaces the text of our message [messageId].
  Future<bool> editMessage(String contactId, String messageId, String text) async {
    final row = await _storage.getMessage(messageId);
    if (row == null || text.trim().isEmpty) return false;
    final m = Message.fromMap(row);
    if (m.conversationId != contactId || !canEdit(m)) return false;
    await _storage.editMessage(messageId, text, DateTime.now().millisecondsSinceEpoch);
    await _refreshPreview(contactId);
    _changed(contactId);
    await _sendAction(contactId, PayloadKind.edit, messageId, body: text);
    return true;
  }

  /// Deletes our message [messageId] on every device of both people.
  Future<bool> deleteForEveryone(String contactId, String messageId) async {
    final row = await _storage.getMessage(messageId);
    if (row == null) return false;
    final m = Message.fromMap(row);
    if (m.conversationId != contactId || !canEdit(m)) return false;
    await _storage.tombstoneMessage(messageId);
    await _refreshPreview(contactId);
    _changed(contactId);
    await _sendAction(contactId, PayloadKind.delete, messageId);
    return true;
  }

  /// Removes a message from this device only.
  Future<void> deleteForMe(String contactId, String messageId) async {
    await _storage.deleteMessage(messageId);
    await _refreshPreview(contactId);
    _changed(contactId);
  }

  // Disappearing messages

  static const disappearChoices = [0, 300, 3600, 86400, 604800];

  static String disappearLabel(int seconds) => switch (seconds) {
        0 => 'Off',
        300 => '5 minutes',
        3600 => '1 hour',
        86400 => '1 day',
        604800 => '1 week',
        _ => seconds < 3600 ? '${seconds ~/ 60} minutes' : '${seconds ~/ 3600} hours',
      };

  Future<int> disappearAfter(String contactId) => _storage.disappearAfter(contactId);

  /// Sets the timer for new messages with [contactId] (0 turns it off) for
  /// both people and all of their devices.
  Future<void> setDisappearing(String contactId, int seconds) async {
    final me = _requireUserId();
    await _applyTimer(contactId, me, seconds);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (GroupState.isGroup(contactId)) {
      await _sendToGroup(contactId,
          (to, gid) => WirePayload.timer(from: me, to: to, timestampMs: now, seconds: seconds, groupId: gid));
    } else {
      try {
        await _deliver(contactId,
            WirePayload.timer(from: me, to: contactId, timestampMs: now, seconds: seconds));
      } catch (e) {
        debugPrint('Timer to $contactId failed: $e');
      }
    }
    unawaited(_syncToOwnDevices(WirePayload.timer(
        from: me, to: me, timestampMs: now, seconds: seconds, conversation: contactId)));
  }

  Future<void> _applyTimer(String conversation, String actor, int seconds) async {
    if (await _storage.disappearAfter(conversation) == seconds) return;
    await _storage.setDisappearAfter(conversation, seconds);
    final who = ChatGroups._capitalized(await _noticeName(actor));
    await _storage.insertSystemMessage(
      conversation,
      seconds == 0
          ? '$who turned off disappearing messages.'
          : '$who set messages to disappear after ${disappearLabel(seconds).toLowerCase()}.',
      id: _uuid.v4(),
    );
    _changed(conversation);
  }

  int? _expiryFrom(int? seconds) => seconds == null || seconds <= 0
      ? null
      : DateTime.now().millisecondsSinceEpoch + seconds * 1000;

  /// Seconds left for a message being re-sent (keeps the original deadline).
  int? _remaining(Message m) {
    final e = m.expiresAt;
    if (e == null) return null;
    final left = e.difference(DateTime.now()).inSeconds;
    return left > 0 ? left : 1;
  }

  Timer? _sweeper;

  /// ICE servers for direct links and calls, with our server's TURN relay.
  List<Map<String, dynamic>> get iceServers => _p2p.iceServers;

  Timer? _turnTimer;

  /// Fetches TURN credentials and renews them before they expire.
  Future<void> _refreshTurn() async {
    Duration next = const Duration(minutes: 5);
    try {
      final turn = await _directory.turnServer();
      _p2p.setServerTurn(turn?.server);
      if (turn != null) next = turn.ttl * 0.8;
    } catch (e) {
      debugPrint('TURN credentials unavailable: $e');
    }
    if (!_started) return;
    _turnTimer?.cancel();
    _turnTimer = Timer(next, () => unawaited(_refreshTurn()));
  }

  /// Removes expired messages (and their cached attachments) now.
  Future<void> sweepExpired() async {
    if (!_started) return;
    try {
      final gone = await _storage.deleteExpired(DateTime.now().millisecondsSinceEpoch);
      for (final raw in gone.attachments) {
        try {
          await attachments.forget(Map<String, dynamic>.from(jsonDecode(raw) as Map));
        } catch (_) {}
      }
      for (final c in gone.conversations) {
        await _refreshPreview(c);
        _changed(c);
      }
    } catch (e) {
      debugPrint('Expiry sweep failed: $e');
    }
  }

  /// Sends an action without the local checks, as a modified client could.
  /// For tests of the receiving side's checks only.
  @visibleForTesting
  Future<void> debugSendRawAction(String contactId, String kind, String target,
          {String? emoji, String? body}) =>
      _sendAction(contactId, PayloadKind.fromWire(kind), target, emoji: emoji, body: body);

  Future<void> _sendAction(String contactId, PayloadKind kind, String target,
      {String? emoji, String? body}) async {
    final me = _requireUserId();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (GroupState.isGroup(contactId)) {
      await _sendToGroup(
          contactId,
          (to, gid) => WirePayload.action(
              kind: kind, from: me, to: to, timestampMs: now, target: target, emoji: emoji, body: body, groupId: gid));
    } else {
      try {
        await _deliver(
            contactId,
            WirePayload.action(
                kind: kind, from: me, to: contactId, timestampMs: now, target: target, emoji: emoji, body: body));
      } catch (e) {
        debugPrint('${kind.wire} to $contactId failed: $e');
      }
    }
    unawaited(_syncToOwnDevices(WirePayload.action(
        kind: kind,
        from: me,
        to: me,
        timestampMs: now,
        target: target,
        conversation: contactId,
        emoji: emoji,
        body: body)));
  }

  /// Applies a reaction / edit / deletion received from [actor] (a contact,
  /// or us on another device) in [conversation].
  Future<void> _applyAction(String conversation, String actor, WirePayload p) async {
    final row = await _storage.getMessage(p.target!);
    if (row == null || row['conversation_id'] != conversation) return;
    final m = Message.fromMap(row);
    if (m.isSystem || m.deleted) return;
    switch (p.kind) {
      case PayloadKind.react:
        await _storage.setReaction(m.id, actor, p.emoji!, p.timestampMs);
        break;
      case PayloadKind.edit:
      case PayloadKind.delete:
        // Only the author, and only within the window (+ a little skew).
        final authored = actor == _myUserId ? m.isFromMe : m.senderId == actor && !m.isFromMe;
        final age = DateTime.fromMillisecondsSinceEpoch(
                m.isFromMe ? p.timestampMs : arrivalTime(p.timestampMs))
            .difference(m.timestamp);
        if (!authored || age > editWindow + const Duration(minutes: 5)) return;
        if (p.kind == PayloadKind.edit) {
          await _storage.editMessage(m.id, p.body!, p.timestampMs);
        } else {
          await _storage.tombstoneMessage(m.id);
        }
        await _refreshPreview(conversation);
        break;
      default:
        return;
    }
    _changed(conversation);
  }

  Future<void> _refreshPreview(String conversation) =>
      _storage.refreshConversationPreview(conversation, (row) {
        final m = Message.fromMap(row);
        return m.deleted ? 'This message was deleted' : previewText(m.content, m.attachment);
      });

  /// Encrypts and uploads a file, then sends it to [contactId] with an
  /// optional [caption].
  Future<Message> sendAttachment(
    String contactId, {
    required Uint8List bytes,
    required String name,
    String? mime,
    String caption = '',
    Map<String, dynamic> extra = const {},
  }) async {
    final meta = await attachments.upload(bytes, name: name, mime: mime);
    return sendMessage(contactId, caption, attachment: {...meta, ...extra});
  }

  /// Sends a recorded voice note (an encrypted audio attachment).
  Future<Message> sendVoiceNote(String contactId, VoiceClip clip) => sendAttachment(contactId,
      bytes: clip.bytes, name: VoiceNote.fileName, mime: VoiceNote.mime, extra: VoiceNote.meta(clip));

  /// One-line preview for the conversation list.
  static String previewText(String text, Map<String, dynamic>? attachment) {
    if (attachment == null) return text;
    if (VoiceNote.isVoice(attachment)) {
      return '🎤 Voice message ${VoiceNote.clock(VoiceNote.durationOf(attachment))}';
    }
    final isImage = (attachment['mime'] as String? ?? '').startsWith('image/');
    // The name comes from the sender: strip bidi/control characters and paths.
    final name = attachment['name'];
    final label = isImage
        ? '📷 Photo'
        : '📎 ${name == null ? 'File' : AttachmentService.safeFileName(name)}';
    return text.isEmpty ? label : '$label · $text';
  }

  /// Attachment metadata as sent to other devices (local-only fields
  /// stripped).
  static Map<String, dynamic> _wireAttachment(Map<String, dynamic> a) =>
      Map.of(a)..removeWhere((k, _) => k.startsWith('local_'));

  /// Retries outgoing messages that previously failed to leave the device.
  Future<void> resendUnsent() async {
    if (!_started || _resending) return;
    _resending = true;
    try {
      await _resendGroupStates();
      final rows = await _storage.getUnsentMessages();
      for (final row in rows) {
        final m = Message.fromMap(row);
        await _transmitMessage(m.conversationId, m.id, m.content,
            m.timestamp.millisecondsSinceEpoch, m.attachment, m.replyTo, _remaining(m));
        _changed(m.conversationId);
      }
    } catch (e) {
      debugPrint('resendUnsent failed: $e');
    } finally {
      _resending = false;
    }
  }

  /// Sends a typing indicator.  P2P only — never goes through the server.
  Future<void> sendTyping(String contactId, bool isTyping) async {
    final me = _myUserId;
    final sessions = _sessions;
    if (!_started || me == null || sessions == null || GroupState.isGroup(contactId)) return;
    try {
      final devices = (await sessions.devices(contactId))
          .where((d) => _p2p.isConnected(d.address))
          .toList();
      if (devices.isEmpty) return;
      final payload = WirePayload.typing(
        from: me,
        to: contactId,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        isTyping: isTyping,
      );
      final sealed =
          await sessions.seal(contactId, devices, payload, envelopeId: _uuid.v4());
      for (final d in devices) {
        final env = sealed[d.deviceId];
        if (env != null) await _p2p.sendMessage(d.address, env.encode());
      }
    } catch (_) {}
  }

  /// Clears the unread badge and sends read receipts for [contactId] (and
  /// tells our other devices).
  Future<void> markConversationRead(String contactId) async {
    await _storage.clearUnreadCount(contactId);
    final ids = await _storage.getUnreadIncomingIds(contactId);
    if (ids.isNotEmpty) {
      await _storage.markIncomingRead(ids);
      final status = sendReadReceipts ? ReceiptStatus.read : ReceiptStatus.delivered;
      final group = _groups[contactId];
      for (final id in ids) {
        if (group == null) {
          _queueReceipt(contactId, id, status);
        } else {
          final sender = (await _storage.getMessage(id))?['sender_id'] as String?;
          if (sender != null) _queueReceipt(sender, id, status, groupId: group.id);
        }
      }
      final me = _myUserId;
      if (me != null) {
        unawaited(_syncToOwnDevices(WirePayload.readSync(
          me: me,
          conversation: contactId,
          ids: ids,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
        )));
      }
    }
    _changed(contactId);
  }

  Future<String> _transmitMessage(String contactId, String id, String text,
      int timestampMs, Map<String, dynamic>? attachment,
      [Map<String, dynamic>? reply, int? expireSeconds]) async {
    final me = _requireUserId();
    var delivered = false;
    try {
      delivered = GroupState.isGroup(contactId)
          ? await _transmitToGroup(
              contactId,
              (to, gid) => WirePayload.message(
                    messageId: id,
                    from: me,
                    to: to,
                    timestampMs: timestampMs,
                    body: text,
                    attachment: attachment == null ? null : _wireAttachment(attachment),
                    reply: reply,
                    expireSeconds: expireSeconds,
                    groupId: gid,
                  ),
              id)
          : await _deliver(
        contactId,
        WirePayload.message(
          messageId: id,
          from: me,
          to: contactId,
          timestampMs: timestampMs,
          body: text,
          attachment: attachment == null ? null : _wireAttachment(attachment),
          reply: reply,
          expireSeconds: expireSeconds,
        ),
        envelopeId: id,
      );
    } catch (e) {
      debugPrint('Send to $contactId failed: $e');
    }

    // A receipt may already have upgraded the status over a fast P2P link.
    final current = (await _storage.getMessage(id))?['status'] as String?;
    final next = delivered ? 'sent' : 'failed';
    if (current == 'sending' || current == 'failed') {
      await _storage.updateMessageStatus(id, next);
      return next;
    }
    return current ?? next;
  }

  Future<void> _syncToOwnDevices(WirePayload payload) async {
    final me = _myUserId;
    if (me == null) return;
    try {
      await _deliver(me, payload);
    } catch (e) {
      debugPrint('Sync to own devices failed: $e');
    }
  }

  /// Seals [payload] for every device of [userId] and sends each envelope
  /// P2P when that device has an open channel, otherwise via its relay
  /// queue.  Returns whether every device was reached (`false` if [userId]
  /// has no devices at all). With [onlyDevices], only those of [userId]'s
  /// devices get it.
  Future<bool> _deliver(
    String userId,
    WirePayload payload, {
    String? envelopeId,
    Set<String>? onlyDevices,
    bool relayOnly = false,
  }) async {
    final sessions = _sessions;
    if (sessions == null) throw StateError('ChatService.start() has not been called');
    final envId = envelopeId ?? _uuid.v4();
    for (var attempt = 0; attempt < 3; attempt++) {
      final devices = await sessions.devices(userId, refresh: attempt > 0);
      if (devices.isEmpty) {
        // Nobody to sync to is fine; a contact without devices can't be reached.
        return userId == _myUserId;
      }
      if (userId != _myUserId && !await _keysTrusted(userId, devices)) {
        debugPrint('Not sending to $userId: keys changed since verification');
        return false;
      }
      final targets =
          onlyDevices == null ? devices : devices.where((d) => onlyDevices.contains(d.deviceId)).toList();
      if (targets.isEmpty) return false;
      final sealed =
          await sessions.seal(userId, targets, payload, envelopeId: envId);
      final viaRelay = <String, String>{};
      for (final d in targets) {
        final env = sealed[d.deviceId];
        if (env == null) continue; // no session (device vanished); 409 sorts it out
        if (!relayOnly && await _p2p.sendMessage(d.address, env.encode())) continue;
        viaRelay[d.deviceId] = env.encodeJson();
      }
      try {
        if (viaRelay.isNotEmpty || sealed.length < targets.length) {
          await _directory.queueRelayMessages(userId,
              knownDevices: devices.map((d) => d.deviceId).toList(),
              envelopes: viaRelay);
        }
        return sealed.length == targets.length;
      } on DevicesChangedException {
        continue; // refresh the device list and seal again
      }
    }
    return false;
  }

  /// False when [userId] was verified and [devices] are not the keys that
  /// were verified: nothing is encrypted to keys the user hasn't accepted.
  Future<bool> _keysTrusted(String userId, List<DeviceKeys> devices) async {
    final pinned = await _storage.kvGet('verified:$userId');
    return pinned == null || pinned == keySetDigest(devices);
  }

  // Receipts

  void _queueReceipt(String contactId, String messageId, ReceiptStatus status, {String? groupId}) {
    final key = groupId == null ? contactId : '$contactId|$groupId';
    _pendingReceipts
        .putIfAbsent(key, () => {})
        .putIfAbsent(status, () => {})
        .add(messageId);
    _receiptTimers[key]?.cancel();
    _receiptTimers[key] = Timer(_receiptDebounce, () => _flushReceipts(key));
  }

  Future<void> _flushReceipts(String key) async {
    _receiptTimers.remove(key);
    final byStatus = _pendingReceipts.remove(key);
    final me = _myUserId;
    if (byStatus == null || me == null || !_started) return;
    final [contactId, ...rest] = key.split('|');
    final groupId = rest.firstOrNull;

    for (final entry in byStatus.entries) {
      try {
        await _deliver(
          contactId,
          WirePayload.receipt(
            from: me,
            to: contactId,
            timestampMs: DateTime.now().millisecondsSinceEpoch,
            ids: entry.value.toList(),
            status: entry.key,
            groupId: groupId,
          ),
        );
      } catch (e) {
        debugPrint('Receipt to $contactId failed: $e');
      }
    }
  }

  static const _statusRank = {
    'sending': 0,
    'failed': 0,
    'sent': 1,
    'delivered': 2,
    'read': 3,
  };

  Future<void> _applyReceipt(String contactId, WirePayload payload, String fromDevice) async {
    final newStatus = payload.receiptStatus!.name;
    for (final id in payload.receiptIds) {
      final profileVersion = ProfileService.ackedVersion(id);
      if (profileVersion != null) {
        await profiles.confirm(contactId, profileVersion, fromDevice);
        continue;
      }
      final row = await _storage.getMessage(id);
      if (row == null ||
          row['is_from_me'] != 1 ||
          row['conversation_id'] != contactId) {
        continue;
      }
      final current = row['status'] as String;
      if ((_statusRank[newStatus] ?? 0) > (_statusRank[current] ?? 0)) {
        await _storage.updateMessageStatus(id, newStatus);
      }
    }
    _changed(contactId);
  }

  // Receiving

  Future<void> _handleIncomingBytes(String address, Uint8List raw) async {
    try {
      final envelope = WireEnvelope.fromBytes(raw);
      if (envelope.senderAddress != address) return; // not who we're talking to
      await _openAndHandle(envelope);
    } catch (e) {
      debugPrint('Dropped P2P payload from $address: $e');
    }
  }

  /// Decrypts and dispatches one envelope.  Network errors propagate so the
  /// relay drain can keep the row for a later retry.
  Future<void> _openAndHandle(WireEnvelope envelope) async {
    final sessions = _sessions;
    final me = _myUserId;
    if (sessions == null || me == null) return;
    final seenKey = '${envelope.senderAddress}/${envelope.id}';
    if (await _storage.wasEnvelopeSeen(seenKey)) return; // redelivery

    WirePayload payload;
    try {
      payload = await sessions.open(envelope);
    } on UndecryptableException catch (e) {
      debugPrint('Undecryptable from ${envelope.senderAddress}: ${e.reason}');
      await _storage.markEnvelopeSeen(seenKey);
      // Start afresh with that device: our next message is a new X3DH.
      await sessions.resetSession(envelope.senderAddress);
      if (envelope.senderId != me) await _noteUndecryptable(envelope.senderId);
      return;
    }

    if (envelope.senderId == me) {
      if (payload.kind == PayloadKind.sync) {
        await _applySync(payload);
      } else if (payload.kind == PayloadKind.profile) {
        await profiles.receive(me, payload.profile!);
      } else if (payload.kind == PayloadKind.history) {
        await _importHistoryFrom(payload.attachment!);
      } else if (payload.kind == PayloadKind.group) {
        await _receiveGroupState(me, payload);
      } else if (payload.kind == PayloadKind.call) {
        _emitCallSignal(envelope, payload);
      } else if (payload.kind == PayloadKind.timer && payload.conversation != null) {
        await _applyTimer(payload.conversation!, me, payload.expireSeconds!);
      } else if (payload.conversation != null &&
          (payload.kind == PayloadKind.react ||
              payload.kind == PayloadKind.edit ||
              payload.kind == PayloadKind.delete)) {
        await _applyAction(payload.conversation!, me, payload);
      }
    } else if (payload.groupId != null && payload.kind != PayloadKind.group) {
      _heardFrom(envelope.senderId);
      await _receiveForGroup(envelope.senderId, payload);
    } else {
      final contactId = envelope.senderId;
      _heardFrom(contactId);
      switch (payload.kind) {
        case PayloadKind.message:
          await _storeIncomingMessage(contactId, payload);
          break;
        case PayloadKind.receipt:
          await _applyReceipt(contactId, payload, envelope.senderDevice);
          break;
        case PayloadKind.typing:
          if (!_typingController.isClosed) {
            _typingController.add(TypingEvent(contactId, payload.isTyping));
          }
          break;
        case PayloadKind.react:
        case PayloadKind.edit:
        case PayloadKind.delete:
          await _applyAction(contactId, contactId, payload);
          break;
        case PayloadKind.timer:
          await _applyTimer(contactId, contactId, payload.expireSeconds!);
          break;
        case PayloadKind.profile:
          await profiles.receive(contactId, payload.profile!);
          unawaited(_ackProfile(contactId, envelope.senderDevice, payload.profile!));
          break;
        case PayloadKind.history:
          break; // only our own devices may send history
        case PayloadKind.group:
          await _receiveGroupState(contactId, payload);
          break;
        case PayloadKind.call:
          _emitCallSignal(envelope, payload);
          break;
        case PayloadKind.sync:
          break; // only our own devices send these
      }
    }
    await _storage.markEnvelopeSeen(seenKey);
  }

  void _emitCallSignal(WireEnvelope envelope, WirePayload payload) {
    if (_callSignals.isClosed) return;
    _callSignals.add(CallSignal(
      from: envelope.senderId,
      fromDevice: envelope.senderDevice,
      sentAt: DateTime.fromMillisecondsSinceEpoch(payload.timestampMs),
      data: payload.call!,
    ));
  }

  /// A contact's timestamp, kept within what delivery allows: no more than
  /// the relay lifetime in the past, a few minutes in the future. The edit
  /// window is measured with these (audit run 1, U4-3).
  static int arrivalTime(int sentMs, {DateTime? now}) {
    final n = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return sentMs.clamp(n - const Duration(hours: 25).inMilliseconds,
        n + const Duration(minutes: 5).inMilliseconds);
  }

  /// Stores a message from [contactId], in their 1:1 chat or in the group
  /// [conversation].
  Future<void> _storeIncomingMessage(String contactId, WirePayload payload, {String? conversation}) async {
    final conv = conversation ?? contactId;
    final id = payload.messageId!;
    final sentAt = arrivalTime(payload.timestampMs);
    final existing = await _storage.getMessage(id);
    if (existing != null && existing['conversation_id'] != conv) return; // an id reused elsewhere
    final isActive = _activeConversationId == conv;

    if (existing == null) {
      final status = isActive ? 'read' : 'received';
      await _storage.insertMessage(
        id: id,
        conversationId: conv,
        senderId: contactId,
        content: payload.body!,
        timestamp: sentAt,
        status: status,
        isFromMe: false,
        attachment:
            payload.attachment == null ? null : jsonEncode(payload.attachment),
        replyTo: payload.reply == null ? null : jsonEncode(_replyRef(payload.reply!)),
        expiresAt: _expiryFrom(payload.expireSeconds),
      );
      final preview = previewText(payload.body!, payload.attachment);
      await _storage.updateConversation(
        id: conv,
        contactUserId: conv,
        lastMessage: conversation == null ? preview : '${await _noticeName(contactId)}: $preview',
        lastMessageTime: sentAt,
      );
      if (!isActive) await _storage.incrementUnreadCount(conv);

      if (!_onMessageReceivedController.isClosed) {
        _onMessageReceivedController.add(Message(
          id: id,
          conversationId: conv,
          senderId: contactId,
          content: payload.body!,
          timestamp: DateTime.fromMillisecondsSinceEpoch(sentAt),
          status: status,
          isFromMe: false,
          attachment: payload.attachment,
        ));
      }
      _changed(conv);
    }

    final alreadyRead = existing?['status'] == 'read' || isActive;
    _queueReceipt(
      contactId,
      id,
      alreadyRead && sendReadReceipts
          ? ReceiptStatus.read
          : ReceiptStatus.delivered,
      groupId: payload.groupId,
    );
  }

  /// A message we sent, or messages we read, on another of our devices.
  Future<void> _applySync(WirePayload payload) async {
    final contactId = payload.conversation!;
    final me = _requireUserId();
    if (payload.messageId != null && payload.body != null) {
      if (await _storage.getMessage(payload.messageId!) == null) {
        await _storage.insertMessage(
          id: payload.messageId!,
          conversationId: contactId,
          senderId: me,
          content: payload.body!,
          timestamp: payload.timestampMs,
          status: 'sent',
          isFromMe: true,
          attachment: payload.attachment == null
              ? null
              : jsonEncode(payload.attachment),
          replyTo: payload.reply == null ? null : jsonEncode(_replyRef(payload.reply!)),
          expiresAt: _expiryFrom(payload.expireSeconds),
        );
        await _storage.updateConversation(
          id: contactId,
          contactUserId: contactId,
          lastMessage: previewText(payload.body!, payload.attachment),
          lastMessageTime: payload.timestampMs,
        );
      }
    }
    if (payload.readIds.isNotEmpty) {
      await _storage.markIncomingRead(payload.readIds);
      // Reading a chat reads everything up to the newest message read.
      var newest = 0;
      for (final id in payload.readIds) {
        final row = await _storage.getMessage(id);
        final t = row?['timestamp'] as int? ?? 0;
        if (t > newest) newest = t;
      }
      if (newest > 0) await _storage.markIncomingReadUpTo(contactId, newest);
      final unread = await _storage.getUnreadIncomingIds(contactId);
      await _storage.updateConversation(
          id: contactId, contactUserId: contactId, unreadCount: unread.length);
    }
    _changed(contactId);
  }

  // Relay queue

  /// Downloads and processes every relay-queue envelope waiting for us.
  Future<void> drainRelayQueue() async {
    if (!_started) return;
    if (_draining) {
      _drainAgain = true;
      return;
    }
    _draining = true;
    try {
      do {
        _drainAgain = false;
        final rows = await _directory.fetchRelayMessages();
        if (rows.isEmpty) break;
        await _enqueueRelayRows(rows);
        // A full page means there may be more behind it.
        if (rows.length >= 200) _drainAgain = true;
      } while (_drainAgain && _started);
    } catch (e) {
      debugPrint('Relay drain failed: $e');
    } finally {
      _draining = false;
    }
  }

  /// An envelope pushed over the socket while we are connected.
  void _onRelayPush(Map<String, dynamic> row) {
    if (!_started) return;
    unawaited(_enqueueRelayRows([row]));
  }

  /// Serializes relay processing so a push and a drain never interleave.
  Future<void> _enqueueRelayRows(List<Map<String, dynamic>> rows) {
    final next = _relayChain.then((_) => _processRelayRows(rows));
    _relayChain = next.catchError((Object e) {
      debugPrint('Relay processing failed: $e');
    });
    return _relayChain;
  }

  Future<void> _processRelayRows(List<Map<String, dynamic>> rows) async {
    if (!_started) return;
    final done = <String>[];

    for (final row in rows) {
      final relayId = row['id'] as String?;
      final senderId = row['sender_id'] as String?;
      final senderDevice = row['sender_device'] as String?;
      final raw = row['envelope'] as String?;
      if (relayId == null || senderId == null || raw == null) continue;
      try {
        final envelope = WireEnvelope.decodeJson(raw);
        if (envelope.senderId == senderId &&
            (senderDevice == null || envelope.senderDevice == senderDevice)) {
          await _openAndHandle(envelope);
        }
      } on FormatException {
        // Not a valid v3 envelope: drop it.
      } catch (e) {
        // Network or storage error: keep it on the server for the next drain.
        debugPrint('Relay envelope $relayId kept for retry: $e');
        continue;
      }
      done.add(relayId);
    }

    // Only acknowledge what is safely stored on this device.
    if (done.isNotEmpty) {
      try {
        await _directory.ackRelayMessages(done);
      } catch (e) {
        // Redelivered next time; envelope ids make that harmless.
        debugPrint('Relay ack failed: $e');
      }
    }
  }

  // P2P signaling (one WebRTC connection per remote device)

  /// Starts WebRTC handshakes with every device of [contactId] that has no
  /// open or pending link.  Messages keep flowing via the relay meanwhile;
  /// devices that are offline answer `signal_error` and are skipped.
  Future<void> connect(String contactId) async {
    final sessions = _sessions;
    if (!_started || sessions == null || !_directory.isRealtimeConnected) return;
    if (GroupState.isGroup(contactId)) return; // group messages use the relay
    List<DeviceKeys> devices;
    try {
      devices = await sessions.devices(contactId);
    } catch (e) {
      debugPrint('P2P connect: no device list for $contactId: $e');
      return;
    }
    for (final d in devices) {
      unawaited(_connectDevice(contactId, d.deviceId));
    }
  }

  Future<void> _connectDevice(String userId, String deviceId) async {
    final address = '$userId:$deviceId';
    if (!_started ||
        _p2p.isConnected(address) ||
        _negotiations.containsKey(address)) {
      return;
    }

    final neg = _Negotiation(userId, deviceId,
        isCaller: true, sessionId: _uuid.v4());
    _negotiations[address] = neg;
    _armTimeout(neg);

    try {
      final offer = await _p2p.createOffer(address);
      if (!identical(_negotiations[address], neg)) {
        return; // superseded (e.g. we yielded to their simultaneous offer)
      }
      neg.peerReady = true;
      if (!_directory.sendSignal(
          to: userId,
          toDevice: deviceId,
          sessionId: neg.sessionId,
          kind: 'offer',
          sdp: offer)) {
        throw StateError('signaling socket is down');
      }
      neg.descriptionSent = true;
      _flushLocalIce(neg);
    } catch (e) {
      debugPrint('P2P connect to $address failed: $e');
      await _abandon(neg);
    }
  }

  void _onSignal(SignalEvent event) {
    if (!_started) return;
    final address = '${event.from}:${event.fromDevice}';
    switch (event.kind) {
      case 'offer':
        unawaited(_onIncomingOffer(event));
        break;
      case 'answer':
        unawaited(_onAnswer(event));
        break;
      case 'ice':
        final neg = _negotiations[address];
        final candidate = event.candidate;
        if (neg == null ||
            neg.sessionId != event.sessionId ||
            candidate == null) {
          return; // for a handshake we abandoned or yielded
        }
        if (neg.peerReady) {
          unawaited(_applyRemoteIce(address, candidate));
        } else {
          neg.pendingRemoteIce.add(candidate);
        }
        break;
      case 'bye':
        final neg = _negotiations[address];
        if (neg != null && neg.sessionId == event.sessionId) {
          unawaited(_abandon(neg, notifyPeer: false));
        }
        break;
    }
  }

  /// The server couldn't forward our frame: that device is offline (or the
  /// user is no longer a contact).  Stop waiting; the relay carries messages.
  void _onSignalError(SignalError error) {
    final neg = _negotiations['${error.to}:${error.toDevice}'];
    if (neg != null && neg.sessionId == error.sessionId) {
      unawaited(_abandon(neg, notifyPeer: false));
    }
  }

  Future<void> _onIncomingOffer(SignalEvent event) async {
    final sessionId = event.sessionId;
    final address = '${event.from}:${event.fromDevice}';
    final offer = event.sdp;
    final me = _sessions?.myAddress;
    if (offer == null || me == null) return;
    if (!_handledOfferSessions.add(sessionId)) return;
    if (_handledOfferSessions.length > 500) {
      _handledOfferSessions.remove(_handledOfferSessions.first);
    }

    final existing = _negotiations[address];
    if (existing != null && existing.isCaller) {
      // Glare: both sides dialled at once.  The lower address yields and
      // answers; the higher one keeps its own offer and ignores this one.
      if (me.compareTo(address) > 0) return;
      await _abandon(existing, notifyPeer: false);
    } else if (existing != null) {
      await _abandon(existing, notifyPeer: false);
    }

    // Registered synchronously so their ICE candidates, which follow the
    // offer immediately, are buffered instead of dropped.
    final neg = _Negotiation(event.from, event.fromDevice,
        isCaller: false, sessionId: sessionId);
    _negotiations[address] = neg;
    _armTimeout(neg);

    try {
      final answer = await _p2p.handleOffer(address, offer);
      if (!identical(_negotiations[address], neg)) return;
      neg.peerReady = true;
      await _flushRemoteIce(neg);
      if (!_directory.sendSignal(
          to: event.from,
          toDevice: event.fromDevice,
          sessionId: sessionId,
          kind: 'answer',
          sdp: answer)) {
        throw StateError('signaling socket is down');
      }
      neg.descriptionSent = true;
      _flushLocalIce(neg);
    } catch (e) {
      debugPrint('Answering offer from $address failed: $e');
      await _abandon(neg);
    }
  }

  Future<void> _onAnswer(SignalEvent event) async {
    final neg = _negotiations['${event.from}:${event.fromDevice}'];
    final answer = event.sdp;
    if (neg == null ||
        !neg.isCaller ||
        answer == null ||
        neg.sessionId != event.sessionId ||
        neg.answerApplied) {
      return;
    }
    neg.answerApplied = true;

    try {
      await _p2p.handleAnswer(neg.address, answer);
    } catch (e) {
      debugPrint('Applying answer from ${neg.address} failed: $e');
      await _abandon(neg);
    }
  }

  void _onLocalIceCandidate(IceCandidateEvent event) {
    final neg = _negotiations[event.contactId];
    if (neg == null) return;
    final candidate = {
      'candidate': event.candidate.candidate,
      'sdpMid': event.candidate.sdpMid,
      'sdpMLineIndex': event.candidate.sdpMLineIndex,
    };
    // Candidates must not overtake our offer / answer.
    if (!neg.descriptionSent) {
      neg.pendingLocalIce.add(candidate);
    } else {
      _sendIce(neg, candidate);
    }
  }

  void _sendIce(_Negotiation neg, Map<String, dynamic> candidate) {
    _directory.sendSignal(
        to: neg.userId,
        toDevice: neg.deviceId,
        sessionId: neg.sessionId,
        kind: 'ice',
        candidate: candidate);
  }

  void _flushLocalIce(_Negotiation neg) {
    final pending = List.of(neg.pendingLocalIce);
    neg.pendingLocalIce.clear();
    for (final c in pending) {
      _sendIce(neg, c);
    }
  }

  Future<void> _flushRemoteIce(_Negotiation neg) async {
    final pending = List.of(neg.pendingRemoteIce);
    neg.pendingRemoteIce.clear();
    for (final c in pending) {
      await _applyRemoteIce(neg.address, c);
    }
  }

  Future<void> _applyRemoteIce(
      String address, Map<String, dynamic> candidate) async {
    try {
      await _p2p.addIceCandidate(address, candidate);
    } catch (_) {
      // Late or duplicate candidate: harmless.
    }
  }

  void _onConnectionStateChange(ConnectionStateEvent event) {
    final address = event.contactId;
    final neg = _negotiations[address];

    if (event.state == P2PConnectionState.connected) {
      _directLinks.add(address);
      if (neg != null) _finish(neg);
      // A direct link is up: push anything that was stuck.
      unawaited(resendUnsent());
      return;
    }
    if (event.state == P2PConnectionState.failed && neg != null) {
      unawaited(_abandon(neg));
    }
    if ((event.state == P2PConnectionState.disconnected ||
            event.state == P2PConnectionState.failed) &&
        _directLinks.remove(address)) {
      // An established channel died; anything written to it in its last
      // moments may never have arrived.  Re-send it (ids deduplicate).
      unawaited(_resendUnconfirmed(_splitAddress(address).userId));
    }
  }

  /// Re-sends recent outgoing messages to [contactId] that were handed to a
  /// data channel but never acknowledged.
  Future<void> _resendUnconfirmed(String contactId) async {
    if (!_started) return;
    try {
      final since = DateTime.now()
          .subtract(const Duration(minutes: 2))
          .millisecondsSinceEpoch;
      final rows = await _storage.getSentUnconfirmed(contactId, since);
      for (final row in rows) {
        final m = Message.fromMap(row);
        await _transmitMessage(contactId, m.id, m.content,
            m.timestamp.millisecondsSinceEpoch, m.attachment, m.replyTo, _remaining(m));
      }
    } catch (e) {
      debugPrint('Re-sending unconfirmed messages failed: $e');
    }
  }

  void _armTimeout(_Negotiation neg) {
    neg.timeout = Timer(_negotiationTimeout, () {
      if (!_p2p.isConnected(neg.address)) unawaited(_abandon(neg));
    });
  }

  /// Handshake succeeded.  Nothing was stored server-side, so nothing to
  /// clean up.
  void _finish(_Negotiation neg) {
    neg.timeout?.cancel();
    if (identical(_negotiations[neg.address], neg)) {
      _negotiations.remove(neg.address);
    }
  }

  /// Handshake failed or was superseded: tear it down.
  Future<void> _abandon(_Negotiation neg, {bool notifyPeer = true}) async {
    neg.timeout?.cancel();
    if (identical(_negotiations[neg.address], neg)) {
      _negotiations.remove(neg.address);
      if (!_p2p.isConnected(neg.address)) {
        await _p2p.closeConnection(neg.address);
      }
    }
    if (notifyPeer && neg.descriptionSent) {
      _directory.sendSignal(
          to: neg.userId,
          toDevice: neg.deviceId,
          sessionId: neg.sessionId,
          kind: 'bye');
    }
  }

  // Notices

  Future<void> _noteDevicesChanged(
      String contactId, DeviceListChange change) async {
    if (!_started || await _storage.getConversation(contactId) == null) return;
    final cached = await _storage.getCachedContact(contactId);
    final name = cached?['display_name'] as String? ?? 'This contact';
    final what = change.added.isNotEmpty && change.removed.isEmpty
        ? '$name signed in on a new device.'
        : change.removed.isNotEmpty && change.added.isEmpty && change.changed.isEmpty
            ? '$name removed a device.'
            : "$name's devices changed.";
    final paused = await verificationOf(contactId) == Verification.changed;
    await _storage.insertSystemMessage(
      contactId,
      paused
          ? '$what You had verified them, so sending is paused until you verify '
              'the new safety number or accept it.'
          : '$what Your safety number with them changed; verify it in contact info.',
      id: _uuid.v4(),
    );
    _changed(contactId);
  }

  Future<void> _noteUndecryptable(String contactId) async {
    await ensureConversation(contactId);
    await _storage.insertSystemMessage(
      contactId,
      "A message couldn't be decrypted, so a new secure session was started. "
      'Ask the sender to resend it if it was important.',
      id: _uuid.v4(),
    );
    _changed(contactId);
  }

  // Helpers

  String _requireUserId() {
    final uid = _myUserId;
    if (uid == null) throw StateError('ChatService.start() has not been called');
    return uid;
  }

  void _changed(String contactId) {
    if (!_conversationChangedController.isClosed) {
      _conversationChangedController.add(contactId);
    }
  }

  /// Tears down all listeners, streams, and connections.
  Future<void> dispose() async {
    await stop();
    await _conversationChangedController.close();
    await _onMessageReceivedController.close();
    await _typingController.close();
    await _devicesChangedController.close();
    await _callSignals.close();
  }
}

/// One decrypted call signal from [from]'s device [fromDevice].
class CallSignal {
  final String from;
  final String fromDevice;
  final DateTime sentAt;
  final Map<String, dynamic> data;

  const CallSignal({required this.from, required this.fromDevice, required this.sentAt, required this.data});
}

enum Verification {
  unverified,
  verified,

  /// Verified before, but their keys have changed since. Sending is paused.
  changed,
}

/// The safety number changed between showing it and marking it verified.
class SafetyNumberChangedException implements Exception {
  const SafetyNumberChangedException();

  @override
  String toString() => 'The safety number just changed. Compare the new number before verifying.';
}
