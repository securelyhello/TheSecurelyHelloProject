import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:securelyhello/core/chat/wire_protocol.dart';
import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/storage/local_storage.dart';

// =============================================================================
// Domain models
// =============================================================================

/// Local representation of a chat message.
class Message {
  final String id;

  /// For 1:1 chats this is the contact's user id.
  final String conversationId;
  final String senderId;

  /// Decrypted plaintext for display.
  final String content;

  final DateTime timestamp;

  /// Outgoing: `sending`, `sent`, `delivered`, `read`, `failed`.
  /// Incoming: `received` or `read`.
  final String status;

  final bool isFromMe;

  /// `text` for chat messages, `system` for local notices.
  final String kind;

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.content,
    required this.timestamp,
    required this.status,
    required this.isFromMe,
    this.kind = 'text',
  });

  bool get isSystem => kind == 'system';

  factory Message.fromMap(Map<String, dynamic> map) {
    return Message(
      id: map['id'] as String,
      conversationId: map['conversation_id'] as String,
      senderId: map['sender_id'] as String,
      content: map['content'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      status: map['status'] as String,
      isFromMe: (map['is_from_me'] as int) == 1,
      kind: map['kind'] as String? ?? 'text',
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

/// One in-flight WebRTC handshake with a contact.
class _Negotiation {
  final String contactId;
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

  _Negotiation(this.contactId,
      {required this.isCaller, required this.sessionId});
}

enum _OpenResult { handled, undecryptable }

// =============================================================================
// ChatService
// =============================================================================

/// Orchestrates end-to-end encrypted messaging.
///
/// Transport order for every outgoing payload:
/// 1. the WebRTC data channel, if one is open;
/// 2. otherwise the server's relay queue (ciphertext only, 24h expiry),
///    while a P2P connection is negotiated in the background.
///
/// All payloads are signed with the sender's Ed25519 key and encrypted to the
/// recipient's X25519 key before leaving the device (see [WireCodec]).
class ChatService {
  static const _negotiationTimeout = Duration(seconds: 30);
  static const _receiptDebounce = Duration(milliseconds: 300);

  final LocalStorage _storage;
  final P2PConnectionManager _p2p;
  final DirectoryService _directory;
  final _uuid = const Uuid();

  CryptoIdentity? _identity;
  String? _myUserId;
  bool _started = false;
  String? _activeConversationId;

  /// When `false`, incoming messages are only acknowledged as delivered.
  bool sendReadReceipts = true;

  final Map<String, _Negotiation> _negotiations = {};
  final Set<String> _handledOfferSessions = {};
  final Set<String> _onlineContacts = {};
  final Set<String> _directLinks = {};
  Future<void> _relayChain = Future.value();
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  // Batched outgoing receipts: contactId → status → ids.
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

  ChatService({
    required LocalStorage storage,
    required P2PConnectionManager p2p,
    required DirectoryService directory,
  })  : _storage = storage,
        _p2p = p2p,
        _directory = directory;

  /// Emits a contact id whenever that conversation's messages or metadata
  /// changed (new message, status update, system notice…).
  Stream<String> get onConversationChanged =>
      _conversationChangedController.stream;

  /// Emits each newly received chat message.
  Stream<Message> get onMessageReceived => _onMessageReceivedController.stream;

  /// Emits typing indicators from peers.
  Stream<TypingEvent> get onTyping => _typingController.stream;

  bool get isStarted => _started;
  String? get myUserId => _myUserId;
  CryptoIdentity? get identity => _identity;

  // ===========================================================================
  // Lifecycle
  // ===========================================================================

  /// Starts messaging for the signed-in user.  Idempotent per user.
  Future<void> start({
    required CryptoIdentity identity,
    required String myUserId,
  }) async {
    if (_started && _myUserId == myUserId) return;
    await stop();

    _identity = identity;
    _myUserId = myUserId;

    await _directory.startRealtime();

    _subscriptions
      ..add(_directory.signals.listen(_onSignal))
      ..add(_directory.signalErrors.listen(_onSignalError))
      ..add(_directory.relayPushes.listen(_onRelayPush))
      ..add(_directory.realtimeState.listen(_onRealtimeState))
      ..add(_directory.presenceEvents.listen(_onPresence))
      ..add(_directory.contactEvents.listen(_onContactEvent))
      ..add(_p2p.onIceCandidate.listen(_onLocalIceCandidate))
      ..add(_p2p.onConnectionStateChange.listen(_onConnectionStateChange))
      ..add(_p2p.onDataChannelMessage
          .listen((e) => _handleIncomingBytes(e.contactId, e.data)));

    _started = true;

    // Opens the socket; if we are offline it keeps retrying on its own and
    // `_onRealtimeState(true)` picks up from there.
    await _directory.startRealtime();
    await drainRelayQueue();
    unawaited(resendUnsent());
  }

  /// The socket is (back) up: collect what we missed, push what was stuck,
  /// and bring the open chat's direct link back.
  void _onRealtimeState(bool up) {
    if (!up) {
      _onlineContacts.clear();
      return;
    }
    if (!_started) return;
    unawaited(drainRelayQueue().then((_) => resendUnsent()));
    final active = _activeConversationId;
    if (active != null) unawaited(connect(active));
  }

  void _onPresence(PresenceEvent event) {
    if (event.online) {
      _onlineContacts.add(event.userId);
      // They just came online and we are looking at their chat: go direct.
      if (_activeConversationId == event.userId) {
        unawaited(connect(event.userId));
      }
    } else {
      _onlineContacts.remove(event.userId);
    }
  }

  void _onContactEvent(ContactEvent event) {
    final userId = event.userId;
    if (userId == null) return;
    if (event.type == 'keys_changed') {
      unawaited(_refreshPeerKeys(userId).catchError((Object _) => null));
    } else if (event.type == 'contact_removed') {
      final neg = _negotiations[userId];
      if (neg != null) unawaited(_abandon(neg, notifyPeer: false));
      unawaited(_p2p.closeConnection(userId));
    }
  }

  /// Stops everything for the current user (sign-out / account switch).
  Future<void> stop() async {
    _started = false;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();

    for (final neg in _negotiations.values) {
      neg.timeout?.cancel();
    }
    _negotiations.clear();
    _handledOfferSessions.clear();
    _onlineContacts.clear();
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
    _activeConversationId = null;
  }

  /// Tells the service which chat is on screen, so incoming messages there
  /// are marked read immediately.
  void setActiveConversation(String? contactId) {
    _activeConversationId = contactId;
  }

  // ===========================================================================
  // Queries
  // ===========================================================================

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
    return rows.map(Message.fromMap).toList();
  }

  /// Ensures a (possibly empty) conversation row exists for [contactId].
  Future<void> ensureConversation(String contactId) async {
    await _storage.updateConversation(id: contactId, contactUserId: contactId);
  }

  Future<void> clearConversation(String contactId) async {
    await _storage.clearConversation(contactId);
    _changed(contactId);
  }

  Future<void> deleteConversation(String contactId) async {
    await _storage.deleteConversation(contactId);
    _changed(contactId);
  }

  /// The 60-digit safety number shared with [contactId], or `null` if their
  /// keys are unknown.
  Future<String?> safetyNumberFor(String contactId) async {
    final identity = _identity;
    final me = _myUserId;
    if (identity == null || me == null) return null;
    final keys = await _peerKeys(contactId);
    if (keys == null) return null;
    return CryptoCore.safetyNumber(
      myUserId: me,
      mySigningKey: identity.publicSigningKeyBase64,
      myEncryptionKey: identity.publicEncryptionKeyBase64,
      theirUserId: contactId,
      theirSigningKey: keys.signingKey,
      theirEncryptionKey: keys.encryptionKey,
    );
  }

  // ===========================================================================
  // Sending
  // ===========================================================================

  /// Stores [plaintext] locally and delivers it to [contactId].
  Future<Message> sendMessage(String contactId, String plaintext) async {
    final me = _requireUserId();
    final id = _uuid.v4();
    final now = DateTime.now();

    await _storage.insertMessage(
      id: id,
      conversationId: contactId,
      senderId: me,
      content: plaintext,
      timestamp: now.millisecondsSinceEpoch,
      status: 'sending',
      isFromMe: true,
    );
    await _storage.updateConversation(
      id: contactId,
      contactUserId: contactId,
      lastMessage: plaintext,
      lastMessageTime: now.millisecondsSinceEpoch,
    );
    _changed(contactId);

    final status = await _transmitText(
        contactId, id, plaintext, now.millisecondsSinceEpoch);
    _changed(contactId);

    if (!_p2p.isConnected(contactId)) unawaited(connect(contactId));

    return Message(
      id: id,
      conversationId: contactId,
      senderId: me,
      content: plaintext,
      timestamp: now,
      status: status,
      isFromMe: true,
    );
  }

  /// Retries outgoing messages that previously failed to leave the device.
  Future<void> resendUnsent() async {
    if (!_started || _resending) return;
    _resending = true;
    try {
      final rows = await _storage.getUnsentMessages();
      for (final row in rows) {
        final contactId = row['conversation_id'] as String;
        await _transmitText(contactId, row['id'] as String,
            row['content'] as String, row['timestamp'] as int);
        _changed(contactId);
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
    if (!_started || me == null || !_p2p.isConnected(contactId)) return;
    try {
      await _deliver(
        contactId,
        WirePayload.typing(
          from: me,
          to: contactId,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          isTyping: isTyping,
        ),
        allowRelay: false,
      );
    } catch (_) {}
  }

  /// Clears the unread badge and sends read receipts for [contactId].
  Future<void> markConversationRead(String contactId) async {
    await _storage.clearUnreadCount(contactId);
    final ids = await _storage.getUnreadIncomingIds(contactId);
    if (ids.isNotEmpty) {
      await _storage.markIncomingRead(ids);
      for (final id in ids) {
        _queueReceipt(contactId, id,
            sendReadReceipts ? ReceiptStatus.read : ReceiptStatus.delivered);
      }
    }
    _changed(contactId);
  }

  Future<String> _transmitText(
      String contactId, String id, String text, int timestampMs) async {
    final me = _requireUserId();
    var delivered = false;
    try {
      delivered = await _deliver(
        contactId,
        WirePayload.message(
          messageId: id,
          from: me,
          to: contactId,
          timestampMs: timestampMs,
          body: text,
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

  /// Seals [payload] for [contactId] and sends it P2P, falling back to the
  /// relay when [allowRelay].  Returns whether it left the device.
  Future<bool> _deliver(
    String contactId,
    WirePayload payload, {
    String? envelopeId,
    bool allowRelay = true,
  }) async {
    final keys = await _peerKeys(contactId);
    if (keys == null) {
      throw StateError('No public keys known for $contactId');
    }
    final envelope = WireCodec.seal(
      envelopeId: envelopeId ?? _uuid.v4(),
      payload: payload,
      identity: _requireIdentity(),
      recipientEncryptionKey: keys.encryptionKey,
    );

    if (await _p2p.sendMessage(contactId, envelope.encode())) return true;
    if (!allowRelay) return false;

    await _directory.queueRelayMessage(contactId, envelope.encodeJson());
    return true;
  }

  // ===========================================================================
  // Receipts
  // ===========================================================================

  void _queueReceipt(String contactId, String messageId, ReceiptStatus status) {
    _pendingReceipts
        .putIfAbsent(contactId, () => {})
        .putIfAbsent(status, () => {})
        .add(messageId);
    _receiptTimers[contactId]?.cancel();
    _receiptTimers[contactId] =
        Timer(_receiptDebounce, () => _flushReceipts(contactId));
  }

  Future<void> _flushReceipts(String contactId) async {
    _receiptTimers.remove(contactId);
    final byStatus = _pendingReceipts.remove(contactId);
    final me = _myUserId;
    if (byStatus == null || me == null || !_started) return;

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

  Future<void> _applyReceipt(String contactId, WirePayload payload) async {
    final newStatus = payload.receiptStatus!.name;
    for (final id in payload.receiptIds) {
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

  // ===========================================================================
  // Receiving
  // ===========================================================================

  Future<void> _handleIncomingBytes(String contactId, Uint8List raw) async {
    try {
      final envelope = WireEnvelope.fromBytes(raw);
      final result = await _openAndHandle(contactId, envelope);
      if (result == _OpenResult.undecryptable) {
        await _noteUndecryptable(contactId);
      }
    } catch (e) {
      debugPrint('Dropped P2P payload from $contactId: $e');
    }
  }

  /// Decrypts and dispatches one envelope.  Network errors propagate so the
  /// relay drain can keep the row for a later retry.
  Future<_OpenResult> _openAndHandle(
      String contactId, WireEnvelope envelope) async {
    final payload = await _openWithKeyRefresh(contactId, envelope);
    if (payload == null) return _OpenResult.undecryptable;

    switch (payload.kind) {
      case PayloadKind.message:
        await _storeIncomingText(contactId, payload);
        break;
      case PayloadKind.receipt:
        await _applyReceipt(contactId, payload);
        break;
      case PayloadKind.typing:
        if (!_typingController.isClosed) {
          _typingController.add(TypingEvent(contactId, payload.isTyping));
        }
        break;
    }
    return _OpenResult.handled;
  }

  Future<WirePayload?> _openWithKeyRefresh(
      String contactId, WireEnvelope envelope) async {
    WirePayload? tryOpen(PeerKeys keys) {
      try {
        return WireCodec.open(
          envelope: envelope,
          identity: _requireIdentity(),
          sender: keys,
          expectedSender: contactId,
          myUserId: _requireUserId(),
        );
      } catch (_) {
        return null;
      }
    }

    final cached = await _peerKeys(contactId);
    final first = cached == null ? null : tryOpen(cached);
    if (first != null) return first;

    // The sender may have rotated keys (new device) — refetch once.
    final fresh = await _refreshPeerKeys(contactId);
    if (fresh == null ||
        (cached != null &&
            fresh.encryptionKey == cached.encryptionKey &&
            fresh.signingKey == cached.signingKey)) {
      return null;
    }
    return tryOpen(fresh);
  }

  Future<void> _storeIncomingText(String contactId, WirePayload payload) async {
    final id = payload.messageId!;
    final existing = await _storage.getMessage(id);
    final isActive = _activeConversationId == contactId;

    if (existing == null) {
      await _storage.insertMessage(
        id: id,
        conversationId: contactId,
        senderId: contactId,
        content: payload.body!,
        timestamp: payload.timestampMs,
        status: isActive ? 'read' : 'received',
        isFromMe: false,
      );
      await _storage.updateConversation(
        id: contactId,
        contactUserId: contactId,
        lastMessage: payload.body,
        lastMessageTime: payload.timestampMs,
      );
      if (!isActive) await _storage.incrementUnreadCount(contactId);

      if (!_onMessageReceivedController.isClosed) {
        _onMessageReceivedController.add(Message(
          id: id,
          conversationId: contactId,
          senderId: contactId,
          content: payload.body!,
          timestamp: DateTime.fromMillisecondsSinceEpoch(payload.timestampMs),
          status: isActive ? 'read' : 'received',
          isFromMe: false,
        ));
      }
      _changed(contactId);
    }

    final alreadyRead = existing?['status'] == 'read' || isActive;
    _queueReceipt(
      contactId,
      id,
      alreadyRead && sendReadReceipts
          ? ReceiptStatus.read
          : ReceiptStatus.delivered,
    );
  }

  // ===========================================================================
  // Relay queue
  // ===========================================================================

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
    final undecryptableFrom = <String>{};

    for (final row in rows) {
      final relayId = row['id'] as String?;
      final senderId = row['sender_id'] as String?;
      final raw = row['envelope'] as String?;
      if (relayId == null || senderId == null || raw == null) continue;
      try {
        final envelope = WireEnvelope.decodeJson(raw);
        final result = await _openAndHandle(senderId, envelope);
        if (result == _OpenResult.undecryptable) {
          undecryptableFrom.add(senderId);
        }
      } on FormatException {
        undecryptableFrom.add(senderId);
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
        // Redelivered next time; message ids make that harmless.
        debugPrint('Relay ack failed: $e');
      }
    }
    for (final senderId in undecryptableFrom) {
      await _noteUndecryptable(senderId);
    }
  }

  // ===========================================================================
  // P2P signaling
  // ===========================================================================

  /// Starts a WebRTC handshake with [contactId] unless one is already open or
  /// in progress.  Messages keep flowing via the relay meanwhile.
  Future<void> connect(String contactId) async {
    if (!_started ||
        !_directory.isRealtimeConnected ||
        _p2p.isConnected(contactId) ||
        _negotiations.containsKey(contactId)) {
      return;
    }

    final neg =
        _Negotiation(contactId, isCaller: true, sessionId: _uuid.v4());
    _negotiations[contactId] = neg;
    _armTimeout(neg);

    try {
      final offer = await _p2p.createOffer(contactId);
      if (!identical(_negotiations[contactId], neg)) {
        return; // superseded (e.g. we yielded to their simultaneous offer)
      }
      neg.peerReady = true;
      if (!_directory.sendSignal(
          to: contactId, sessionId: neg.sessionId, kind: 'offer', sdp: offer)) {
        throw StateError('signaling socket is down');
      }
      neg.descriptionSent = true;
      _flushLocalIce(neg);
    } catch (e) {
      debugPrint('P2P connect to $contactId failed: $e');
      await _abandon(neg);
    }
  }

  void _onSignal(SignalEvent event) {
    if (!_started) return;
    switch (event.kind) {
      case 'offer':
        unawaited(_onIncomingOffer(event));
        break;
      case 'answer':
        unawaited(_onAnswer(event));
        break;
      case 'ice':
        final neg = _negotiations[event.from];
        final candidate = event.candidate;
        if (neg == null ||
            neg.sessionId != event.sessionId ||
            candidate == null) {
          return; // for a handshake we abandoned or yielded
        }
        if (neg.peerReady) {
          unawaited(_applyRemoteIce(neg.contactId, candidate));
        } else {
          neg.pendingRemoteIce.add(candidate);
        }
        break;
      case 'bye':
        final neg = _negotiations[event.from];
        if (neg != null && neg.sessionId == event.sessionId) {
          unawaited(_abandon(neg, notifyPeer: false));
        }
        break;
    }
  }

  /// The server couldn't forward our frame: the contact is offline (or no
  /// longer a contact).  Stop waiting; the relay queue carries the messages.
  void _onSignalError(SignalError error) {
    final neg = _negotiations[error.to];
    if (neg != null && neg.sessionId == error.sessionId) {
      unawaited(_abandon(neg, notifyPeer: false));
    }
  }

  Future<void> _onIncomingOffer(SignalEvent event) async {
    final sessionId = event.sessionId;
    final callerId = event.from;
    final offer = event.sdp;
    final me = _myUserId;
    if (offer == null || me == null) return;
    if (!_handledOfferSessions.add(sessionId)) return;
    if (_handledOfferSessions.length > 500) {
      _handledOfferSessions.remove(_handledOfferSessions.first);
    }

    final existing = _negotiations[callerId];
    if (existing != null && existing.isCaller) {
      // Glare: both sides dialled at once.  The lower user id yields and
      // answers; the higher one keeps its own offer and ignores this one.
      if (me.compareTo(callerId) > 0) return;
      await _abandon(existing, notifyPeer: false);
    } else if (existing != null) {
      await _abandon(existing, notifyPeer: false);
    }

    // Registered synchronously so their ICE candidates, which follow the
    // offer immediately, are buffered instead of dropped.
    final neg = _Negotiation(callerId, isCaller: false, sessionId: sessionId);
    _negotiations[callerId] = neg;
    _armTimeout(neg);

    try {
      final answer = await _p2p.handleOffer(callerId, offer);
      if (!identical(_negotiations[callerId], neg)) return;
      neg.peerReady = true;
      await _flushRemoteIce(neg);
      if (!_directory.sendSignal(
          to: callerId, sessionId: sessionId, kind: 'answer', sdp: answer)) {
        throw StateError('signaling socket is down');
      }
      neg.descriptionSent = true;
      _flushLocalIce(neg);
    } catch (e) {
      debugPrint('Answering offer from $callerId failed: $e');
      await _abandon(neg);
    }
  }

  Future<void> _onAnswer(SignalEvent event) async {
    final neg = _negotiations[event.from];
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
      await _p2p.handleAnswer(neg.contactId, answer);
    } catch (e) {
      debugPrint('Applying answer from ${event.from} failed: $e');
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
      _directory.sendSignal(
          to: neg.contactId,
          sessionId: neg.sessionId,
          kind: 'ice',
          candidate: candidate);
    }
  }

  void _flushLocalIce(_Negotiation neg) {
    final pending = List.of(neg.pendingLocalIce);
    neg.pendingLocalIce.clear();
    for (final c in pending) {
      _directory.sendSignal(
          to: neg.contactId, sessionId: neg.sessionId, kind: 'ice', candidate: c);
    }
  }

  Future<void> _flushRemoteIce(_Negotiation neg) async {
    final pending = List.of(neg.pendingRemoteIce);
    neg.pendingRemoteIce.clear();
    for (final c in pending) {
      await _applyRemoteIce(neg.contactId, c);
    }
  }

  Future<void> _applyRemoteIce(
      String contactId, Map<String, dynamic> candidate) async {
    try {
      await _p2p.addIceCandidate(contactId, candidate);
    } catch (_) {
      // Late or duplicate candidate: harmless.
    }
  }

  void _onConnectionStateChange(ConnectionStateEvent event) {
    final neg = _negotiations[event.contactId];

    if (event.state == P2PConnectionState.connected) {
      _directLinks.add(event.contactId);
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
        _directLinks.remove(event.contactId)) {
      // An established channel died; anything written to it in its last
      // moments may never have arrived.  Re-send it (ids deduplicate).
      unawaited(_resendUnconfirmed(event.contactId));
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
        await _transmitText(contactId, row['id'] as String,
            row['content'] as String, row['timestamp'] as int);
      }
    } catch (e) {
      debugPrint('Re-sending unconfirmed messages failed: $e');
    }
  }

  void _armTimeout(_Negotiation neg) {
    neg.timeout = Timer(_negotiationTimeout, () {
      if (!_p2p.isConnected(neg.contactId)) unawaited(_abandon(neg));
    });
  }

  /// Handshake succeeded.  Nothing was stored server-side, so nothing to
  /// clean up.
  void _finish(_Negotiation neg) {
    neg.timeout?.cancel();
    if (identical(_negotiations[neg.contactId], neg)) {
      _negotiations.remove(neg.contactId);
    }
  }

  /// Handshake failed or was superseded: tear it down.
  Future<void> _abandon(_Negotiation neg, {bool notifyPeer = true}) async {
    neg.timeout?.cancel();
    if (identical(_negotiations[neg.contactId], neg)) {
      _negotiations.remove(neg.contactId);
      if (!_p2p.isConnected(neg.contactId)) {
        await _p2p.closeConnection(neg.contactId);
      }
    }
    if (notifyPeer && neg.descriptionSent) {
      _directory.sendSignal(
          to: neg.contactId, sessionId: neg.sessionId, kind: 'bye');
    }
  }

  // ===========================================================================
  // Keys
  // ===========================================================================

  /// Returns [contactId]'s public keys from the local cache, fetching them
  /// from the directory if needed.  Returns `null` if the user is unknown.
  Future<PeerKeys?> _peerKeys(String contactId) async {
    final cached = await _storage.getCachedContact(contactId);
    if (cached != null) {
      final keys = PeerKeys(
        signingKey: cached['public_signing_key'] as String? ?? '',
        encryptionKey: cached['public_encryption_key'] as String? ?? '',
      );
      if (keys.isComplete) return keys;
    }
    return _refreshPeerKeys(contactId);
  }

  Future<PeerKeys?> _refreshPeerKeys(String contactId) async {
    final user = await _directory.getUserById(contactId);
    if (user == null) return null;

    final keys = PeerKeys(
      signingKey: user['signing_public_key'] as String? ?? '',
      encryptionKey: user['encryption_public_key'] as String? ?? '',
    );
    final changed = await _storage.cacheContact(
      userId: contactId,
      username: user['username'] as String?,
      displayName: user['display_name'] as String?,
      publicSigningKey: keys.signingKey,
      publicEncryptionKey: keys.encryptionKey,
      isOnline: user['status'] == 'online',
    );
    if (changed) {
      await noteSafetyNumberChanged(
          contactId, user['display_name'] as String? ?? 'This contact');
    }
    return keys.isComplete ? keys : null;
  }

  /// Adds a local notice that [contactId]'s keys changed.
  Future<void> noteSafetyNumberChanged(
      String contactId, String displayName) async {
    if (await _storage.getConversation(contactId) == null) return;
    await _storage.insertSystemMessage(
      contactId,
      "$displayName's safety number changed. They may have reinstalled or "
      'signed in on a new device. Verify it in contact info.',
      id: _uuid.v4(),
    );
    _changed(contactId);
  }

  Future<void> _noteUndecryptable(String contactId) async {
    await ensureConversation(contactId);
    await _storage.insertSystemMessage(
      contactId,
      "A message couldn't be decrypted. It was encrypted to an old key of "
      'yours; ask the sender to resend it.',
      id: _uuid.v4(),
    );
    _changed(contactId);
  }

  // ===========================================================================
  // Helpers
  // ===========================================================================

  CryptoIdentity _requireIdentity() {
    final id = _identity;
    if (id == null) throw StateError('ChatService.start() has not been called');
    return id;
  }

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
  }
}
