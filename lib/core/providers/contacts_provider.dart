import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/storage/local_storage.dart';

/// Represents a contact with full profile data.
class Contact {
  final String userId;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final bool isOnline;
  final DateTime? lastSeen;
  final String? nickname;

  const Contact({
    required this.userId,
    required this.username,
    required this.displayName,
    this.avatarUrl,
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
      isOnline: userData['status'] == 'online',
      lastSeen: userData['last_seen'] != null
          ? DateTime.tryParse(userData['last_seen'].toString())
          : null,
      nickname: map['nickname']?.toString(),
    );
  }

  Contact withPresence({required bool isOnline, DateTime? lastSeen}) => Contact(
        userId: userId,
        username: username,
        displayName: displayName,
        avatarUrl: avatarUrl,
        isOnline: isOnline,
        lastSeen: lastSeen ?? this.lastSeen,
        nickname: nickname,
      );

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

/// Search result from the user directory.
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
  final DirectoryService _directoryService;
  final LocalStorage _localStorage;

  List<Contact> _contacts = [];
  List<UserSearchResult> _searchResults = [];
  List<ContactRequest> _sentRequests = [];
  List<ContactRequest> _receivedRequests = [];

  bool _isLoading = false;
  bool _isSearching = false;
  String? _errorMessage;
  Timer? _searchDebounce;
  String _lastSearch = '';

  ContactsProvider({
    required DirectoryService directoryService,
    required LocalStorage localStorage,
  })  : _directoryService = directoryService,
        _localStorage = localStorage;

  final List<StreamSubscription<dynamic>> _subs = [];
  String? _myUserId;
  bool _loading = false;
  bool _reloadQueued = false;
  final _newRequestController = StreamController<String>.broadcast();
  Stream<String> get onNewRequest => _newRequestController.stream;

  /// Subscribes to pushes from the server. Call after sign-in.
  void init() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs
      ..clear()
      ..add(_directoryService.contactEvents.listen(_onContactEvent))
      ..add(_directoryService.presenceEvents.listen(_onPresence))
      // After a reconnect, pick up whatever changed while we were away.
      ..add(_directoryService.realtimeState.listen((up) {
        if (up && _myUserId != null) loadContacts(silent: true);
      }));
  }

  Future<void> _onContactEvent(ContactEvent event) async {
    if (event.type == 'devices_changed') return; // ChatService handles it
    await loadContacts(silent: true);
    if (event.type == 'contact_request') {
      _newRequestController.add('You have a new contact request');
    } else if (event.type == 'contact_request_update' &&
        event.status == 'accepted') {
      _newRequestController.add('Your contact request was accepted');
    }
  }

  void _onPresence(PresenceEvent event) {
    final i = _contacts.indexWhere((c) => c.userId == event.userId);
    if (i < 0) return;
    if (_contacts[i].isOnline == event.online && event.lastSeen == null) return;
    _contacts[i] = _contacts[i]
        .withPresence(isOnline: event.online, lastSeen: event.lastSeen);
    _sortContacts();
    notifyListeners();
  }

  void _sortContacts() {
    _contacts.sort((a, b) {
      if (a.isOnline != b.isOnline) return a.isOnline ? -1 : 1;
      return a.displayLabel
          .toLowerCase()
          .compareTo(b.displayLabel.toLowerCase());
    });
  }

  /// Clears everything (sign-out).
  Future<void> reset() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _searchDebounce?.cancel();
    _myUserId = null;
    _contacts = [];
    _searchResults = [];
    _sentRequests = [];
    _receivedRequests = [];
    _errorMessage = null;
    _isLoading = false;
    _isSearching = false;
    notifyListeners();
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

  /// Load contacts and pending requests from the server.
  ///
  /// [silent] skips the loading flag (background refreshes after a push).
  Future<void> loadContacts({bool silent = false}) async {
    if (_loading) {
      _reloadQueued = true;
      return;
    }
    _loading = true;
    if (!silent) {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();
    }

    try {
      do {
        _reloadQueued = false;
        await _loadOnce();
      } while (_reloadQueued);
      if (silent) _errorMessage = null;
    } catch (e) {
      // A background refresh failing is not worth an error banner.
      if (!silent || _contacts.isEmpty) {
        _errorMessage = e is ApiException || e is NetworkException
            ? e.toString()
            : 'Failed to load contacts';
      }
      debugPrint('loadContacts failed: $e');
    }

    _loading = false;
    _isLoading = false;
    notifyListeners();
  }

  Future<void> _loadOnce() async {
    final myUserId = _directoryService.myUserId;
    final results = await Future.wait([
      _directoryService.getContacts(),
      _directoryService.fetchPendingRequests(),
    ]);
    // Signed out (or switched account) while the requests were in flight.
    if (_directoryService.myUserId != myUserId || myUserId == null) return;

    _contacts = results[0].map(Contact.fromMap).toList();
    _sortContacts();

    final allRequests = results[1].map(ContactRequest.fromMap).toList();
    _myUserId = myUserId;
    _sentRequests = allRequests.where((r) => r.senderId == myUserId).toList();
    _receivedRequests =
        allRequests.where((r) => r.receiverId == myUserId).toList();

    // Cache contacts locally (names for offline start and notices). Device
    // keys are tracked by ChatService, which flags safety-number changes.
    for (final contact in List.of(_contacts)) {
      if (!_localStorage.isOpen) break;
      await _localStorage.cacheContact(
        userId: contact.userId,
        username: contact.username,
        displayName: contact.displayName,
        avatarUrl: contact.avatarUrl,
        isOnline: contact.isOnline,
        lastSeen: contact.lastSeen?.millisecondsSinceEpoch,
      );
    }
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
    _errorMessage = null;
    notifyListeners();

    final term = query.trim();
    _lastSearch = term;
    _searchDebounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final results = await _directoryService.searchUsers(term);
        if (_lastSearch != term) return; // a newer search superseded this one
        final contactIds = _contacts.map((c) => c.userId).toSet();

        _searchResults = results
            .where((r) => r['user_id'] != _directoryService.myUserId)
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
        if (_lastSearch != term) return;
        _errorMessage = e is ApiException || e is NetworkException
            ? e.toString()
            : 'Search failed';
        debugPrint('Search failed: $e');
        _searchResults = [];
      }

      _isSearching = false;
      notifyListeners();
    });
  }

  /// Clear search results.
  void clearSearch() {
    _lastSearch = '';
    _searchResults = [];
    _isSearching = false;
    _searchDebounce?.cancel();
    notifyListeners();
  }

  /// Send a contact request to a user.
  Future<bool> sendContactRequest(String receiverUserId) async {
    _errorMessage = null;
    try {
      await _directoryService.sendContactRequest(receiverUserId);
      await loadContacts(silent: true);
      _refreshSearchRelationships();
      return true;
    } catch (e) {
      _errorMessage = _friendly(e, 'Failed to send request');
      notifyListeners();
      return false;
    }
  }

  /// Accept an incoming contact request.
  Future<bool> acceptContactRequest(String requestId) async {
    _errorMessage = null;
    try {
      await _directoryService.acceptContactRequest(requestId);
      await loadContacts(silent: true);
      _refreshSearchRelationships();
      return true;
    } catch (e) {
      _errorMessage = _friendly(e, 'Failed to accept request');
      notifyListeners();
      return false;
    }
  }

  /// Reject an incoming contact request.
  Future<bool> rejectContactRequest(String requestId) async {
    _errorMessage = null;
    try {
      await _directoryService.rejectContactRequest(requestId);
      await loadContacts(silent: true);
      _refreshSearchRelationships();
      return true;
    } catch (e) {
      _errorMessage = _friendly(e, 'Failed to reject request');
      notifyListeners();
      return false;
    }
  }

  /// Withdraw a pending request we sent.
  Future<bool> cancelContactRequest(String requestId) async {
    _errorMessage = null;
    try {
      await _directoryService.cancelContactRequest(requestId);
      await loadContacts(silent: true);
      _refreshSearchRelationships();
      return true;
    } catch (e) {
      _errorMessage = _friendly(e, 'Failed to cancel request');
      notifyListeners();
      return false;
    }
  }

  static String _friendly(Object e, String fallback) =>
      e is ApiException || e is NetworkException ? e.toString() : fallback;

  /// Re-derives each search result's relationship after the lists changed,
  /// so buttons flip from "Add" to "Requested" without a new search.
  void _refreshSearchRelationships() {
    if (_searchResults.isEmpty) return;
    final contactIds = _contacts.map((c) => c.userId).toSet();
    _searchResults = _searchResults.map((r) {
      var relationship = ContactRelationship.none;
      String? requestId;
      if (contactIds.contains(r.userId)) {
        relationship = ContactRelationship.contact;
      } else {
        final sent = _sentRequests.where((q) => q.receiverId == r.userId);
        final received = _receivedRequests.where((q) => q.senderId == r.userId);
        if (sent.isNotEmpty) {
          relationship = ContactRelationship.requestSent;
          requestId = sent.first.id;
        } else if (received.isNotEmpty) {
          relationship = ContactRelationship.requestReceived;
          requestId = received.first.id;
        }
      }
      return UserSearchResult(
        userId: r.userId,
        username: r.username,
        displayName: r.displayName,
        avatarUrl: r.avatarUrl,
        isOnline: r.isOnline,
        relationship: relationship,
        requestId: requestId,
      );
    }).toList();
    notifyListeners();
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
      _errorMessage = _friendly(e, 'Failed to remove contact');
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
    for (final s in _subs) {
      s.cancel();
    }
    _newRequestController.close();
    super.dispose();
  }
}
