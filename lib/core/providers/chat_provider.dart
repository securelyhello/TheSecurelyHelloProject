import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:securelyhello/core/chat/attachment_service.dart';
import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/crypto/crypto_core.dart';

/// Manages chat conversations and messages for the UI.
///
/// Conversation ids are the contact's user id (1:1 chats).
class ChatProvider extends ChangeNotifier {
  static const _readReceiptsPref = 'send_read_receipts';
  static const _typingTimeout = Duration(seconds: 6);
  static const _typingIdle = Duration(seconds: 4);
  static const _typingResend = Duration(seconds: 3);

  final ChatService _chatService;

  List<Conversation> _conversations = [];
  final Map<String, List<Message>> _messageCache = {};
  final Map<String, int> _messageLimits = {};
  String? _activeConversationId;
  bool _isLoading = false;
  bool _initialized = false;
  String? _errorMessage;
  bool _sendReadReceipts = true;

  final Map<String, Timer> _typingContacts = {};
  final Map<String, Timer> _myTypingIdle = {};
  final Map<String, DateTime> _myTypingSentAt = {};

  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _refreshTimer;

  // Coalesces bursts of change events (e.g. a relay drain) into one reload.
  final Set<String> _changedPending = {};
  Timer? _changeDebounce;

  ChatProvider({required ChatService chatService}) : _chatService = chatService;

  // -- Getters --
  List<Conversation> get conversations => List.unmodifiable(_conversations);
  String? get activeConversationId => _activeConversationId;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get sendReadReceipts => _sendReadReceipts;
  int get totalUnreadCount =>
      _conversations.fold(0, (sum, c) => sum + c.unreadCount);

  /// Get messages for a conversation (newest first).
  List<Message> getMessages(String conversationId) {
    return List.unmodifiable(_messageCache[conversationId] ?? []);
  }

  /// Check if a contact is typing.
  bool isContactTyping(String contactId) =>
      _typingContacts.containsKey(contactId);

  /// Start messaging for the signed-in user.
  Future<void> init({
    required CryptoIdentity identity,
    required String myUserId,
    required String deviceId,
  }) async {
    if (_initialized && _chatService.myUserId == myUserId) return;
    _isLoading = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      _sendReadReceipts = prefs.getBool(_readReceiptsPref) ?? true;
      _chatService.sendReadReceipts = _sendReadReceipts;

      await _chatService.start(
          identity: identity, myUserId: myUserId, deviceId: deviceId);
      await loadConversations();

      _subs
        ..add(_chatService.onConversationChanged.listen(_onConversationChanged))
        ..add(_chatService.onTyping.listen(_onTyping));

      // Safety net only: the socket pushes relay messages and every
      // reconnect drains the queue, so this rarely finds anything.
      _refreshTimer = Timer.periodic(const Duration(minutes: 3), (_) {
        _chatService.drainRelayQueue();
        _chatService.resendUnsent();
      });
      _initialized = true;
    } catch (e) {
      _errorMessage = 'Failed to initialize chat: $e';
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Called when the app returns to the foreground.
  Future<void> onResume() async {
    if (!_initialized) return;
    await _chatService.drainRelayQueue();
    await _chatService.resendUnsent();
    final active = _activeConversationId;
    if (active != null) await _chatService.markConversationRead(active);
  }

  /// Stop messaging and clear in-memory state (sign-out).
  Future<void> reset() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _changeDebounce?.cancel();
    _changedPending.clear();
    for (final t in [..._typingContacts.values, ..._myTypingIdle.values]) {
      t.cancel();
    }
    _typingContacts.clear();
    _myTypingIdle.clear();
    _myTypingSentAt.clear();

    await _chatService.stop();

    _conversations = [];
    _messageCache.clear();
    _messageLimits.clear();
    _activeConversationId = null;
    _initialized = false;
    _errorMessage = null;
    notifyListeners();
  }

  /// Load all conversations from local storage.
  Future<void> loadConversations() async {
    try {
      _conversations = await _chatService.fetchConversations();
      _conversations.sort((a, b) => (b.lastMessageTime ?? DateTime(2000))
          .compareTo(a.lastMessageTime ?? DateTime(2000)));
      notifyListeners();
    } catch (e) {
      _errorMessage = 'Failed to load conversations: $e';
      notifyListeners();
    }
  }

  final Map<String, Verification> _verification = {};

  /// Verification state of a loaded conversation's contact (refreshed with
  /// its messages).
  Verification verificationCached(String contactId) =>
      _verification[contactId] ?? Verification.unverified;

  /// Load (or reload) the newest messages of a conversation.
  Future<void> loadMessages(String conversationId) async {
    try {
      final limit = _messageLimits[conversationId] ?? 50;
      _messageCache[conversationId] =
          await _chatService.fetchMessages(conversationId, limit: limit);
      _verification[conversationId] = await _chatService.verificationOf(conversationId);
      notifyListeners();
    } catch (e) {
      _errorMessage = 'Failed to load messages: $e';
      notifyListeners();
    }
  }

  /// Extend the loaded history by another page.
  Future<void> loadOlderMessages(String conversationId) async {
    final loaded = _messageCache[conversationId]?.length ?? 0;
    final limit = _messageLimits[conversationId] ?? 50;
    if (loaded < limit) return; // everything is already loaded
    _messageLimits[conversationId] = limit + 50;
    await loadMessages(conversationId);
  }

  /// Open a conversation — set active, load messages, mark as read, and try
  /// to bring up a direct P2P link.
  Future<void> openConversation(String conversationId) async {
    _activeConversationId = conversationId;
    _chatService.setActiveConversation(conversationId);
    _isLoading = true;
    notifyListeners();

    await loadMessages(conversationId);
    await _chatService.markConversationRead(conversationId);
    unawaited(_chatService.connect(conversationId));

    _isLoading = false;
    notifyListeners();
  }

  /// Close the active conversation.
  void closeConversation() {
    final active = _activeConversationId;
    if (active != null) _stopMyTyping(active);
    _activeConversationId = null;
    _chatService.setActiveConversation(null);
    notifyListeners();
  }

  Future<int> disappearAfter(String contactId) => _chatService.disappearAfter(contactId);

  Future<void> setDisappearing(String contactId, int seconds) async {
    await _chatService.setDisappearing(contactId, seconds);
    notifyListeners();
  }

  /// React to a message ('' removes our reaction).
  Future<void> react(String contactId, String messageId, String emoji) =>
      _chatService.react(contactId, messageId, emoji);

  Future<bool> editMessage(String contactId, String messageId, String text) =>
      _chatService.editMessage(contactId, messageId, text.trim());

  Future<bool> deleteForEveryone(String contactId, String messageId) =>
      _chatService.deleteForEveryone(contactId, messageId);

  Future<void> deleteForMe(String contactId, String messageId) =>
      _chatService.deleteForMe(contactId, messageId);

  /// Send a text message to a contact.
  Future<bool> sendMessage(String contactId, String plaintext,
      {Map<String, dynamic>? replyTo}) async {
    final text = plaintext.trim();
    if (text.isEmpty) return false;
    _errorMessage = null;
    _stopMyTyping(contactId);

    try {
      await _chatService.sendMessage(contactId, text, replyTo: replyTo);
      return true;
    } catch (e) {
      _errorMessage = 'Failed to send message: $e';
      notifyListeners();
      return false;
    }
  }

  /// Contacts with an upload in progress (the composer shows a spinner).
  final Set<String> _uploading = {};
  bool isUploading(String contactId) => _uploading.contains(contactId);

  /// The attachment store (load / save attachments shown in a chat).
  AttachmentService get attachments => _chatService.attachments;

  /// Encrypts, uploads and sends a file.
  Future<bool> sendAttachment(
    String contactId, {
    required Uint8List bytes,
    required String name,
    String caption = '',
  }) async {
    _errorMessage = null;
    _uploading.add(contactId);
    notifyListeners();
    try {
      await _chatService.sendAttachment(contactId,
          bytes: bytes, name: name, caption: caption.trim());
      return true;
    } catch (e) {
      _errorMessage = e is AttachmentTooLargeException ||
              e is ApiException ||
              e is NetworkException
          ? e.toString()
          : 'Failed to send the file: $e';
      return false;
    } finally {
      _uploading.remove(contactId);
      notifyListeners();
    }
  }

  /// Retry messages stuck in `failed`.
  Future<void> retryFailed() => _chatService.resendUnsent();

  /// Call on every composer change to drive the typing indicator.
  void onComposerChanged(String contactId, String text) {
    if (text.trim().isEmpty) {
      _stopMyTyping(contactId);
      return;
    }
    final last = _myTypingSentAt[contactId];
    if (last == null || DateTime.now().difference(last) > _typingResend) {
      _myTypingSentAt[contactId] = DateTime.now();
      _chatService.sendTyping(contactId, true);
    }
    _myTypingIdle[contactId]?.cancel();
    _myTypingIdle[contactId] =
        Timer(_typingIdle, () => _stopMyTyping(contactId));
  }

  void _stopMyTyping(String contactId) {
    _myTypingIdle.remove(contactId)?.cancel();
    if (_myTypingSentAt.remove(contactId) != null) {
      _chatService.sendTyping(contactId, false);
    }
  }

  /// Mark a conversation as read.
  Future<void> markConversationAsRead(String conversationId) =>
      _chatService.markConversationRead(conversationId);

  /// Delete all messages but keep the chat.
  Future<void> clearConversation(String conversationId) =>
      _chatService.clearConversation(conversationId);

  /// Delete a conversation and all its messages.
  Future<void> deleteConversation(String conversationId) async {
    try {
      _conversations.removeWhere((c) => c.id == conversationId);
      _messageCache.remove(conversationId);
      notifyListeners();
      await _chatService.deleteConversation(conversationId);
    } catch (e) {
      _errorMessage = 'Failed to delete conversation: $e';
      notifyListeners();
    }
  }

  /// Get or create a conversation for a contact.
  Future<String> getOrCreateConversation(String contactUserId) async {
    if (!_conversations.any((c) => c.contactUserId == contactUserId)) {
      await _chatService.ensureConversation(contactUserId);
      await loadConversations();
    }
    return contactUserId;
  }

  /// Safety number shared with [contactId].
  Future<String?> safetyNumberFor(String contactId) =>
      _chatService.safetyNumberFor(contactId);

  Future<Verification> verificationOf(String contactId) =>
      _chatService.verificationOf(contactId);

  Future<void> markVerified(String contactId) async {
    await _chatService.markVerified(contactId);
    notifyListeners();
  }

  Future<void> clearVerified(String contactId) async {
    await _chatService.clearVerified(contactId);
    notifyListeners();
  }

  /// The latest [limit] messages with [contactId], newest first.
  Future<List<Message>> recentMessages(String contactId, {int limit = 20}) =>
      _chatService.fetchMessages(contactId, limit: limit);

  /// Each newly received message (for notifications).
  Stream<Message> get onMessageReceived => _chatService.onMessageReceived;

  /// The signed-in user's id, once messaging has started.
  String? get myUserId => _chatService.myUserId;

  /// How many devices [userId] has (for ourselves: including this one).
  Future<int> deviceCount(String userId) async =>
      (await _chatService.devicesOf(userId)).length;

  /// Toggle read receipts (persisted).
  Future<void> setSendReadReceipts(bool value) async {
    _sendReadReceipts = value;
    _chatService.sendReadReceipts = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_readReceiptsPref, value);
  }

  // -- Private --

  void _onConversationChanged(String contactId) {
    _changedPending.add(contactId);
    _changeDebounce?.cancel();
    _changeDebounce = Timer(const Duration(milliseconds: 80), () async {
      final changed = Set.of(_changedPending);
      _changedPending.clear();
      await loadConversations();
      for (final id in changed) {
        if (_messageCache.containsKey(id) || _activeConversationId == id) {
          await loadMessages(id);
        }
      }
    });
  }

  void _onTyping(TypingEvent event) {
    _typingContacts.remove(event.contactId)?.cancel();
    if (event.isTyping) {
      _typingContacts[event.contactId] = Timer(_typingTimeout, () {
        _typingContacts.remove(event.contactId);
        notifyListeners();
      });
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _changeDebounce?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}
