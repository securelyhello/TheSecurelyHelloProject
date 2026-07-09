import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:securelyhello/core/networking/supabase_directory_service.dart';
import 'package:securelyhello/core/storage/local_storage.dart';

/// Represents a contact with full profile data.
class Contact {
  final String userId;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final String publicSigningKey;
  final String publicEncryptionKey;
  final bool isOnline;
  final DateTime? lastSeen;
  final String? nickname;

  const Contact({
    required this.userId,
    required this.username,
    required this.displayName,
    this.avatarUrl,
    required this.publicSigningKey,
    required this.publicEncryptionKey,
    this.isOnline = false,
    this.lastSeen,
    this.nickname,
  });

  factory Contact.fromMap(Map<String, dynamic> map) {
    // Handle joined query format: contacts joined with users
    final userData = map['contact_user'] as Map<String, dynamic>? ?? map;
    return Contact(
      userId: userData['user_id']?.toString() ?? map['contact_user_id']?.toString() ?? '',
      username: userData['username']?.toString() ?? '',
      displayName: userData['display_name']?.toString() ?? '',
      avatarUrl: null, // Removed from schema
      publicSigningKey: userData['signing_public_key']?.toString() ?? '',
      publicEncryptionKey: userData['encryption_public_key']?.toString() ?? '',
      isOnline: userData['status'] == 'online',
      lastSeen: userData['last_seen'] != null
          ? DateTime.tryParse(userData['last_seen'].toString())
          : null,
      nickname: map['nickname']?.toString(),
    );
  }

  /// The display label — nickname if set, otherwise display name.
  String get displayLabel => nickname?.isNotEmpty == true ? nickname! : displayName;
}

enum ContactRelationship {
  none,
  contact,
  requestSent,
  requestReceived,
}

class ContactRequest {
  final String id;
  final String senderId;
  final String receiverId;
  final String status;
  final UserSearchResult? sender;
  final UserSearchResult? receiver;

  ContactRequest({
    required this.id,
    required this.senderId,
    required this.receiverId,
    required this.status,
    this.sender,
    this.receiver,
  });

  factory ContactRequest.fromMap(Map<String, dynamic> map) {
    return ContactRequest(
      id: map['id'],
      senderId: map['sender_user_id'],
      receiverId: map['receiver_user_id'],
      status: map['status'],
      sender: map['sender'] != null ? UserSearchResult.fromMap(map['sender']) : null,
      receiver: map['receiver'] != null ? UserSearchResult.fromMap(map['receiver']) : null,
    );
  }
}

/// Search result from Supabase user directory.
class UserSearchResult {
  final String userId;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final bool isOnline;
  final ContactRelationship relationship;
  final String? requestId;

  const UserSearchResult({
    required this.userId,
    required this.username,
    required this.displayName,
    this.avatarUrl,
    this.isOnline = false,
    this.relationship = ContactRelationship.none,
    this.requestId,
  });

  factory UserSearchResult.fromMap(
    Map<String, dynamic> map, {
    ContactRelationship relationship = ContactRelationship.none,
    String? requestId,
  }) {
    return UserSearchResult(
      userId: map['user_id']?.toString() ?? '',
      username: map['username']?.toString() ?? '',
      displayName: map['display_name']?.toString() ?? '',
      avatarUrl: null, // Removed from schema
      isOnline: map['status'] == 'online',
      relationship: relationship,
      requestId: requestId,
    );
  }
}

/// Manages the user's contact list and search functionality.
class ContactsProvider extends ChangeNotifier {
  final SupabaseDirectoryService _directoryService;
  final LocalStorage _localStorage;

  List<Contact> _contacts = [];
  List<UserSearchResult> _searchResults = [];
  List<ContactRequest> _sentRequests = [];
  List<ContactRequest> _receivedRequests = [];

  bool _isLoading = false;
  bool _isSearching = false;
  String? _errorMessage;
  Timer? _searchDebounce;

  ContactsProvider({
    required SupabaseDirectoryService directoryService,
    required LocalStorage localStorage,
  })  : _directoryService = directoryService,
        _localStorage = localStorage;

  StreamSubscription? _requestsSub;
  final _newRequestController = StreamController<String>.broadcast();
  Stream<String> get onNewRequest => _newRequestController.stream;

  void init() {
    _requestsSub?.cancel();
    _requestsSub = _directoryService.listenForContactRequests().listen((event) {
      loadContacts(); // reload to get the joined sender profile
      _newRequestController.add('You have a new contact request!');
    });
  }

  // -- Getters --
  List<Contact> get contacts => List.unmodifiable(_contacts);
  List<UserSearchResult> get searchResults => List.unmodifiable(_searchResults);
  List<ContactRequest> get sentRequests => List.unmodifiable(_sentRequests);
  List<ContactRequest> get receivedRequests => List.unmodifiable(_receivedRequests);
  
  bool get isLoading => _isLoading;
  bool get isSearching => _isSearching;
  String? get errorMessage => _errorMessage;
  int get contactCount => _contacts.length;
  int get onlineCount => _contacts.where((c) => c.isOnline).length;

  /// Load contacts from Supabase.
  Future<void> loadContacts() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final contactsData = await _directoryService.getContacts();
      _contacts = contactsData.map((data) => Contact.fromMap(data)).toList();

      // Sort: online first, then alphabetical
      _contacts.sort((a, b) {
        if (a.isOnline != b.isOnline) {
          return a.isOnline ? -1 : 1;
        }
        return a.displayLabel.toLowerCase().compareTo(b.displayLabel.toLowerCase());
      });

      // Cache contacts locally
      for (final contact in _contacts) {
        await _localStorage.cacheContact(
          userId: contact.userId,
          username: contact.username,
          displayName: contact.displayName,
          avatarUrl: contact.avatarUrl,
          publicSigningKey: contact.publicSigningKey,
          publicEncryptionKey: contact.publicEncryptionKey,
          isOnline: contact.isOnline,
          lastSeen: contact.lastSeen?.millisecondsSinceEpoch,
        );
      }

      // Load pending requests
      final reqData = await _directoryService.fetchPendingRequests();
      final allRequests = reqData.map((r) => ContactRequest.fromMap(r)).toList();
      
      final myUserId = await _directoryService.getMyUserId();
      _sentRequests = allRequests.where((r) => r.senderId == myUserId).toList();
      _receivedRequests = allRequests.where((r) => r.receiverId == myUserId).toList();
      
    } catch (e) {
      _errorMessage = 'Failed to load contacts: $e';
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Search users by username with debounce.
  void searchUsers(String query) {
    _searchDebounce?.cancel();

    if (query.trim().isEmpty) {
      _searchResults = [];
      _isSearching = false;
      notifyListeners();
      return;
    }

    _isSearching = true;
    notifyListeners();

    _searchDebounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final results = await _directoryService.searchUsers(query.trim());
        final contactIds = _contacts.map((c) => c.userId).toSet();
        final currentAuthId = _directoryService.currentUser?.id;

        _searchResults = results
            .where((r) => r['auth_id'].toString() != currentAuthId) // Exclude self
            .map((r) {
              final userId = r['user_id'].toString();
              
              ContactRelationship relationship = ContactRelationship.none;
              String? requestId;
              
              if (contactIds.contains(userId)) {
                relationship = ContactRelationship.contact;
              } else {
                final sent = _sentRequests.where((req) => req.receiverId == userId).toList();
                final received = _receivedRequests.where((req) => req.senderId == userId).toList();
                
                if (sent.isNotEmpty) {
                  relationship = ContactRelationship.requestSent;
                  requestId = sent.first.id;
                } else if (received.isNotEmpty) {
                  relationship = ContactRelationship.requestReceived;
                  requestId = received.first.id;
                }
              }

              return UserSearchResult.fromMap(
                r,
                relationship: relationship,
                requestId: requestId,
              );
            })
            .toList();
      } catch (e) {
        _errorMessage = 'Search failed: $e';
        debugPrint('Search failed: $e');
        _searchResults = [];
      }

      _isSearching = false;
      notifyListeners();
    });
  }

  /// Clear search results.
  void clearSearch() {
    _searchResults = [];
    _isSearching = false;
    _searchDebounce?.cancel();
    notifyListeners();
  }

  /// Add a user as a contact (legacy behavior, you may remove this if unneeded).
  Future<bool> addContact(String contactUserId, {String? nickname}) async {
    _errorMessage = null;

    try {
      await _directoryService.addContact(contactUserId, nickname: nickname);
      await loadContacts(); // Refresh the contact list
      return true;
    } catch (e) {
      _errorMessage = 'Failed to add contact: $e';
      notifyListeners();
      return false;
    }
  }

  /// Send a contact request to a user.
  Future<bool> sendContactRequest(String receiverUserId) async {
    _errorMessage = null;
    try {
      await _directoryService.sendContactRequest(receiverUserId);
      await loadContacts(); // refresh lists
      return true;
    } catch (e) {
      _errorMessage = 'Failed to send request: $e';
      notifyListeners();
      return false;
    }
  }

  /// Accept an incoming contact request.
  Future<bool> acceptContactRequest(String requestId) async {
    _errorMessage = null;
    try {
      await _directoryService.acceptContactRequest(requestId);
      await loadContacts(); // refresh lists
      return true;
    } catch (e) {
      _errorMessage = 'Failed to accept request: $e';
      notifyListeners();
      return false;
    }
  }

  /// Reject an incoming contact request.
  Future<bool> rejectContactRequest(String requestId) async {
    _errorMessage = null;
    try {
      await _directoryService.rejectContactRequest(requestId);
      await loadContacts(); // refresh lists
      return true;
    } catch (e) {
      _errorMessage = 'Failed to reject request: $e';
      notifyListeners();
      return false;
    }
  }

  /// Remove a contact.
  Future<bool> removeContact(String contactUserId) async {
    _errorMessage = null;

    try {
      await _directoryService.removeContact(contactUserId);
      _contacts.removeWhere((c) => c.userId == contactUserId);
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = 'Failed to remove contact: $e';
      notifyListeners();
      return false;
    }
  }

  /// Get a contact by user ID.
  Contact? getContact(String userId) {
    try {
      return _contacts.firstWhere((c) => c.userId == userId);
    } catch (_) {
      return null;
    }
  }

  /// Check if a username is available.
  Future<bool> isUsernameAvailable(String username) async {
    try {
      return await _directoryService.isUsernameAvailable(username);
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _requestsSub?.cancel();
    _newRequestController.close();
    super.dispose();
  }
}
