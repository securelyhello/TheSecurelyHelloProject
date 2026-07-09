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
      userId: userData['id']?.toString() ?? map['contact_user_id']?.toString() ?? '',
      username: userData['username']?.toString() ?? '',
      displayName: userData['display_name']?.toString() ?? '',
      avatarUrl: null, // Removed from schema
      publicSigningKey: userData['public_signing_key']?.toString() ?? '',
      publicEncryptionKey: userData['public_encryption_key']?.toString() ?? '',
      isOnline: userData['is_online'] == true,
      lastSeen: userData['last_seen'] != null
          ? DateTime.tryParse(userData['last_seen'].toString())
          : null,
      nickname: map['nickname']?.toString(),
    );
  }

  /// The display label — nickname if set, otherwise display name.
  String get displayLabel => nickname?.isNotEmpty == true ? nickname! : displayName;
}

/// Search result from Supabase user directory.
class UserSearchResult {
  final String userId;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final bool isOnline;
  final bool isAlreadyContact;

  const UserSearchResult({
    required this.userId,
    required this.username,
    required this.displayName,
    this.avatarUrl,
    this.isOnline = false,
    this.isAlreadyContact = false,
  });

  factory UserSearchResult.fromMap(
    Map<String, dynamic> map, {
    bool isAlreadyContact = false,
  }) {
    return UserSearchResult(
      userId: map['id']?.toString() ?? '',
      username: map['username']?.toString() ?? '',
      displayName: map['display_name']?.toString() ?? '',
      avatarUrl: null, // Removed from schema
      isOnline: map['is_online'] == true,
      isAlreadyContact: isAlreadyContact,
    );
  }
}

/// Manages the user's contact list and search functionality.
class ContactsProvider extends ChangeNotifier {
  final SupabaseDirectoryService _directoryService;
  final LocalStorage _localStorage;

  List<Contact> _contacts = [];
  List<UserSearchResult> _searchResults = [];
  bool _isLoading = false;
  bool _isSearching = false;
  String? _errorMessage;
  Timer? _searchDebounce;

  ContactsProvider({
    required SupabaseDirectoryService directoryService,
    required LocalStorage localStorage,
  })  : _directoryService = directoryService,
        _localStorage = localStorage;

  // -- Getters --
  List<Contact> get contacts => List.unmodifiable(_contacts);
  List<UserSearchResult> get searchResults => List.unmodifiable(_searchResults);
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
        final currentUserId = _directoryService.currentUser?.id;

        _searchResults = results
            .where((r) => r['id'].toString() != currentUserId) // Exclude self
            .map((r) => UserSearchResult.fromMap(
                  r,
                  isAlreadyContact: contactIds.contains(r['id'].toString()),
                ))
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

  /// Add a user as a contact.
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
    super.dispose();
  }
}
