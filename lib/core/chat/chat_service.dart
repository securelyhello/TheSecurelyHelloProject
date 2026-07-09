import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/networking/supabase_directory_service.dart';

// =============================================================================
// Domain models
// =============================================================================

/// Local representation of a chat message.
class Message {
  final String id;
  final String conversationId;
  final String senderId;

  /// Decrypted plaintext for display.  Stored encrypted in SQLite; only
  /// decrypted into this field when read back for the UI.
  final String content;

  final DateTime timestamp;

  /// One of: `sending`, `sent`, `delivered`, `read`.
  final String status;

  final bool isFromMe;

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.content,
    required this.timestamp,
    required this.status,
    required this.isFromMe,
  });

  factory Message.fromMap(Map<String, dynamic> map) {
    return Message(
      id: map['id'] as String,
      conversationId: map['conversation_id'] as String,
      senderId: map['sender_id'] as String,
      content: map['content'] as String,
      timestamp:
          DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      status: map['status'] as String,
      isFromMe: (map['is_from_me'] as int) == 1,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'conversation_id': conversationId,
        'sender_id': senderId,
        'content': content,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'status': status,
        'is_from_me': isFromMe ? 1 : 0,
      };
}

/// Local representation of a conversation list entry.
class Conversation {
  final String id;
  final String contactUserId;
  final String? lastMessage;
  final DateTime? lastMessageTime;
  final int unreadCount;

  /// Cached contact profile info (populated from contacts_cache table).
  final Map<String, dynamic>? contactInfo;

  const Conversation({
    required this.id,
    required this.contactUserId,
    this.lastMessage,
    this.lastMessageTime,
    this.unreadCount = 0,
    this.contactInfo,
  });

  factory Conversation.fromMap(
    Map<String, dynamic> map, {
    Map<String, dynamic>? contactInfo,
  }) {
    return Conversation(
      id: map['id'] as String,
      contactUserId: map['contact_user_id'] as String,
      lastMessage: map['last_message'] as String?,
      lastMessageTime: map['last_message_time'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              map['last_message_time'] as int)
          : null,
      unreadCount: (map['unread_count'] as int?) ?? 0,
      contactInfo: contactInfo,
    );
  }
  Conversation copyWith({
    String? id,
    String? contactUserId,
    String? lastMessage,
    DateTime? lastMessageTime,
    int? unreadCount,
    Map<String, dynamic>? contactInfo,
  }) {
    return Conversation(
      id: id ?? this.id,
      contactUserId: contactUserId ?? this.contactUserId,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
      contactInfo: contactInfo ?? this.contactInfo,
    );
  }
}

// =============================================================================
// Wire protocol for data-channel messages
// =============================================================================

/// Minimal envelope sent over WebRTC data channels or the relay queue.
///
/// ```json
/// {
///   "id": "<uuid>",
///   "s": "<sender_user_id>",
///   "t": <unix_ms>,
///   "c": "<base64 NaCl-box ciphertext>"
/// }
/// ```
class _WireMessage {
  final String id;
  final String senderId;
  final int timestampMs;
  final String ciphertextBase64;

  _WireMessage({
    required this.id,
    required this.senderId,
    required this.timestampMs,
    required this.ciphertextBase64,
  });

  Uint8List encode() =>
      Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  Map<String, dynamic> toJson() => {
        'id': id,
        's': senderId,
        't': timestampMs,
        'c': ciphertextBase64,
      };

  static _WireMessage fromJson(Map<String, dynamic> json) => _WireMessage(
        id: json['id'] as String,
        senderId: json['s'] as String,
        timestampMs: json['t'] as int,
        ciphertextBase64: json['c'] as String,
      );

  static _WireMessage fromBytes(Uint8List bytes) =>
      fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
}

// =============================================================================
// ChatService
// =============================================================================

/// Top-level service that orchestrates end-to-end encrypted messaging.
///
/// Wires together [CryptoCore] + [LocalStorage] + [P2PConnectionManager] +
/// [SupabaseDirectoryService] into a single API surface consumed by the UI
/// layer.
class ChatService {
  final LocalStorage _storage;
  final P2PConnectionManager _p2p;
  final SupabaseDirectoryService _directory;

  CryptoIdentity? _identity;
  final _uuid = const Uuid();

  // Stream controllers for reactive UI updates.
  final StreamController<List<Message>> _messagesController =
      StreamController<List<Message>>.broadcast();
  final StreamController<List<Conversation>> _conversationsController =
      StreamController<List<Conversation>>.broadcast();
  final StreamController<Message> _onMessageReceivedController =
      StreamController<Message>.broadcast();

  // Active subscriptions we need to cancel on dispose.
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  // Tracks in-flight signaling sessions so we don't duplicate them.
  final Map<String, String> _activeSignalingSessions = {}; // contactId → sessionId

  ChatService({
    required LocalStorage storage,
    required P2PConnectionManager p2p,
    required SupabaseDirectoryService directory,
    CryptoIdentity? identity,
  })  : _storage = storage,
        _p2p = p2p,
        _directory = directory,
        _identity = identity;

  Stream<Message> get onMessageReceived => _onMessageReceivedController.stream;

  /// The loaded cryptographic identity.  `null` until [init] completes.
  CryptoIdentity? get identity => _identity;

  /// The current user's Supabase user id.
  String? get currentUserId => _directory.currentUser?.id;

  // ===========================================================================
  // Initialization
  // ===========================================================================

  /// Boots the chat service:
  ///
  /// 1. Loads (or generates) the cryptographic identity from local storage.
  /// 2. Initializes the P2P connection manager.
  /// 3. Sets up listeners for signaling, ICE candidates, and data-channel
  ///    messages.
  /// 4. Drains the relay queue for any messages received while offline.
  Future<void> init() async {
    // 1. Identity
    _identity ??= await _storage.loadIdentity();
    if (_identity == null) {
      _identity = CryptoCore.generateIdentity();
      await _storage.saveIdentity(_identity!);
    }

    // 2. P2P
    await _p2p.init();

    // 3. Listeners
    _listenForSignalingSessions();
    _listenForDataChannelMessages();
    _listenForIceCandidates();
    _listenForConnectionStateChanges();

    // 4. Drain relay queue
    await _drainRelayQueue();
  }

  // ===========================================================================
  // Send
  // ===========================================================================

  /// Sends a plaintext [message] to [contactId].
  ///
  /// 1. Fetches the contact's public encryption key.
  /// 2. Encrypts with NaCl box.
  /// 3. Stores the **plaintext** locally with status `sending`.
  /// 4. Transmits over P2P if connected, otherwise relays via Supabase.
  /// 5. Updates local status to `sent`.
  Future<Message> sendMessage(String contactId, String plaintext) async {
    final identity = _requireIdentity();
    final uid = _requireUserId();

    // --- 1. Get contact's encryption key ---
    final contactEncKey = await _getContactEncryptionKey(contactId);

    // --- 2. Encrypt ---
    final plaintextBytes = Uint8List.fromList(utf8.encode(plaintext));
    final ciphertext = CryptoCore.encrypt(
      plaintextBytes,
      CryptoCore.fromBase64(contactEncKey),
      Uint8List.fromList(identity.encryptionPrivateKey),
    );

    // --- 3. Store locally ---
    final messageId = _uuid.v4();
    final now = DateTime.now();
    final conversationId = _conversationId(uid, contactId);

    await _storage.insertMessage(
      id: messageId,
      conversationId: conversationId,
      senderId: uid,
      content: plaintext,
      timestamp: now.millisecondsSinceEpoch,
      status: 'sending',
      isFromMe: true,
    );

    await _storage.updateConversation(
      id: conversationId,
      contactUserId: contactId,
      lastMessage: plaintext,
      lastMessageTime: now.millisecondsSinceEpoch,
    );

    // Notify UI immediately.
    _emitMessages(conversationId);
    _emitConversations();

    // --- 4. Transmit ---
    final wire = _WireMessage(
      id: messageId,
      senderId: uid,
      timestampMs: now.millisecondsSinceEpoch,
      ciphertextBase64: CryptoCore.toBase64(ciphertext),
    );

    if (_p2p.isConnected(contactId)) {
      _p2p.sendMessage(contactId, wire.encode());
      await _storage.updateMessageStatus(messageId, 'sent');
    } else {
      // Try to establish P2P; meanwhile relay via Supabase.
      _initiateP2PConnection(contactId);
      await _directory.queueRelayMessage(
        contactId,
        jsonEncode(wire.toJson()),
      );
      await _storage.updateMessageStatus(messageId, 'sent');
    }

    _emitMessages(conversationId);

    return Message(
      id: messageId,
      conversationId: conversationId,
      senderId: uid,
      content: plaintext,
      timestamp: now,
      status: 'sent',
      isFromMe: true,
    );
  }

  // ===========================================================================
  // Queries (reactive)
  // ===========================================================================

  /// Returns a stream of messages for [conversationId], refreshed
  /// whenever a new message is sent or received in that conversation.
  Stream<List<Message>> getMessages(String conversationId) {
    // Emit current state right away, then push updates.
    _emitMessages(conversationId);
    return _messagesController.stream;
  }

  /// Returns a stream of all conversations, refreshed on changes.
  Stream<List<Conversation>> getConversations() {
    _emitConversations();
    return _conversationsController.stream;
  }

  /// One-shot fetch of messages (non-reactive).
  Future<List<Message>> fetchMessages(
    String conversationId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final rows = await _storage.getMessages(conversationId,
        limit: limit, offset: offset);
    return rows.map(Message.fromMap).toList();
  }

  /// Marks all messages in a conversation as read and resets the unread
  /// counter.
  Future<void> markConversationAsRead(String conversationId) async {
    await _storage.clearUnreadCount(conversationId);
    _emitConversations();
  }

  /// Deletes a conversation and all its messages from local storage.
  Future<void> deleteConversation(String conversationId) async {
    await _storage.deleteConversation(conversationId);
    _emitConversations();
  }

  // ===========================================================================
  // P2P helpers
  // ===========================================================================

  /// Initiates a WebRTC connection to [contactId] if one doesn't already
  /// exist.
  Future<void> _initiateP2PConnection(String contactId) async {
    if (_p2p.isConnected(contactId) ||
        _activeSignalingSessions.containsKey(contactId)) {
      return;
    }

    try {
      final sdpOffer = await _p2p.createOffer(contactId);
      final sessionId =
          await _directory.createSignalingSession(contactId, sdpOffer);
      _activeSignalingSessions[contactId] = sessionId;

      // Listen for ICE candidates on this session.
      _listenForSessionIceCandidates(sessionId, contactId);

      // Listen for the answer.
      _listenForSignalingAnswer(sessionId, contactId);
    } catch (e) {
      _activeSignalingSessions.remove(contactId);
      // Silently log — the message was already relayed.
    }
  }

  void _listenForSignalingAnswer(String sessionId, String contactId) {
    final sub = _directory.listenForSignalingSessions().listen((event) async {
      if (event['session_id'] == sessionId && event['status'] == 'answered') {
        final sdpAnswer = event['answer_sdp'] as String?;
        if (sdpAnswer != null) {
          await _p2p.handleAnswer(contactId, sdpAnswer);
          await _directory.completeSignalingSession(sessionId);
        }
      }
    });
    _subscriptions.add(sub);
  }

  // ===========================================================================
  // Signaling listeners
  // ===========================================================================

  /// Subscribes to incoming signaling sessions where we are the callee.
  void _listenForSignalingSessions() {
    final sub = _directory.listenForSignalingSessions().listen((session) async {
      final status = session['status'] as String?;
      final sessionId = session['session_id'] as String;
      final callerId = session['caller_user_id'] as String;
      
      if (status == 'expired' || status == 'failed') {
        _activeSignalingSessions.remove(callerId);
        return;
      }
      
      if (status != 'pending') return;

      final sdpOffer = session['offer_sdp'] as String?;

      if (sdpOffer == null) return;

      try {
        final sdpAnswer = await _p2p.handleOffer(callerId, sdpOffer);
        await _directory.answerSignalingSession(sessionId, sdpAnswer);
        _activeSignalingSessions[callerId] = sessionId;

        _listenForSessionIceCandidates(sessionId, callerId);
      } catch (e) {
        // If we can't handle the offer, ignore — the caller will fall back
        // to relay.
      }
    });
    _subscriptions.add(sub);
  }

  void _listenForSessionIceCandidates(
      String sessionId, String contactId) {
    final sub =
        _directory.listenForIceCandidates(sessionId).listen((row) async {
      try {
        final candidateMap = <String, dynamic>{
          'candidate': row['candidate'],
          'sdpMLineIndex': row['sdp_mline_index'],
          'sdpMid': row['sdp_mid'],
        };
        await _p2p.addIceCandidate(contactId, candidateMap);
      } catch (_) {
        // ICE candidate may arrive after connection is settled — safe to ignore.
      }
    });
    _subscriptions.add(sub);
  }

  /// Relays locally gathered ICE candidates to the remote peer via Supabase.
  void _listenForIceCandidates() {
    final sub = _p2p.onIceCandidate.listen((event) async {
      final sessionId = _activeSignalingSessions[event.contactId];
      if (sessionId == null) return;

      try {
        await _directory.sendIceCandidate(
          sessionId,
          event.contactId,
          {
            'candidate': event.candidate.candidate,
            'sdpMid': event.candidate.sdpMid,
            'sdpMLineIndex': event.candidate.sdpMLineIndex,
          },
        );
      } catch (_) {
        // Best-effort relay; the connection may still succeed without this
        // candidate.
      }
    });
    _subscriptions.add(sub);
  }

  /// Cleans up signaling state when a P2P connection reaches a terminal
  /// state.
  void _listenForConnectionStateChanges() {
    final sub = _p2p.onConnectionStateChange.listen((event) async {
      final sessionId = _activeSignalingSessions[event.contactId];
      if (sessionId == null) return;

      if (event.state == P2PConnectionState.connected ||
          event.state == P2PConnectionState.failed ||
          event.state == P2PConnectionState.disconnected) {
        _activeSignalingSessions.remove(event.contactId);
        try {
          await _directory.cleanupSignaling(sessionId);
        } catch (_) {}
      }
    });
    _subscriptions.add(sub);
  }

  // ===========================================================================
  // Incoming message handling
  // ===========================================================================

  /// Listens for encrypted messages arriving over data channels.
  void _listenForDataChannelMessages() {
    final sub = _p2p.onDataChannelMessage.listen((event) async {
      await _handleIncomingWireMessage(event.contactId, event.data);
    });
    _subscriptions.add(sub);
  }

  /// Processes a single incoming encrypted wire message.
  Future<void> _handleIncomingWireMessage(
      String contactId, Uint8List raw) async {
    try {
      final wire = _WireMessage.fromBytes(raw);
      await _decryptAndStore(wire, contactId);
    } catch (e) {
      // Malformed message — drop silently.
    }
  }

  /// Decrypts a [_WireMessage] and persists the plaintext locally.
  Future<void> _decryptAndStore(
      _WireMessage wire, String contactId) async {
    final identity = _requireIdentity();
    final uid = _requireUserId();

    final contactEncKey = await _getContactEncryptionKey(contactId);
    final ciphertext = CryptoCore.fromBase64(wire.ciphertextBase64);

    final plainBytes = CryptoCore.decrypt(
      ciphertext,
      CryptoCore.fromBase64(contactEncKey),
      Uint8List.fromList(identity.encryptionPrivateKey),
    );
    final plaintext = utf8.decode(plainBytes);

    final conversationId = _conversationId(uid, contactId);

    await _storage.insertMessage(
      id: wire.id,
      conversationId: conversationId,
      senderId: wire.senderId,
      content: plaintext,
      timestamp: wire.timestampMs,
      status: 'delivered',
      isFromMe: false,
    );

    await _storage.updateConversation(
      id: conversationId,
      contactUserId: contactId,
      lastMessage: plaintext,
      lastMessageTime: wire.timestampMs,
    );
    await _storage.incrementUnreadCount(conversationId);

    _emitMessages(conversationId);
    _emitConversations();
    
    final msg = Message(
      id: wire.id,
      conversationId: conversationId,
      senderId: wire.senderId,
      content: plaintext,
      timestamp: DateTime.fromMillisecondsSinceEpoch(wire.timestampMs),
      status: 'delivered',
      isFromMe: false,
    );
    if (!_onMessageReceivedController.isClosed) {
      _onMessageReceivedController.add(msg);
    }
  }

  // ===========================================================================
  // Relay queue
  // ===========================================================================

  /// Downloads and processes all relay-queue messages waiting for us.
  Future<void> _drainRelayQueue() async {
    try {
      final relayMessages = await _directory.fetchRelayMessages();
      for (final row in relayMessages) {
        try {
          final payload = row['encrypted_blob'] as String;
          final senderId = row['sender_id'] as String;
          final wireJson =
              jsonDecode(payload) as Map<String, dynamic>;
          final wire = _WireMessage.fromJson(wireJson);

          await _decryptAndStore(wire, senderId);
          await _directory.deleteRelayMessage(row['id'] as String);
        } catch (_) {
          // Skip malformed relay messages.
        }
      }
    } catch (_) {
      // Network error — will retry on next init.
    }
  }

  /// Manually triggers a relay-queue drain (e.g. when the app comes to
  /// foreground).
  Future<void> drainRelayQueue() => _drainRelayQueue();

  // ===========================================================================
  // Dispose
  // ===========================================================================

  /// Tears down all listeners, streams, and connections.
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();

    _messagesController.close();
    _conversationsController.close();
    _onMessageReceivedController.close();

    _p2p.dispose();
    _directory.dispose();
  }

  // ===========================================================================
  // Private helpers
  // ===========================================================================

  CryptoIdentity _requireIdentity() {
    final id = _identity;
    if (id == null) {
      throw StateError('ChatService.init() has not been called');
    }
    return id;
  }

  String _requireUserId() {
    final uid = _directory.currentUser?.id;
    if (uid == null) {
      throw StateError('No authenticated user');
    }
    return uid;
  }

  /// Deterministic conversation ID from two user IDs.  Always sorts
  /// lexicographically so both parties derive the same ID.
  String _conversationId(String userA, String userB) {
    final sorted = [userA, userB]..sort();
    return '${sorted[0]}_${sorted[1]}';
  }

  /// Returns the Base64 public encryption key for [contactId], checking the
  /// local cache first, then falling back to Supabase and caching the result.
  Future<String> _getContactEncryptionKey(String contactId) async {
    // Try local cache first.
    final cached = await _storage.getCachedContact(contactId);
    if (cached != null && cached['public_encryption_key'] != null) {
      return cached['public_encryption_key'] as String;
    }

    // Fetch from Supabase and cache.
    final user = await _directory.getUserById(contactId);
    if (user == null) {
      throw StateError('Contact $contactId not found in user directory');
    }

    await _storage.cacheContact(
      userId: contactId,
      username: user['username'] as String?,
      displayName: user['display_name'] as String?,
      avatarUrl: null, // Removed from schema
      publicSigningKey: user['signing_public_key'] as String?,
      publicEncryptionKey: user['encryption_public_key'] as String?,
      isOnline: user['status'] == 'online',
    );

    return user['encryption_public_key'] as String;
  }

  /// Pushes the latest message list for [conversationId] into the messages
  /// stream.
  void _emitMessages(String conversationId) async {
    try {
      final rows = await _storage.getMessages(conversationId);
      final messages = rows.map(Message.fromMap).toList();
      if (!_messagesController.isClosed) {
        _messagesController.add(messages);
      }
    } catch (_) {}
  }

  /// Pushes the latest conversation list into the conversations stream.
  void _emitConversations() async {
    try {
      final rows = await _storage.getConversations();
      final conversations = <Conversation>[];

      for (final row in rows) {
        final contactId = row['contact_user_id'] as String;
        final contactInfo = await _storage.getCachedContact(contactId);
        conversations.add(
            Conversation.fromMap(row, contactInfo: contactInfo));
      }

      if (!_conversationsController.isClosed) {
        _conversationsController.add(conversations);
      }
    } catch (_) {}
  }
}
