import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show ConflictAlgorithm, Database, DatabaseFactory, OpenDatabaseOptions;
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;

import 'package:securelyhello/core/crypto/crypto_core.dart';

/// Local SQLite storage for messages, conversations and cached contacts.
///
/// * One database file per account (`securelyhello_<userId>.db`), so several
///   accounts on one device never share history.
/// * On Linux / Windows the database goes through `sqflite_common_ffi`, and
///   lives in the application-support directory. A launch profile
///   (`SH_PROFILE`, see `AppConfig`) gets its own sub-directory.
/// * Message bodies and conversation previews are encrypted at rest with a
///   per-account key held in the platform keystore (see `SecureKeyStore`).
/// * Private identity keys are **not** stored here any more; they live in the
///   keystore.  [takeLegacyIdentity] migrates them out of old databases.
///
/// **Nothing stored here ever leaves the device.**
class LocalStorage {
  static const _legacyDbName = 'securelyhello.db';
  static const _dbVersion = 2;
  static const _sealedPrefix = 'enc1:';

  final DatabaseFactory _factory;
  final Future<String> Function() _baseDir;

  Database? _db;
  Uint8List? _key;
  String? _authId;

  /// [databaseFactory] and [baseDirectory] are injectable for tests; by
  /// default the platform's SQLite and app directory are used. [profile]
  /// namespaces the directory (two app instances on one machine).
  LocalStorage({
    DatabaseFactory? databaseFactory,
    Future<String> Function()? baseDirectory,
    String profile = '',
  })  : _factory = databaseFactory ?? _defaultFactory(),
        _baseDir = baseDirectory ?? (() => _defaultBaseDir(profile));

  static bool get _isDesktopFfi => Platform.isLinux || Platform.isWindows;

  static DatabaseFactory _defaultFactory() {
    if (_isDesktopFfi) {
      sqfliteFfiInit();
      return databaseFactoryFfi;
    }
    return sqflite.databaseFactory;
  }

  static Future<String> _defaultBaseDir(String profile) async {
    // Mobile keeps the documents directory used by earlier releases so
    // existing databases are found; desktop uses the app-support directory
    // instead of the user's visible ~/Documents.
    final root = (Platform.isAndroid || Platform.isIOS)
        ? await getApplicationDocumentsDirectory()
        : await getApplicationSupportDirectory();
    final dir = profile.isEmpty
        ? root.path
        : p.join(root.path, 'profiles', profile);
    await Directory(dir).create(recursive: true);
    return dir;
  }

  /// The underlying database instance. Throws if no account is open.
  Database get db {
    final database = _db;
    if (database == null) {
      throw StateError('LocalStorage.openForUser() has not been called');
    }
    return database;
  }

  bool get isOpen => _db != null;

  /// The auth id whose database is currently open.
  String? get openAuthId => _authId;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<String> _pathFor(String fileName) async =>
      p.join(await _baseDir(), fileName);

  static String _fileNameFor(String authId) => 'securelyhello_$authId.db';

  /// Opens (or creates) the database for [authId].
  ///
  /// If this account has no database yet but a pre-multi-account
  /// `securelyhello.db` exists, it is adopted when [adoptLegacyIf] confirms
  /// that its stored identity belongs to this account.
  Future<void> openForUser(
    String authId, {
    required Uint8List encryptionKey,
    Future<bool> Function(CryptoIdentity legacyIdentity)? adoptLegacyIf,
  }) async {
    if (_db != null && _authId == authId) return;
    await close();

    final path = await _pathFor(_fileNameFor(authId));
    if (!File(path).existsSync() && adoptLegacyIf != null) {
      await _maybeAdoptLegacy(path, adoptLegacyIf);
    }

    _key = encryptionKey;
    _authId = authId;
    _db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _dbVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  Future<void> _maybeAdoptLegacy(
    String newPath,
    Future<bool> Function(CryptoIdentity) adoptLegacyIf,
  ) async {
    final legacyPath = await _pathFor(_legacyDbName);
    if (!File(legacyPath).existsSync()) return;

    CryptoIdentity? legacyIdentity;
    final legacy = await _factory.openDatabase(legacyPath);
    try {
      legacyIdentity = await _readIdentityRows(legacy);
    } finally {
      await legacy.close();
    }
    if (legacyIdentity == null || !await adoptLegacyIf(legacyIdentity)) return;

    for (final suffix in ['', '-journal', '-wal', '-shm']) {
      final f = File('$legacyPath$suffix');
      if (f.existsSync()) await f.rename('$newPath$suffix');
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();

    batch.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id              TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        sender_id       TEXT NOT NULL,
        content         TEXT NOT NULL,
        timestamp       INTEGER NOT NULL,
        status          TEXT NOT NULL DEFAULT 'sending',
        is_from_me      INTEGER NOT NULL DEFAULT 0,
        kind            TEXT NOT NULL DEFAULT 'text'
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
      CREATE TABLE IF NOT EXISTS contacts_cache (
        user_id               TEXT PRIMARY KEY,
        username              TEXT,
        display_name          TEXT,
        avatar_url            TEXT,
        public_signing_key    TEXT,
        public_encryption_key TEXT,
        is_online             INTEGER NOT NULL DEFAULT 0,
        last_seen             INTEGER
      )
    ''');

    await batch.commit(noResult: true);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.transaction((txn) async {
        await txn.execute(
            "ALTER TABLE messages ADD COLUMN kind TEXT NOT NULL DEFAULT 'text'");

        // v1 keyed conversations by "<userA>_<userB>" while the UI used the
        // contact's user id.  Collapse everything onto the contact id.
        final convs = await txn.query('conversations');
        final merged = <String, Map<String, dynamic>>{};
        for (final c in convs) {
          final contactId = c['contact_user_id'] as String;
          final oldId = c['id'] as String;
          if (oldId != contactId) {
            await txn.update('messages', {'conversation_id': contactId},
                where: 'conversation_id = ?', whereArgs: [oldId]);
          }
          final prev = merged[contactId];
          final time = c['last_message_time'] as int? ?? 0;
          final prevTime = prev?['last_message_time'] as int? ?? -1;
          merged[contactId] = {
            'id': contactId,
            'contact_user_id': contactId,
            'last_message':
                time >= prevTime ? c['last_message'] : prev!['last_message'],
            'last_message_time': time >= prevTime ? time : prevTime,
            'unread_count': (c['unread_count'] as int? ?? 0) +
                (prev?['unread_count'] as int? ?? 0),
          };
        }
        await txn.delete('conversations');
        for (final row in merged.values) {
          await txn.insert('conversations', row);
        }

        // Encrypt plaintext left over from v1.
        final msgs = await txn.query('messages', columns: ['id', 'content']);
        for (final m in msgs) {
          await txn.update('messages', {'content': _seal(m['content'] as String)},
              where: 'id = ?', whereArgs: [m['id']]);
        }
        for (final row in merged.values) {
          final last = row['last_message'] as String?;
          if (last != null) {
            await txn.update('conversations', {'last_message': _seal(last)},
                where: 'id = ?', whereArgs: [row['id']]);
          }
        }
      });
    }
  }

  /// Closes the database.  Safe to call multiple times.
  Future<void> close() async {
    await _db?.close();
    _db = null;
    _key = null;
    _authId = null;
  }

  /// Closes and permanently deletes [authId]'s database file.
  Future<void> deleteDatabaseForUser(String authId) async {
    if (_authId == authId) await close();
    await _factory.deleteDatabase(await _pathFor(_fileNameFor(authId)));
  }

  // ---------------------------------------------------------------------------
  // At-rest encryption helpers
  // ---------------------------------------------------------------------------

  String _seal(String plaintext) {
    if (plaintext.startsWith(_sealedPrefix)) return plaintext;
    final key = _key!;
    final sealed = CryptoCore.secretEncrypt(
        Uint8List.fromList(utf8.encode(plaintext)), key);
    return '$_sealedPrefix${CryptoCore.toBase64(sealed)}';
  }

  String _unseal(String stored) {
    if (!stored.startsWith(_sealedPrefix)) return stored;
    try {
      final data = CryptoCore.fromBase64(stored.substring(_sealedPrefix.length));
      return utf8.decode(CryptoCore.secretDecrypt(data, _key!));
    } catch (_) {
      return '[unreadable message]';
    }
  }

  Map<String, dynamic> _unsealMessage(Map<String, dynamic> row) =>
      {...row, 'content': _unseal(row['content'] as String)};

  Map<String, dynamic> _unsealConversation(Map<String, dynamic> row) {
    final last = row['last_message'] as String?;
    return {...row, 'last_message': last == null ? null : _unseal(last)};
  }

  // ---------------------------------------------------------------------------
  // Legacy identity migration
  // ---------------------------------------------------------------------------

  static Future<CryptoIdentity?> _readIdentityRows(Database db) async {
    final tables = await db.query('sqlite_master',
        where: 'type = ? AND name = ?', whereArgs: ['table', 'identity_keys']);
    if (tables.isEmpty) return null;

    final rows = await db.query('identity_keys');
    if (rows.isEmpty) return null;
    final map = <String, String?>{
      for (final row in rows) row['key'] as String: row['value'] as String?,
    };
    return CryptoIdentity.fromMap(map);
  }

  /// Returns an identity left in the old plaintext `identity_keys` table and
  /// deletes it from disk.  The caller must move it to the keystore.
  Future<CryptoIdentity?> takeLegacyIdentity() async {
    final identity = await _readIdentityRows(db);
    if (identity != null) {
      await db.execute('DROP TABLE identity_keys');
    }
    return identity;
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
    String kind = 'text',
  }) async {
    await db.insert(
      'messages',
      {
        'id': id,
        'conversation_id': conversationId,
        'sender_id': senderId,
        'content': _seal(content),
        'timestamp': timestamp,
        'status': status,
        'is_from_me': isFromMe ? 1 : 0,
        'kind': kind,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Inserts a local-only notice (e.g. "safety number changed").
  Future<void> insertSystemMessage(
    String conversationId,
    String text, {
    required String id,
  }) =>
      insertMessage(
        id: id,
        conversationId: conversationId,
        senderId: 'system',
        content: text,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        status: 'read',
        isFromMe: false,
        kind: 'system',
      );

  Future<bool> messageExists(String messageId) async {
    final rows = await db.query('messages',
        columns: ['id'], where: 'id = ?', whereArgs: [messageId], limit: 1);
    return rows.isNotEmpty;
  }

  /// Returns a single decrypted message row, or `null`.
  Future<Map<String, dynamic>?> getMessage(String messageId) async {
    final rows = await db.query('messages',
        where: 'id = ?', whereArgs: [messageId], limit: 1);
    return rows.isEmpty ? null : _unsealMessage(rows.first);
  }

  /// Returns messages for [conversationId], newest first.
  ///
  /// Pass [limit] and [offset] for pagination.
  Future<List<Map<String, dynamic>>> getMessages(
    String conversationId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final rows = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_unsealMessage).toList();
  }

  /// Outgoing messages that never reached the peer or the relay.
  Future<List<Map<String, dynamic>>> getUnsentMessages() async {
    final rows = await db.query(
      'messages',
      where: "is_from_me = 1 AND status IN ('failed', 'sending')",
      orderBy: 'timestamp ASC',
    );
    return rows.map(_unsealMessage).toList();
  }

  /// Outgoing messages to [conversationId] newer than [sinceMs] that left
  /// the device but were never acknowledged by the recipient.
  Future<List<Map<String, dynamic>>> getSentUnconfirmed(
      String conversationId, int sinceMs) async {
    final rows = await db.query(
      'messages',
      where: "conversation_id = ? AND is_from_me = 1 AND status = 'sent' "
          'AND timestamp >= ?',
      whereArgs: [conversationId, sinceMs],
      orderBy: 'timestamp ASC',
    );
    return rows.map(_unsealMessage).toList();
  }

  /// Ids of incoming messages in [conversationId] we haven't acknowledged as
  /// read yet.
  Future<List<String>> getUnreadIncomingIds(String conversationId) async {
    final rows = await db.query(
      'messages',
      columns: ['id'],
      where: "conversation_id = ? AND is_from_me = 0 AND kind = 'text' "
          "AND status != 'read'",
      whereArgs: [conversationId],
    );
    return rows.map((r) => r['id'] as String).toList();
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

  /// Marks a batch of incoming messages as read.
  Future<void> markIncomingRead(List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    final placeholders = List.filled(messageIds.length, '?').join(',');
    await db.rawUpdate(
      "UPDATE messages SET status = 'read' WHERE id IN ($placeholders)",
      messageIds,
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
    final rows = await db.query(
      'conversations',
      orderBy: 'last_message_time DESC',
    );
    return rows.map(_unsealConversation).toList();
  }

  /// Returns a single conversation by its ID, or `null`.
  Future<Map<String, dynamic>?> getConversation(String conversationId) async {
    final rows = await db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [conversationId],
      limit: 1,
    );
    return rows.isEmpty ? null : _unsealConversation(rows.first);
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
        'last_message': lastMessage == null ? null : _seal(lastMessage),
        'last_message_time': lastMessageTime,
        'unread_count': unreadCount ?? 0,
      });
    } else {
      final updates = <String, dynamic>{};
      if (lastMessage != null) updates['last_message'] = _seal(lastMessage);
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

  /// Removes all messages but keeps the conversation entry.
  Future<void> clearConversation(String conversationId) async {
    final batch = db.batch();
    batch.delete('messages',
        where: 'conversation_id = ?', whereArgs: [conversationId]);
    batch.update(
        'conversations', {'last_message': null, 'unread_count': 0},
        where: 'id = ?', whereArgs: [conversationId]);
    await batch.commit(noResult: true);
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
  // Contact cache
  // ---------------------------------------------------------------------------

  /// Caches a user's public profile locally for offline access and fast
  /// encryption-key lookup.
  ///
  /// Returns `true` when previously cached, non-empty public keys were
  /// replaced by different ones — i.e. the contact's safety number changed.
  Future<bool> cacheContact({
    required String userId,
    String? username,
    String? displayName,
    String? avatarUrl,
    String? publicSigningKey,
    String? publicEncryptionKey,
    bool isOnline = false,
    int? lastSeen,
  }) async {
    final previous = await getCachedContact(userId);
    final prevEnc = previous?['public_encryption_key'] as String?;
    final prevSig = previous?['public_signing_key'] as String?;
    final keysChanged = prevEnc != null &&
        prevEnc.isNotEmpty &&
        publicEncryptionKey != null &&
        publicEncryptionKey.isNotEmpty &&
        (prevEnc != publicEncryptionKey || prevSig != publicSigningKey);

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
    return keysChanged;
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

  /// Wipes the entire contact cache.
  Future<void> clearContactsCache() async {
    await db.delete('contacts_cache');
  }
}
