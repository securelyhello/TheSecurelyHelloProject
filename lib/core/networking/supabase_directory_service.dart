import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Bridges the app to Supabase for authentication, user directory lookup,
/// contact management, WebRTC signaling relay, and offline message relay.
///
/// **Security invariants enforced by the SQL schema + this class:**
/// * Private keys are never sent to Supabase.
/// * Message plaintext / ciphertext is never written to any Supabase table
///   (the relay queue stores NaCl-box-encrypted payloads only).
/// * All tables are protected by Row-Level Security policies.
class SupabaseDirectoryService {
  SupabaseClient get _client => Supabase.instance.client;

  // Active realtime channels — tracked so we can unsubscribe on dispose.
  final List<RealtimeChannel> _channels = [];
  
  // ===========================================================================
  // Auth
  // ===========================================================================

  /// Creates a new account with email + password.
  Future<AuthResponse> signUp(String email, String password) async {
    return _client.auth.signUp(email: email, password: password);
  }

  /// Signs in with email + password.
  Future<AuthResponse> signIn(String email, String password) async {
    final res = await _client.auth.signInWithPassword(email: email, password: password);
    _cachedUserId = null; // reset cache
    return res;
  }

  /// Signs the current user out.
  Future<void> signOut() async {
    _cachedUserId = null;
    await _client.auth.signOut();
  }

  /// Sends a password-reset email.
  Future<void> resetPassword(String email) async {
    await _client.auth.resetPasswordForEmail(email);
  }

  /// Calls the `delete_own_account()` RPC (SECURITY DEFINER) and signs out.
  Future<void> deleteAccount() async {
    await _client.rpc('delete_own_account');
    await _client.auth.signOut();
  }

  /// The currently authenticated [User], or `null`.
  User? get currentUser => _client.auth.currentUser;

  /// Reactive stream of authentication state changes.
  Stream<AuthState> get authStateChanges =>
      _client.auth.onAuthStateChange;

  // ===========================================================================
  // User directory
  // ===========================================================================

  /// Creates a public user profile row.  Call once after sign-up, passing
  /// the public keys from [CryptoIdentity.exportPublicKeys()].
  Future<void> createUserProfile({
    required String uid,
    required String username,
    required String displayName,
    String? avatarUrl, // Ignored since schema doesn't have it, kept for compat
    required String publicSigningKey,
    required String publicEncryptionKey,
  }) async {
    await _client.from('users').insert({
      'id': uid,
      'username': username,
      'display_name': displayName,
      'signing_public_key': publicSigningKey,
      'encryption_public_key': publicEncryptionKey,
    });
  }

  /// Looks up a user by their unique **username**.
  Future<Map<String, dynamic>?> getUserByUsername(String username) async {
    final rows = await _client
        .from('users')
        .select()
        .eq('username', username)
        .limit(1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Looks up a user by their **user_id**.
  Future<Map<String, dynamic>?> getUserById(String userId) async {
    final rows = await _client
        .from('users')
        .select()
        .eq('id', userId)
        .limit(1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Case-insensitive prefix search on the `username` column.
  Future<List<Map<String, dynamic>>> searchUsers(String query) async {
    final authId = _requireAuthId();
    return _client
        .from('users')
        .select()
        .ilike('username', '%$query%')
        .neq('id', authId)
        .limit(20);
  }

  /// Updates fields on the **current user's** profile.
  Future<void> updateProfile({
    String? displayName,
    String? avatarUrl, // Ignored
    String? username,
  }) async {
    final authId = _requireAuthId();
    final updates = <String, dynamic>{};
    if (displayName != null) updates['display_name'] = displayName;
    if (username != null) updates['username'] = username;
    if (updates.isEmpty) return;

    await _client.from('users').update(updates).eq('id', authId);
  }

  /// Sets the user's online presence and updates `last_seen`.
  Future<void> updateOnlineStatus(bool isOnline) async {
    final authId = _requireAuthId();
    await _client.from('users').update({
      'is_online': isOnline,
      'last_seen': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', authId);
  }

  /// Returns `true` if no other user has claimed [username].
  Future<bool> isUsernameAvailable(String username) async {
    final rows = await _client
        .from('users')
        .select('id')
        .eq('username', username)
        .limit(1);
    return rows.isEmpty;
  }

  // ===========================================================================
  // Contacts
  // ===========================================================================

  /// Adds [contactUserId] to the current user's contact list.
  Future<void> addContact(String contactUserId, {String? nickname}) async {
    final myUserId = _requireAuthId();
    await _client.from('contacts').insert({
      'user_id': myUserId,
      'contact_user_id': contactUserId,
      'nickname': nickname,
    });
  }

  /// Removes [contactUserId] from the current user's contact list.
  Future<void> removeContact(String contactUserId) async {
    final myUserId = _requireAuthId();
    await _client
        .from('contacts')
        .delete()
        .eq('user_id', myUserId)
        .eq('contact_user_id', contactUserId);
  }

  /// Returns the current user's contacts with joined user profile data.
  Future<List<Map<String, dynamic>>> getContacts() async {
    final myUserId = _requireAuthId();
    return _client
        .from('contacts')
        .select('*, users!contacts_contact_user_id_fkey(*)')
        .eq('user_id', myUserId)
        .order('created_at', ascending: true);
  }

  // ===========================================================================
  // Signaling (WebRTC SDP + ICE relay)
  // ===========================================================================

  /// Creates a new signaling session with an SDP offer.  Returns the
  /// server-generated session UUID.
  Future<String> createSignalingSession(
    String calleeId,
    String sdpOffer,
  ) async {
    final myUserId = _requireAuthId();
    final rows = await _client
        .from('signaling_sessions')
        .insert({
          'caller_id': myUserId,
          'callee_id': calleeId,
          'sdp_offer': sdpOffer,
          'status': 'pending',
        })
        .select('session_id');
    return rows.first['session_id'] as String;
  }

  /// Sets the SDP answer and marks the session as `answered`.
  Future<void> answerSignalingSession(
    String sessionId,
    String sdpAnswer,
  ) async {
    await _client.from('signaling_sessions').update({
      'sdp_answer': sdpAnswer,
      'status': 'answered',
    }).eq('id', sessionId);
  }

  /// Marks the signaling session as `completed`.
  Future<void> completeSignalingSession(String sessionId) async {
    await _client
        .from('signaling_sessions')
        .update({'status': 'completed'})
        .eq('id', sessionId);
  }

  /// Inserts a trickle-ICE candidate into the relay table.
  Future<void> sendIceCandidate(
    String sessionId,
    String targetUserId,
    Map<String, dynamic> candidate,
  ) async {
    final myUserId = _requireAuthId();
    await _client.from('ice_candidates').insert({
      'session_id': sessionId,
      'sender_id': myUserId,
      'target_user_id': targetUserId,
      'candidate': candidate,
    });
  }

  /// Listens (via Supabase Realtime) for **new** signaling sessions where the
  /// current user is the callee and the status is `pending`.
  Stream<Map<String, dynamic>> listenForSignalingSessions() async* {
    final myUserId = _requireAuthId();
    final controller = StreamController<Map<String, dynamic>>();

    final channel = _client
        .channel('signaling_$myUserId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'signaling_sessions',
          callback: (payload) {
            final newRow = payload.newRecord;
            if (newRow.isNotEmpty) {
              controller.add(newRow);
            }
          },
        )
        .subscribe();

    _channels.add(channel);

    controller.onCancel = () {
      _client.removeChannel(channel);
      _channels.remove(channel);
    };

    yield* controller.stream;
  }

  /// Listens for new ICE candidates in a particular signaling session.
  Stream<Map<String, dynamic>> listenForIceCandidates(String sessionId) async* {
    final myUserId = _requireAuthId();
    final controller = StreamController<Map<String, dynamic>>();

    final channel = _client
        .channel('ice_${sessionId}_$myUserId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'ice_candidates',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'session_id',
            value: sessionId,
          ),
          callback: (payload) {
            final row = payload.newRecord;
            // Only forward candidates not from us.
            if (row['sender_id'] != myUserId) {
              controller.add(row);
            }
          },
        )
        .subscribe();

    _channels.add(channel);

    controller.onCancel = () {
      _client.removeChannel(channel);
      _channels.remove(channel);
    };

    yield* controller.stream;
  }

  /// Deletes the signaling session and its associated ICE candidates.
  Future<void> cleanupSignaling(String sessionId) async {
    await _client
        .from('ice_candidates')
        .delete()
        .eq('session_id', sessionId);
    await _client
        .from('signaling_sessions')
        .delete()
        .eq('id', sessionId);
  }

  // ===========================================================================
  // Relay queue (encrypted offline messages)
  // ===========================================================================

  /// Enqueues an encrypted message for a recipient who is offline.
  Future<void> queueRelayMessage(
    String recipientId,
    String encryptedPayload,
  ) async {
    final myUserId = _requireAuthId();
    await _client.from('relay_queue').insert({
      'sender_id': myUserId,
      'recipient_id': recipientId,
      'encrypted_payload': encryptedPayload,
    });
  }

  /// Fetches all pending relay messages addressed to the current user,
  /// ordered oldest-first.
  Future<List<Map<String, dynamic>>> fetchRelayMessages() async {
    final myUserId = _requireAuthId();
    return _client
        .from('relay_queue')
        .select()
        .eq('recipient_id', myUserId)
        .order('created_at', ascending: true);
  }

  /// Deletes a relay message after it has been decrypted and stored locally.
  Future<void> deleteRelayMessage(String messageId) async {
    await _client.from('relay_queue').delete().eq('id', messageId);
  }

  // ===========================================================================
  // Dispose
  // ===========================================================================

  /// Removes all Supabase Realtime channel subscriptions.
  void dispose() {
    for (final channel in _channels) {
      _client.removeChannel(channel);
    }
    _channels.clear();
  }

  // ===========================================================================
  // Helpers
  // ===========================================================================

  /// Returns the current user's Auth UUID or throws if unauthenticated.
  String _requireAuthId() {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('SupabaseDirectoryService: No authenticated user');
    }
    return user.id;
  }
}
