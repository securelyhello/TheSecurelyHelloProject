import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:securelyhello/core/crypto/crypto_core.dart';

/// Local SQLite storage for messages, conversations, cached contacts, and
/// cryptographic identity keys.
///
/// **Nothing stored here ever leaves the device.**  Supabase only receives
/// public keys — see [SupabaseDirectoryService].
class LocalStorage {
  static const _dbName = 'securelyhello.db';
  static const _dbVersion = 1;

  Database? _db;

  /// The underlying database instance. Throws if [init] hasn't been called.
  Database get db {
    final database = _db;
    if (database == null) {
      throw StateError('LocalStorage.init() has not been called');
    }
    return database;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Opens (or creates) the local database and ensures all tables exist.
  Future<void> init() async {
    if (_db != null) return;

    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);

    _db = await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();

    batch.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id             TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        sender_id      TEXT NOT NULL,
        content        TEXT NOT NULL,
        timestamp      INTEGER NOT NULL,
        status         TEXT NOT NULL DEFAULT 'sending',
        is_from_me     INTEGER NOT NULL DEFAULT 0
      )
    ''');

    batch.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_conversation
        ON messages(conversation_id, timestamp DESC)
    ''');

    batch.execute('''
      CREATE TABLE IF NOT EXISTS conversations (
        id                TEXT PRIMARY KEY,
        contact_user_id   TEXT NOT NULL,
        last_message      TEXT,
        last_message_time INTEGER,
        unread_count      INTEGER NOT NULL DEFAULT 0
      )
    ''');

    batch.execute('''
      CREATE TABLE IF NOT EXISTS identity_keys (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE IF NOT EXISTS contacts_cache (
        user_id             TEXT PRIMARY KEY,
        username            TEXT,
        display_name        TEXT,
        avatar_url          TEXT,
        public_signing_key  TEXT,
        public_encryption_key TEXT,
        is_online           INTEGER NOT NULL DEFAULT 0,
        last_seen           INTEGER
      )
    ''');

    await batch.commit(noResult: true);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Reserved for future schema migrations.
  }

  /// Closes the database.  Safe to call multiple times.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // ---------------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------------

  /// Inserts a new message row.
  Future<void> insertMessage({
    required String id,
    required String conversationId,
    required String senderId,
    required String content,
    required int timestamp,
    required String status,
    required bool isFromMe,
  }) async {
    await db.insert(
      'messages',
      {
        'id': id,
        'conversation_id': conversationId,
        'sender_id': senderId,
        'content': content,
        'timestamp': timestamp,
        'status': status,
        'is_from_me': isFromMe ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Returns messages for [conversationId], newest first.
  ///
  /// Pass [limit] and [offset] for pagination.
  Future<List<Map<String, dynamic>>> getMessages(
    String conversationId, {
    int limit = 50,
    int offset = 0,
  }) async {
    return db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
  }

  /// Updates the delivery status of a message.
  Future<void> updateMessageStatus(String messageId, String status) async {
    await db.update(
      'messages',
      {'status': status},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// Deletes a single message.
  Future<void> deleteMessage(String messageId) async {
    await db.delete('messages', where: 'id = ?', whereArgs: [messageId]);
  }

  /// Deletes all messages in a conversation.
  Future<void> deleteMessagesForConversation(String conversationId) async {
    await db.delete(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
  }

  // ---------------------------------------------------------------------------
  // Conversations
  // ---------------------------------------------------------------------------

  /// Returns all conversations ordered by most-recent message.
  Future<List<Map<String, dynamic>>> getConversations() async {
    return db.query(
      'conversations',
      orderBy: 'last_message_time DESC',
    );
  }

  /// Returns a single conversation by its ID, or `null`.
  Future<Map<String, dynamic>?> getConversation(String conversationId) async {
    final rows = await db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [conversationId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Creates or updates a conversation row.
  Future<void> updateConversation({
    required String id,
    required String contactUserId,
    String? lastMessage,
    int? lastMessageTime,
    int? unreadCount,
  }) async {
    final existing = await getConversation(id);

    if (existing == null) {
      await db.insert('conversations', {
        'id': id,
        'contact_user_id': contactUserId,
        'last_message': lastMessage,
        'last_message_time': lastMessageTime,
        'unread_count': unreadCount ?? 0,
      });
    } else {
      final updates = <String, dynamic>{};
      if (lastMessage != null) updates['last_message'] = lastMessage;
      if (lastMessageTime != null) {
        updates['last_message_time'] = lastMessageTime;
      }
      if (unreadCount != null) updates['unread_count'] = unreadCount;
      if (updates.isNotEmpty) {
        await db.update(
          'conversations',
          updates,
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    }
  }

  /// Increments the unread counter for a conversation.
  Future<void> incrementUnreadCount(String conversationId) async {
    await db.rawUpdate(
      'UPDATE conversations SET unread_count = unread_count + 1 WHERE id = ?',
      [conversationId],
    );
  }

  /// Resets the unread counter to zero.
  Future<void> clearUnreadCount(String conversationId) async {
    await db.update(
      'conversations',
      {'unread_count': 0},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  /// Deletes a conversation and all its messages.
  Future<void> deleteConversation(String conversationId) async {
    final batch = db.batch();
    batch.delete('messages',
        where: 'conversation_id = ?', whereArgs: [conversationId]);
    batch.delete('conversations',
        where: 'id = ?', whereArgs: [conversationId]);
    await batch.commit(noResult: true);
  }

  // ---------------------------------------------------------------------------
  // Identity keys  (PRIVATE — never sent to Supabase)
  // ---------------------------------------------------------------------------

  /// Persists a [CryptoIdentity] to the local database.
  Future<void> saveIdentity(CryptoIdentity identity) async {
    final map = identity.toMap();
    final batch = db.batch();
    for (final entry in map.entries) {
      batch.insert(
        'identity_keys',
        {'key': entry.key, 'value': entry.value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Loads the stored [CryptoIdentity], or returns `null` if none exists.
  Future<CryptoIdentity?> loadIdentity() async {
    final rows = await db.query('identity_keys');
    if (rows.isEmpty) return null;

    final map = <String, String?>{};
    for (final row in rows) {
      map[row['key'] as String] = row['value'] as String?;
    }
    return CryptoIdentity.fromMap(map);
  }

  /// Deletes all stored identity keys (used on account deletion).
  Future<void> clearIdentity() async {
    await db.delete('identity_keys');
  }

  // ---------------------------------------------------------------------------
  // Contact cache
  // ---------------------------------------------------------------------------

  /// Caches a user's public profile locally for offline access and fast
  /// encryption-key lookup.
  Future<void> cacheContact({
    required String userId,
    String? username,
    String? displayName,
    String? avatarUrl,
    String? publicSigningKey,
    String? publicEncryptionKey,
    bool isOnline = false,
    int? lastSeen,
  }) async {
    await db.insert(
      'contacts_cache',
      {
        'user_id': userId,
        'username': username,
        'display_name': displayName,
        'avatar_url': avatarUrl,
        'public_signing_key': publicSigningKey,
        'public_encryption_key': publicEncryptionKey,
        'is_online': isOnline ? 1 : 0,
        'last_seen': lastSeen,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Returns cached profile data for a single contact, or `null`.
  Future<Map<String, dynamic>?> getCachedContact(String userId) async {
    final rows = await db.query(
      'contacts_cache',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Returns all locally cached contacts.
  Future<List<Map<String, dynamic>>> getAllCachedContacts() async {
    return db.query('contacts_cache', orderBy: 'display_name ASC');
  }

  /// Removes a single contact from the cache.
  Future<void> removeCachedContact(String userId) async {
    await db.delete('contacts_cache',
        where: 'user_id = ?', whereArgs: [userId]);
  }

  /// Wipes the entire contact cache (e.g. on sign-out).
  Future<void> clearContactsCache() async {
    await db.delete('contacts_cache');
  }
}
