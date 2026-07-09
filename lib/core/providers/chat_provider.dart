import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/storage/local_storage.dart';

/// Manages chat conversations and messages.
class ChatProvider extends ChangeNotifier {
  final ChatService _chatService;
  final LocalStorage _localStorage;

  List<Conversation> _conversations = [];
  final Map<String, List<Message>> _messageCache = {};
  String? _activeConversationId;
  bool _isLoading = false;
  String? _errorMessage;
  final Set<String> _typingContacts = {};
  Timer? _refreshTimer;

  ChatProvider({
    required ChatService chatService,
    required LocalStorage localStorage,
  })  : _chatService = chatService,
        _localStorage = localStorage;

  // -- Getters --
  List<Conversation> get conversations => List.unmodifiable(_conversations);
  String? get activeConversationId => _activeConversationId;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  int get totalUnreadCount =>
      _conversations.fold(0, (sum, c) => sum + c.unreadCount);

  /// Get messages for a conversation.
  List<Message> getMessages(String conversationId) {
    return List.unmodifiable(_messageCache[conversationId] ?? []);
  }

  /// Check if a contact is typing.
  bool isContactTyping(String contactId) => _typingContacts.contains(contactId);

  /// Initialize — load conversations, set up listeners.
  Future<void> init() async {
    _isLoading = true;
    notifyListeners();

    try {
      await _chatService.init();
      await loadConversations();

      // Listen for incoming messages
      _chatService.onMessageReceived.listen((message) {
        _handleIncomingMessage(message);
      });

      // Periodic refresh for conversation list
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => loadConversations(),
      );
    } catch (e) {
      _errorMessage = 'Failed to initialize chat: $e';
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Load all conversations from local storage.
  Future<void> loadConversations() async {
    try {
      final data = await _localStorage.getConversations();
      _conversations = data.map((map) => Conversation.fromMap(map)).toList();

      // Sort by most recent message
      _conversations.sort((a, b) =>
          (b.lastMessageTime ?? DateTime(2000))
              .compareTo(a.lastMessageTime ?? DateTime(2000)));

      notifyListeners();
    } catch (e) {
      _errorMessage = 'Failed to load conversations: $e';
      notifyListeners();
    }
  }

  /// Load messages for a specific conversation.
  Future<void> loadMessages(String conversationId, {int limit = 50, int offset = 0}) async {
    _isLoading = true;
    notifyListeners();

    try {
      final data = await _localStorage.getMessages(conversationId, limit: limit, offset: offset);
      final messages = data.map((map) => Message.fromMap(map)).toList();

      if (offset == 0) {
        _messageCache[conversationId] = messages;
      } else {
        _messageCache[conversationId] = [
          ...(_messageCache[conversationId] ?? []),
          ...messages,
        ];
      }
    } catch (e) {
      _errorMessage = 'Failed to load messages: $e';
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Open a conversation — set active, load messages, mark as read.
  Future<void> openConversation(String conversationId) async {
    _activeConversationId = conversationId;
    await loadMessages(conversationId);
    await markConversationAsRead(conversationId);
  }

  /// Close the active conversation.
  void closeConversation() {
    _activeConversationId = null;
    notifyListeners();
  }

  /// Send a text message to a contact.
  Future<bool> sendMessage(String contactId, String plaintext) async {
    if (plaintext.trim().isEmpty) return false;
    _errorMessage = null;

    try {
      await _chatService.sendMessage(contactId, plaintext.trim());

      // Refresh messages for this conversation
      await loadMessages(contactId);
      await loadConversations();

      return true;
    } catch (e) {
      _errorMessage = 'Failed to send message: $e';
      notifyListeners();
      return false;
    }
  }

  /// Mark a conversation as read.
  Future<void> markConversationAsRead(String conversationId) async {
    try {
      final index = _conversations.indexWhere((c) => c.id == conversationId);
      if (index != -1) {
        await _localStorage.updateConversation(
          id: conversationId,
          contactUserId: _conversations[index].contactUserId,
          unreadCount: 0,
        );

        _conversations[index] = _conversations[index].copyWith(unreadCount: 0);
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Delete a conversation and all its messages.
  Future<void> deleteConversation(String conversationId) async {
    try {
      await _localStorage.deleteConversation(conversationId);
      _conversations.removeWhere((c) => c.id == conversationId);
      _messageCache.remove(conversationId);
      notifyListeners();
    } catch (e) {
      _errorMessage = 'Failed to delete conversation: $e';
      notifyListeners();
    }
  }

  /// Set typing status for a contact (for UI display).
  void setContactTyping(String contactId, bool isTyping) {
    if (isTyping) {
      _typingContacts.add(contactId);
    } else {
      _typingContacts.remove(contactId);
    }
    notifyListeners();
  }

  /// Handle an incoming message from the chat service.
  void _handleIncomingMessage(Message message) {
    // Add to message cache
    final conversationId = message.conversationId;
    if (_messageCache.containsKey(conversationId)) {
      _messageCache[conversationId]!.insert(0, message);
    } else {
      _messageCache[conversationId] = [message];
    }

    // Update conversation list
    final existingIndex = _conversations.indexWhere((c) => c.id == conversationId);
    if (existingIndex != -1) {
      final existing = _conversations[existingIndex];
      _conversations[existingIndex] = existing.copyWith(
        lastMessage: message.content,
        lastMessageTime: message.timestamp,
        unreadCount: _activeConversationId == conversationId
            ? 0
            : existing.unreadCount + 1,
      );
    } else {
      _conversations.insert(
        0,
        Conversation(
          id: conversationId,
          contactUserId: message.senderId,
          lastMessage: message.content,
          lastMessageTime: message.timestamp,
          unreadCount: _activeConversationId == conversationId ? 0 : 1,
        ),
      );
    }

    // Re-sort
    _conversations.sort((a, b) =>
        (b.lastMessageTime ?? DateTime(2000))
            .compareTo(a.lastMessageTime ?? DateTime(2000)));

    notifyListeners();
  }

  /// Get or create a conversation for a contact.
  Future<String> getOrCreateConversation(String contactUserId) async {
    // Check if conversation already exists
    final existing = _conversations.where((c) => c.contactUserId == contactUserId);
    if (existing.isNotEmpty) {
      return existing.first.id;
    }

    // Create new conversation in local storage
    final conversationId = contactUserId; // Use contact user ID as conversation ID for 1:1 chats
    await _localStorage.updateConversation(
      id: conversationId,
      contactUserId: contactUserId,
      unreadCount: 0,
    );

    await loadConversations();
    return conversationId;
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }
}
