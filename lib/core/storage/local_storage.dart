import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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
  static const _dbVersion = 6;
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

  // Lifecycle

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
    await _createV3(db);
    await _createV4(db);
    await _createV5(db);
    await _createV6(db);
  }

  /// Group chats: who has received and read each of our group messages.
  static Future<void> _createV6(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_receipts (
        message_id TEXT NOT NULL,
        user_id    TEXT NOT NULL,
        status     TEXT NOT NULL,
        PRIMARY KEY (message_id, user_id)
      )
    ''');
  }

  /// Disappearing messages.
  static Future<void> _createV5(Database db) async {
    final batch = db.batch()
      ..execute('ALTER TABLE conversations ADD COLUMN disappear_after INTEGER NOT NULL DEFAULT 0')
      ..execute('ALTER TABLE messages ADD COLUMN expires_at INTEGER')
      ..execute('CREATE INDEX IF NOT EXISTS idx_messages_expiry ON messages(expires_at) '
          'WHERE expires_at IS NOT NULL');
    await batch.commit(noResult: true);
  }

  /// Replies, edits, deletions and reactions.
  static Future<void> _createV4(Database db) async {
    final batch = db.batch()
      ..execute('ALTER TABLE messages ADD COLUMN reply_to TEXT')
      ..execute('ALTER TABLE messages ADD COLUMN edited_at INTEGER')
      ..execute('ALTER TABLE messages ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0')
      ..execute('''
        CREATE TABLE IF NOT EXISTS reactions (
          message_id TEXT NOT NULL,
          reactor_id TEXT NOT NULL,
          emoji      TEXT NOT NULL,
          at         INTEGER NOT NULL,
          PRIMARY KEY (message_id, reactor_id)
        )
      ''');
    await batch.commit(noResult: true);
  }

  /// Protocol v3: per-device sessions, prekeys, device cache, attachments.
  static Future<void> _createV3(Database db) async {
    final batch = db.batch();
    batch.execute('''
      CREATE TABLE IF NOT EXISTS ratchet_sessions (
        address    TEXT PRIMARY KEY,
        record     TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    batch.execute('''
      CREATE TABLE IF NOT EXISTS local_prekeys (
        kind       TEXT NOT NULL,
        key_id     INTEGER NOT NULL,
        private    TEXT NOT NULL,
        public     TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (kind, key_id)
      )
    ''');
    batch.execute('''
      CREATE TABLE IF NOT EXISTS peer_devices (
        user_id      TEXT NOT NULL,
        device_id    TEXT NOT NULL,
        signing_key  TEXT NOT NULL,
        identity_key TEXT NOT NULL,
        PRIMARY KEY (user_id, device_id)
      )
    ''');
    batch.execute('''
      CREATE TABLE IF NOT EXISTS peer_device_lists (
        user_id    TEXT PRIMARY KEY,
        fetched_at INTEGER NOT NULL
      )
    ''');
    batch.execute('''
      CREATE TABLE IF NOT EXISTS seen_envelopes (
        id      TEXT PRIMARY KEY,
        seen_at INTEGER NOT NULL
      )
    ''');
    batch.execute('''
      CREATE TABLE IF NOT EXISTS kv (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    batch.execute('ALTER TABLE messages ADD COLUMN attachment TEXT');
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
    if (oldVersion < 3) {
      await _createV3(db);
      // Account-level keys are gone; peers are re-fetched as device lists.
      await db.update('contacts_cache',
          {'public_signing_key': null, 'public_encryption_key': null});
    }
    if (oldVersion < 4) await _createV4(db);
    if (oldVersion < 5) await _createV5(db);
    if (oldVersion < 6) await _createV6(db);
  }

  /// Closes the database.  Safe to call multiple times.
  /// Chats for a backup or a transfer to another device: decrypted rows of
  /// conversations, messages, reactions and contacts' profiles. Messages set
  /// to disappear and deleted ones are left out.
  Future<Map<String, dynamic>> exportHistory() async {
    final messages = await db.query('messages',
        where: 'expires_at IS NULL AND deleted = 0', orderBy: 'timestamp');
    final ids = {for (final m in messages) m['id'] as String};
    return {
      'conversations': [
        for (final c in await db.query('conversations'))
          {
            'id': c['id'],
            'contact_user_id': c['contact_user_id'],
            'last_message': c['last_message'] == null ? null : _unseal(c['last_message'] as String),
            'last_message_time': c['last_message_time'],
          }
      ],
      'messages': [
        for (final m in messages)
          {
            'id': m['id'],
            'conversation_id': m['conversation_id'],
            'sender_id': m['sender_id'],
            'content': _unseal(m['content'] as String),
            'timestamp': m['timestamp'],
            'status': m['status'],
            'is_from_me': m['is_from_me'],
            'kind': m['kind'],
            'attachment': m['attachment'] == null ? null : _unseal(m['attachment'] as String),
            'reply_to': m['reply_to'] == null ? null : _unseal(m['reply_to'] as String),
            'edited_at': m['edited_at'],
          }
      ],
      'reactions': [
        for (final r in await db.query('reactions'))
          if (ids.contains(r['message_id'])) r
      ],
      'profiles': {for (final e in await kvSealedByPrefix('profile:')) e.key: e.value},
      // Checked and merged by ChatService, which knows the group rules.
      'groups': {for (final e in await kvSealedByPrefix('group:')) e.key: e.value},
      'names': {for (final e in await kvSealedByPrefix('member:')) e.key: e.value},
    };
  }

  /// Merges [data] from [exportHistory]. Messages already here are kept as
  /// they are, so importing twice changes nothing. Returns how many
  /// messages were added. Throws [FormatException] for malformed data.
  Future<int> importHistory(Map<String, dynamic> data) async {
    var added = 0;
    String str(Object? v, String what) => v is String ? v : throw FormatException('Bad $what');
    String? optStr(Object? v) => v is String ? v : null;
    int integer(Object? v, String what) => v is int ? v : throw FormatException('Bad $what');
    await db.transaction((txn) async {
      for (final m in (data['messages'] as List? ?? const [])) {
        if (m is! Map) throw const FormatException('Bad message');
        final id = await txn.insert(
          'messages',
          {
            'id': str(m['id'], 'id'),
            'conversation_id': str(m['conversation_id'], 'conversation'),
            'sender_id': str(m['sender_id'], 'sender'),
            'content': _seal(str(m['content'], 'content')),
            'timestamp': integer(m['timestamp'], 'timestamp'),
            'status': optStr(m['status']) ?? 'received',
            'is_from_me': m['is_from_me'] == 1 ? 1 : 0,
            'kind': optStr(m['kind']) ?? 'text',
            'attachment': optStr(m['attachment']) == null ? null : _seal(m['attachment'] as String),
            'reply_to': optStr(m['reply_to']) == null ? null : _seal(m['reply_to'] as String),
            'edited_at': m['edited_at'] is int ? m['edited_at'] : null,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        if (id != 0) added++;
      }
      for (final r in (data['reactions'] as List? ?? const [])) {
        if (r is! Map) continue;
        await txn.insert(
          'reactions',
          {
            'message_id': str(r['message_id'], 'reaction'),
            'reactor_id': str(r['reactor_id'], 'reaction'),
            'emoji': str(r['emoji'], 'reaction'),
            'at': integer(r['at'], 'reaction'),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      for (final c in (data['conversations'] as List? ?? const [])) {
        if (c is! Map) continue;
        final id = str(c['id'], 'conversation');
        final time = c['last_message_time'] is int ? c['last_message_time'] as int : 0;
        final last = optStr(c['last_message']);
        final existing = await txn.query('conversations', where: 'id = ?', whereArgs: [id], limit: 1);
        if (existing.isEmpty) {
          await txn.insert('conversations', {
            'id': id,
            'contact_user_id': str(c['contact_user_id'], 'conversation'),
            'last_message': last == null ? null : _seal(last),
            'last_message_time': time,
            'unread_count': 0,
          });
        } else if ((existing.first['last_message_time'] as int? ?? 0) < time) {
          await txn.update('conversations', {'last_message': last == null ? null : _seal(last), 'last_message_time': time},
              where: 'id = ?', whereArgs: [id]);
        }
      }
    });
    final profiles = data['profiles'];
    if (profiles is Map) {
      for (final e in profiles.entries) {
        if (e.key is String && (e.key as String).startsWith('profile:') && e.value is String &&
            await kvGetSealed(e.key as String) == null) {
          await kvSetSealed(e.key as String, e.value as String);
        }
      }
    }
    return added;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
    _key = null;
    _authId = null;
  }

  /// Closes and permanently deletes [authId]'s database file and its
  /// attachment cache.
  Future<void> deleteDatabaseForUser(String authId) async {
    if (_authId == authId) await close();
    await _factory.deleteDatabase(await _pathFor(_fileNameFor(authId)));
    final cache = Directory(p.join(await _baseDir(), 'attachments', authId));
    if (cache.existsSync()) await cache.delete(recursive: true);
  }

  /// Where the open account's encrypted attachments are cached, or null.
  Future<String?> attachmentsDir() async {
    final id = _authId;
    if (id == null) return null;
    return p.join(await _baseDir(), 'attachments', id);
  }

  // At-rest encryption helpers

  String _seal(String plaintext) {
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

  Map<String, dynamic> _unsealMessage(Map<String, dynamic> row) {
    final att = row['attachment'] as String?;
    final reply = row['reply_to'] as String?;
    return {
      ...row,
      'content': _unseal(row['content'] as String),
      'attachment': att == null ? null : _unseal(att),
      'reply_to': reply == null ? null : _unseal(reply),
    };
  }

  Map<String, dynamic> _unsealConversation(Map<String, dynamic> row) {
    final last = row['last_message'] as String?;
    return {...row, 'last_message': last == null ? null : _unseal(last)};
  }

  // Legacy identity migration

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

  // Messages

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
    String? attachment,
    String? replyTo,
    int? expiresAt,
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
        'attachment': attachment == null ? null : _seal(attachment),
        'reply_to': replyTo == null ? null : _seal(replyTo),
        'expires_at': expiresAt,
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
      where: "is_from_me = 1 AND deleted = 0 AND status IN ('failed', 'sending')",
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
      where: "conversation_id = ? AND is_from_me = 1 AND deleted = 0 "
          "AND status = 'sent' AND timestamp >= ?",
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

  /// Marks every incoming message in [conversationId] at or before
  /// [timestampMs] as read (read on another of our devices).
  Future<void> markIncomingReadUpTo(String conversationId, int timestampMs) async {
    await db.rawUpdate(
      "UPDATE messages SET status = 'read' WHERE conversation_id = ? "
      "AND is_from_me = 0 AND kind = 'text' AND timestamp <= ?",
      [conversationId, timestampMs],
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

  // Conversations

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
    batch.delete('group_receipts',
        where: 'message_id IN (SELECT id FROM messages WHERE conversation_id = ?)', whereArgs: [conversationId]);
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
    batch.delete('group_receipts',
        where: 'message_id IN (SELECT id FROM messages WHERE conversation_id = ?)', whereArgs: [conversationId]);
    batch.delete('messages',
        where: 'conversation_id = ?', whereArgs: [conversationId]);
    batch.delete('conversations',
        where: 'id = ?', whereArgs: [conversationId]);
    await batch.commit(noResult: true);
  }

  // Contact cache

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

  /// Replaces a message's attachment metadata (e.g. once it is downloaded).
  Future<void> updateMessageAttachment(String messageId, String attachment) async {
    await db.update('messages', {'attachment': _seal(attachment)},
        where: 'id = ?', whereArgs: [messageId]);
  }

  // Key/value settings (device id, prekey counters)

  Future<String?> kvGet(String key) async {
    final rows = await db.query('kv', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  // Group receipts

  static const _receiptRank = {'sending': 0, 'sent': 1, 'delivered': 2, 'read': 3};

  /// The members a group message goes to, each at `sending` until it
  /// reaches them. Recipients already recorded are kept as they are.
  Future<void> addGroupRecipients(String messageId, Iterable<String> userIds) async {
    final batch = db.batch();
    for (final u in userIds) {
      batch.insert('group_receipts', {'message_id': messageId, 'user_id': u, 'status': 'sending'},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }

  /// Raises [userId]'s status for [messageId] (never lowers it) and returns
  /// the status every recipient has reached, or null if [userId] isn't a
  /// recipient.
  Future<String?> applyGroupReceipt(String messageId, String userId, String status) async {
    await db.update('group_receipts', {'status': status},
        where: 'message_id = ? AND user_id = ? AND '
            "(CASE status WHEN 'sending' THEN 0 WHEN 'sent' THEN 1 WHEN 'delivered' THEN 2 ELSE 3 END) < ?",
        whereArgs: [messageId, userId, _receiptRank[status] ?? 0]);
    final all = await groupReceipts(messageId);
    return all.containsKey(userId) ? _lowest(all.values) : null;
  }

  /// A member we can no longer send to (they left, or blocked us) stops
  /// holding the message's status back. Returns the new overall status.
  Future<String?> removeGroupRecipient(String messageId, String userId) async {
    await db.delete('group_receipts', where: 'message_id = ? AND user_id = ?', whereArgs: [messageId, userId]);
    final all = await groupReceipts(messageId);
    return all.isEmpty ? null : _lowest(all.values);
  }

  static String _lowest(Iterable<String> statuses) {
    var lowest = 3;
    for (final s in statuses) {
      lowest = math.min(lowest, _receiptRank[s] ?? 0);
    }
    return _receiptRank.entries.firstWhere((e) => e.value == lowest).key;
  }

  /// Per-member status of one of our group messages.
  Future<Map<String, String>> groupReceipts(String messageId) async => {
        for (final r in await db.query('group_receipts', where: 'message_id = ?', whereArgs: [messageId]))
          r['user_id'] as String: r['status'] as String
      };

  Future<void> kvSet(String key, String value) async {
    await db.insert('kv', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Like [kvSet], but the value is encrypted at rest (personal data).
  Future<void> kvSetSealed(String key, String value) => kvSet(key, _seal(value));

  Future<String?> kvGetSealed(String key) async {
    final raw = await kvGet(key);
    return raw == null ? null : _unseal(raw);
  }

  /// Sealed entries whose key starts with [prefix].
  Future<List<MapEntry<String, String>>> kvSealedByPrefix(String prefix) async {
    final rows = await db.query('kv',
        where: "key LIKE ? ESCAPE '\\'", whereArgs: ['${prefix.replaceAll(r'%', r'\%').replaceAll('_', r'\_')}%']);
    return [for (final r in rows) MapEntry(r['key'] as String, _unseal(r['value'] as String))];
  }

  Future<void> kvDelete(String key) async {
    await db.delete('kv', where: 'key = ?', whereArgs: [key]);
  }

  // Ratchet sessions (sealed at rest)

  Future<String?> getSessionRecord(String address) async {
    final rows = await db.query('ratchet_sessions',
        where: 'address = ?', whereArgs: [address], limit: 1);
    if (rows.isEmpty) return null;
    final raw = _unseal(rows.first['record'] as String);
    return raw == '[unreadable message]' ? null : raw;
  }

  Future<void> saveSessionRecord(String address, String record) async {
    await db.insert(
      'ratchet_sessions',
      {
        'address': address,
        'record': _seal(record),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteSessionRecord(String address) async {
    await db.delete('ratchet_sessions', where: 'address = ?', whereArgs: [address]);
  }

  Future<void> deleteSessionsForUser(String userId) async {
    await db.delete('ratchet_sessions',
        where: 'address LIKE ?', whereArgs: ['$userId:%']);
  }

  /// Device identity changed: every session and prekey is void.
  Future<void> resetDeviceState() async {
    final batch = db.batch()
      ..delete('ratchet_sessions')
      ..delete('local_prekeys')
      ..delete('seen_envelopes');
    await batch.commit(noResult: true);
  }

  // Our prekeys (private halves sealed at rest)

  Future<void> insertPreKeys(
      String kind, List<({int id, String private, String public})> keys) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final k in keys) {
      batch.insert(
        'local_prekeys',
        {
          'kind': kind,
          'key_id': k.id,
          'private': _seal(k.private),
          'public': k.public,
          'created_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// `(private, public, createdAt)` or null.
  Future<({String private, String public, int createdAt})?> getPreKey(
      String kind, int id) async {
    final rows = await db.query('local_prekeys',
        where: 'kind = ? AND key_id = ?', whereArgs: [kind, id], limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return (
      private: _unseal(r['private'] as String),
      public: r['public'] as String,
      createdAt: r['created_at'] as int,
    );
  }

  Future<void> deletePreKey(String kind, int id) async {
    await db.delete('local_prekeys',
        where: 'kind = ? AND key_id = ?', whereArgs: [kind, id]);
  }

  Future<int> maxPreKeyId(String kind) async {
    final rows = await db.rawQuery(
        'SELECT MAX(key_id) AS m FROM local_prekeys WHERE kind = ?', [kind]);
    return (rows.first['m'] as int?) ?? 0;
  }

  /// Drops [kind] prekeys created before [beforeMs], except [keep].
  Future<void> deletePreKeysBefore(String kind, int beforeMs, {int? keep}) async {
    await db.delete('local_prekeys',
        where: 'kind = ? AND created_at < ? AND key_id != ?',
        whereArgs: [kind, beforeMs, keep ?? -1]);
  }

  // Peer devices (public keys of contacts' and our own other devices)

  Future<List<Map<String, dynamic>>> getPeerDevices(String userId) =>
      db.query('peer_devices',
          where: 'user_id = ?', whereArgs: [userId], orderBy: 'device_id');

  /// When the list for [userId] was last fetched (ms), or null.
  Future<int?> peerDevicesFetchedAt(String userId) async {
    final rows = await db.query('peer_device_lists',
        where: 'user_id = ?', whereArgs: [userId], limit: 1);
    return rows.isEmpty ? null : rows.first['fetched_at'] as int;
  }

  /// Replaces [userId]'s device list. Returns `(added, removed, changed)`
  /// device ids compared with what was cached (empty on the first fetch).
  Future<({List<String> added, List<String> removed, List<String> changed})>
      replacePeerDevices(String userId,
          List<({String deviceId, String signingKey, String identityKey})> devices) async {
    final hadList = await peerDevicesFetchedAt(userId) != null;
    final old = {
      for (final r in await getPeerDevices(userId))
        r['device_id'] as String: '${r['signing_key']}|${r['identity_key']}'
    };
    final next = {for (final d in devices) d.deviceId: '${d.signingKey}|${d.identityKey}'};
    await db.transaction((txn) async {
      await txn.delete('peer_devices', where: 'user_id = ?', whereArgs: [userId]);
      for (final d in devices) {
        await txn.insert('peer_devices', {
          'user_id': userId,
          'device_id': d.deviceId,
          'signing_key': d.signingKey,
          'identity_key': d.identityKey,
        });
      }
      await txn.insert(
        'peer_device_lists',
        {'user_id': userId, 'fetched_at': DateTime.now().millisecondsSinceEpoch},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    if (!hadList) return (added: <String>[], removed: <String>[], changed: <String>[]);
    return (
      added: next.keys.where((k) => !old.containsKey(k)).toList(),
      removed: old.keys.where((k) => !next.containsKey(k)).toList(),
      changed: next.keys
          .where((k) => old.containsKey(k) && old[k] != next[k])
          .toList(),
    );
  }

  /// Forces the next lookup of [userId]'s devices to hit the server.
  Future<void> invalidatePeerDevices(String userId) async {
    await db.update('peer_device_lists', {'fetched_at': 0},
        where: 'user_id = ?', whereArgs: [userId]);
  }

  // Envelope de-duplication

  /// Records [envelopeId]; returns false if it was already processed.
  Future<bool> markEnvelopeSeen(String envelopeId) async {
    if (await wasEnvelopeSeen(envelopeId)) return false;
    await db.insert(
      'seen_envelopes',
      {'id': envelopeId, 'seen_at': DateTime.now().millisecondsSinceEpoch},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return true;
  }

  Future<bool> wasEnvelopeSeen(String envelopeId) async {
    final rows = await db.query('seen_envelopes',
        columns: ['id'], where: 'id = ?', whereArgs: [envelopeId], limit: 1);
    return rows.isNotEmpty;
  }

  Future<void> pruneSeenEnvelopes(int beforeMs) async {
    await db.delete('seen_envelopes', where: 'seen_at < ?', whereArgs: [beforeMs]);
  }

  // Edits, deletions, reactions

  Future<void> editMessage(String messageId, String content, int editedAt) async {
    await db.update('messages', {'content': _seal(content), 'edited_at': editedAt},
        where: 'id = ?', whereArgs: [messageId]);
  }

  /// "Deleted for everyone": the content and attachment are wiped, a
  /// tombstone stays so the chat shows where it was.
  Future<void> tombstoneMessage(String messageId) async {
    await db.update(
      'messages',
      {'content': _seal(''), 'attachment': null, 'reply_to': null, 'deleted': 1},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    await db.delete('reactions', where: 'message_id = ?', whereArgs: [messageId]);
  }

  /// Sets ([emoji] non-empty) or removes [reactorId]'s reaction.
  Future<void> setReaction(String messageId, String reactorId, String emoji, int at) async {
    if (emoji.isEmpty) {
      await db.delete('reactions',
          where: 'message_id = ? AND reactor_id = ?', whereArgs: [messageId, reactorId]);
    } else {
      await db.insert(
        'reactions',
        {'message_id': messageId, 'reactor_id': reactorId, 'emoji': emoji, 'at': at},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  /// message id → {reactor id → emoji} for [messageIds].
  Future<Map<String, Map<String, String>>> reactionsFor(List<String> messageIds) async {
    final out = <String, Map<String, String>>{};
    if (messageIds.isEmpty) return out;
    for (var i = 0; i < messageIds.length; i += 500) {
      final chunk = messageIds.sublist(i, i + 500 > messageIds.length ? messageIds.length : i + 500);
      final rows = await db.query('reactions',
          where: 'message_id IN (${List.filled(chunk.length, '?').join(',')})',
          whereArgs: chunk,
          orderBy: 'at');
      for (final r in rows) {
        out.putIfAbsent(r['message_id'] as String, () => {})[r['reactor_id'] as String] =
            r['emoji'] as String;
      }
    }
    return out;
  }

  /// Re-derives the conversation preview from its newest visible message.
  Future<void> refreshConversationPreview(String conversationId, String Function(Map<String, dynamic>) preview) async {
    final rows = await db.query('messages',
        where: "conversation_id = ? AND kind != 'system'",
        whereArgs: [conversationId],
        orderBy: 'timestamp DESC',
        limit: 1);
    final text = rows.isEmpty ? null : preview(_unsealMessage(rows.first));
    await db.update('conversations', {'last_message': text == null ? null : _seal(text)},
        where: 'id = ?', whereArgs: [conversationId]);
  }

  // Disappearing messages

  /// Seconds after which new messages in [conversationId] disappear (0 = off).
  Future<int> disappearAfter(String conversationId) async {
    final rows = await db.query('conversations',
        columns: ['disappear_after'], where: 'id = ?', whereArgs: [conversationId], limit: 1);
    return rows.isEmpty ? 0 : (rows.first['disappear_after'] as int? ?? 0);
  }

  Future<void> setDisappearAfter(String conversationId, int seconds) async {
    await updateConversation(id: conversationId, contactUserId: conversationId);
    await db.update('conversations', {'disappear_after': seconds},
        where: 'id = ?', whereArgs: [conversationId]);
  }

  /// Deletes messages whose time is up; returns their conversations and
  /// attachment metadata (so cached files can be removed too).
  Future<({Set<String> conversations, List<String> attachments})> deleteExpired(int nowMs) async {
    final rows = await db.query('messages',
        columns: ['id', 'conversation_id', 'attachment'],
        where: 'expires_at IS NOT NULL AND expires_at <= ?',
        whereArgs: [nowMs]);
    if (rows.isEmpty) return (conversations: <String>{}, attachments: <String>[]);
    final ids = [for (final r in rows) r['id'] as String];
    final batch = db.batch();
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      final marks = List.filled(chunk.length, '?').join(',');
      batch.delete('messages', where: 'id IN ($marks)', whereArgs: chunk);
      batch.delete('reactions', where: 'message_id IN ($marks)', whereArgs: chunk);
      batch.delete('group_receipts', where: 'message_id IN ($marks)', whereArgs: chunk);
    }
    await batch.commit(noResult: true);
    return (
      conversations: {for (final r in rows) r['conversation_id'] as String},
      attachments: [
        for (final r in rows)
          if (r['attachment'] != null) _unseal(r['attachment'] as String)
      ],
    );
  }
}
