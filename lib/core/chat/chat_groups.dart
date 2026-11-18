part of 'chat_service.dart';

/// Group chats.
///
/// A group message goes to each member separately, over the same pairwise
/// Double Ratchet sessions as 1:1 messages, marked with the group's id. The
/// group's state (name, members, admins) travels the same way, and every
/// member's app checks each change with [GroupState.accept]. The server
/// learns who is in which group, since it lets members who aren't contacts
/// reach each other, but never the name or anything said.
extension ChatGroups on ChatService {
  /// Groups we are in, or were in.
  List<GroupState> get groups => _groups.values.toList(growable: false);

  GroupState? groupOf(String conversationId) => _groups[conversationId];

  /// The public name of someone we met in a group (not a contact).
  String? memberName(String userId) {
    final n = _memberNames[userId];
    if (n == null) return null;
    final display = n['display_name'];
    return display != null && display.isNotEmpty ? display : n['username'];
  }

  /// Creates a group with [memberIds] (our contacts) and tells them.
  Future<GroupState> createGroup(String name, List<String> memberIds) async {
    final me = _requireUserId();
    final others = memberIds.where((u) => u != me).toSet().toList();
    if (name.trim().isEmpty || others.isEmpty) {
      throw ArgumentError('A group needs a name and at least one other member');
    }
    final id = _uuid.v4();
    _rememberNames(await _directory.createGroup(id, others));
    final state = GroupState.create(id: id, name: name, creator: me, others: others);
    await _publishGroup(null, state);
    return state;
  }

  Future<void> renameGroup(String conversationId, String name) async {
    final s = _adminOf(conversationId);
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == s.name) return;
    await _publishGroup(s, s.rename(trimmed));
  }

  /// Adds our contacts [userIds]. They see messages from now on, not
  /// earlier ones.
  Future<void> addGroupMembers(String conversationId, List<String> userIds) async {
    final s = _adminOf(conversationId);
    final fresh = userIds.where((u) => !s.isMember(u)).toSet().toList();
    if (fresh.isEmpty) return;
    _rememberNames(await _directory.addGroupMembers(s.id, fresh));
    await _publishGroup(s, s.adding(fresh));
  }

  Future<void> removeGroupMember(String conversationId, String userId) async {
    final s = _adminOf(conversationId);
    if (!s.isMember(userId) || userId == _myUserId) return;
    await _directory.removeGroupMember(s.id, userId);
    await _publishGroup(s, s.without(userId));
  }

  Future<void> setGroupAdmin(String conversationId, String userId, bool admin) async {
    final s = _adminOf(conversationId);
    if (!s.isMember(userId) || s.isAdmin(userId) == admin) return;
    await _directory.setGroupAdmin(s.id, userId, admin);
    await _publishGroup(s, s.setAdmin(userId, admin));
  }

  /// Leaves the group. Its history stays on this device, read-only.
  Future<void> leaveGroup(String conversationId) async {
    final me = _requireUserId();
    final s = _groups[conversationId];
    if (s == null || !s.isMember(me)) return;
    try {
      await _directory.removeGroupMember(s.id, me);
    } on ApiException catch (e) {
      if (e.status != 404) rethrow; // already gone on the server
    }
    await _publishGroup(s, s.without(me));
  }

  /// Fetches members' public names (for people who aren't our contacts).
  Future<void> refreshGroupMembers(String conversationId) async {
    final s = _groups[conversationId];
    if (s == null || !s.isMember(_requireUserId())) return;
    try {
      _rememberNames(await _directory.groupMembers(s.id));
      _changed(conversationId);
    } catch (e) {
      debugPrint('Group members of ${s.id} not loaded: $e');
    }
  }

  /// Sends [state] to its members without any local checks, as a modified
  /// client could. For tests of the receiving side's checks only.
  @visibleForTesting
  Future<void> debugSendGroupState(GroupState state) =>
      _sendGroupState(state, state.members.toSet()..remove(_requireUserId()));

  /// Per-member delivery of one of our group messages.
  Future<Map<String, String>> groupReceiptsOf(String messageId) => _storage.groupReceipts(messageId);

  GroupState _adminOf(String conversationId) {
    final s = _groups[conversationId];
    if (s == null || !s.isAdmin(_requireUserId())) {
      throw StateError('Only group admins can do that');
    }
    return s;
  }

  void _rememberNames(List<Map<String, dynamic>> members) {
    for (final m in members) {
      final id = m['user_id'];
      if (id is! String || id == _myUserId) continue;
      final entry = {
        'username': m['username'] as String? ?? '',
        'display_name': m['display_name'] as String? ?? '',
      };
      _memberNames[id] = entry;
      unawaited(_storage.kvSetSealed('member:$id', jsonEncode(entry)));
    }
  }

  Future<void> _loadGroups() async {
    for (final e in await _storage.kvSealedByPrefix('group:')) {
      try {
        final s = GroupState.fromJson(Map<String, dynamic>.from(jsonDecode(e.value) as Map));
        _groups[s.conversationId] = s;
      } catch (err) {
        debugPrint('Ignoring stored group ${e.key}: $err');
      }
    }
    for (final e in await _storage.kvSealedByPrefix('member:')) {
      try {
        _memberNames[e.key.substring('member:'.length)] =
            Map<String, String>.from(jsonDecode(e.value) as Map);
      } catch (_) {}
    }
  }

  /// A name for chat notices: "you", a contact's name, or a member's.
  Future<String> _noticeName(String userId) async {
    if (userId == _myUserId) return 'you';
    final contact = await _storage.getCachedContact(userId);
    final display = contact?['display_name'] as String?;
    if (display != null && display.isNotEmpty) return display;
    final username = contact?['username'] as String?;
    if (username != null && username.isNotEmpty) return username;
    return memberName(userId) ?? 'Someone';
  }

  /// Stores [next] and adds a notice for each change since [before].
  Future<void> _saveGroup(GroupState? before, GroupState next, String actor, {bool notices = true}) async {
    _groups[next.conversationId] = next;
    await _storage.kvSetSealed('group:${next.id}', jsonEncode(next.toJson()));
    final cid = next.conversationId;
    if (notices) {
      final names = {
        for (final u in {actor, ...next.members, ...?before?.members}) u: await _noticeName(u),
      };
      final lines = next.describe(before, actor, (u) => names[u] ?? 'Someone');
      for (final line in lines) {
        await _storage.insertSystemMessage(cid, _capitalized(line), id: _uuid.v4());
      }
      await _storage.updateConversation(
        id: cid,
        contactUserId: cid,
        lastMessage: lines.isEmpty ? null : _capitalized(lines.last),
        lastMessageTime: lines.isEmpty ? null : DateTime.now().millisecondsSinceEpoch,
      );
    } else {
      await _storage.updateConversation(id: cid, contactUserId: cid);
    }
    _changed(cid);
  }

  static String _capitalized(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// Saves [next] and sends it to everyone in the old and new member lists
  /// (so removed people learn they're out) and to our other devices.
  Future<void> _publishGroup(GroupState? before, GroupState next) async {
    final me = _requireUserId();
    await _saveGroup(before, next, me);
    final recipients = {...?before?.members, ...next.members}..remove(me);
    await _sendGroupState(next, recipients);
    unawaited(_syncToOwnDevices(WirePayload.group(
        from: me, to: me, timestampMs: DateTime.now().millisecondsSinceEpoch, group: next.toJson())));
  }

  /// Sends [state] to [recipients]; whoever couldn't be reached is retried
  /// with the then-current state by [resendUnsent].
  Future<void> _sendGroupState(GroupState state, Set<String> recipients) async {
    final me = _requireUserId();
    final missed = <String>{};
    for (final u in recipients) {
      try {
        final ok = await _deliver(u, WirePayload.group(
            from: me, to: u, timestampMs: DateTime.now().millisecondsSinceEpoch, group: state.toJson()));
        if (!ok) missed.add(u);
      } on ApiException catch (e) {
        if (e.status != 403) missed.add(u); // 403: blocked or gone; nothing to retry
      } catch (e) {
        debugPrint('Group update to $u failed: $e');
        missed.add(u);
      }
    }
    final key = 'gsend:${state.id}';
    final before = await _storage.kvGetSealed(key);
    final still = {
      if (before != null) ...(jsonDecode(before) as List).cast<String>().where((u) => !recipients.contains(u)),
      ...missed,
    };
    if (still.isEmpty) {
      await _storage.kvDelete(key);
    } else {
      await _storage.kvSetSealed(key, jsonEncode(still.toList()));
    }
  }

  Future<void> _resendGroupStates() async {
    for (final e in await _storage.kvSealedByPrefix('gsend:')) {
      final s = _groups['${GroupState.prefix}${e.key.substring('gsend:'.length)}'];
      if (s == null) {
        await _storage.kvDelete(e.key);
        continue;
      }
      await _sendGroupState(s, (jsonDecode(e.value) as List).cast<String>().toSet());
    }
  }

  /// A group state from [actor] (a member, or us on another device).
  Future<void> _receiveGroupState(String actor, WirePayload p) async {
    final me = _requireUserId();
    final GroupState next;
    try {
      next = GroupState.fromJson(p.group!);
    } on FormatException catch (e) {
      debugPrint('Dropped group state from $actor: $e');
      return;
    }
    final current = _groups[next.conversationId];
    final accepted = GroupState.accept(current, next, actor: actor, me: me);
    if (accepted == null) {
      debugPrint('Ignored a change to group ${next.id} from $actor');
      return;
    }
    await _saveGroup(current, accepted, actor);
    if (accepted.isMember(me)) {
      unawaited(refreshGroupMembers(accepted.conversationId));
      await _replayHeld(accepted.id);
    }
  }

  /// A message, receipt, reaction, edit, deletion or timer for a group.
  Future<void> _receiveForGroup(String sender, WirePayload p) async {
    final gid = p.groupId!;
    final cid = '${GroupState.prefix}$gid';
    final s = _groups[cid];
    if (s == null) {
      await _holdForGroup(sender, p);
      return;
    }
    if (!s.isMember(sender) || !s.isMember(_requireUserId())) return;
    switch (p.kind) {
      case PayloadKind.message:
        await _storeIncomingMessage(sender, p, conversation: cid);
      case PayloadKind.receipt:
        await _applyGroupReceipt(cid, sender, p);
      case PayloadKind.react:
      case PayloadKind.edit:
      case PayloadKind.delete:
        await _applyAction(cid, sender, p);
      case PayloadKind.timer:
        await _applyTimer(cid, sender, p.expireSeconds!);
      default:
        break;
    }
  }

  static const _heldKey = 'gheld';
  static const _maxHeld = 200;

  /// Keeps something for a group we haven't heard of yet: its state can
  /// arrive after the first message when the two take different routes.
  Future<void> _holdForGroup(String sender, WirePayload p) async {
    final raw = await _storage.kvGetSealed(_heldKey);
    final held = raw == null ? <dynamic>[] : jsonDecode(raw) as List;
    held.add({'from': sender, 'p': p.toJson()});
    while (held.length > _maxHeld) {
      held.removeAt(0);
    }
    await _storage.kvSetSealed(_heldKey, jsonEncode(held));
  }

  Future<void> _replayHeld(String gid) async {
    final raw = await _storage.kvGetSealed(_heldKey);
    if (raw == null) return;
    final held = jsonDecode(raw) as List;
    final mine = held.where((h) => (h as Map)['p']?['gid'] == gid).toList();
    if (mine.isEmpty) return;
    held.removeWhere(mine.contains);
    await _storage.kvSetSealed(_heldKey, jsonEncode(held));
    for (final h in mine.cast<Map>()) {
      try {
        await _receiveForGroup(h['from'] as String, WirePayload.fromJson(Map<String, dynamic>.from(h['p'] as Map)));
      } catch (e) {
        debugPrint('Held group payload dropped: $e');
      }
    }
  }

  /// Sends our message [id] to each member who hasn't got it yet.
  Future<bool> _transmitToGroup(String cid, WirePayload Function(String to, String groupId) build, String id) async {
    final me = _requireUserId();
    final s = _groups[cid];
    if (s == null || !s.isMember(me)) return false;
    if ((await _storage.groupReceipts(id)).isEmpty) {
      await _storage.addGroupRecipients(id, s.members.where((u) => u != me));
    }
    var all = true;
    final pending = (await _storage.groupReceipts(id)).entries.where((e) => e.value == 'sending').map((e) => e.key);
    for (final u in pending.toList()) {
      try {
        if (await _deliver(u, build(u, s.id), envelopeId: id)) {
          await _storage.applyGroupReceipt(id, u, 'sent');
        } else {
          all = false;
        }
      } on ApiException catch (e) {
        if (e.status == 403) {
          await _storage.removeGroupRecipient(id, u); // left the group, or blocked
        } else {
          all = false;
        }
      } catch (e) {
        debugPrint('Group message to $u failed: $e');
        all = false;
      }
    }
    return all;
  }

  /// Sends an action, receipt or timer change to every other member.
  Future<void> _sendToGroup(String cid, WirePayload Function(String to, String groupId) build) async {
    final me = _requireUserId();
    final s = _groups[cid];
    if (s == null || !s.isMember(me)) return;
    for (final u in s.members.where((u) => u != me)) {
      try {
        await _deliver(u, build(u, s.id));
      } catch (e) {
        debugPrint('Group update to $u failed: $e');
      }
    }
  }

  Future<void> _applyGroupReceipt(String cid, String sender, WirePayload p) async {
    for (final id in p.receiptIds) {
      final row = await _storage.getMessage(id);
      if (row == null || row['is_from_me'] != 1 || row['conversation_id'] != cid) continue;
      final overall = await _storage.applyGroupReceipt(id, sender, p.receiptStatus!.name);
      if (overall == null) continue;
      final current = row['status'] as String;
      if ((ChatService._statusRank[overall] ?? 0) > (ChatService._statusRank[current] ?? 0)) {
        await _storage.updateMessageStatus(id, overall);
      }
    }
    _changed(cid);
  }

  /// Group states from a backup or another of our devices.
  Future<void> _mergeGroups(Map<String, dynamic> history) async {
    final me = _requireUserId();
    final groups = history['groups'];
    if (groups is Map) {
      for (final v in groups.values) {
        try {
          final next = GroupState.fromJson(Map<String, dynamic>.from(jsonDecode(v as String) as Map));
          final current = _groups[next.conversationId];
          final accepted = GroupState.accept(current, next, actor: me, me: me);
          if (accepted != null) await _saveGroup(current, accepted, me, notices: false);
        } catch (e) {
          debugPrint('Group in history skipped: $e');
        }
      }
    }
    final names = history['names'];
    if (names is Map) {
      for (final e in names.entries) {
        final key = e.key;
        if (key is String && key.startsWith('member:') && e.value is String) {
          try {
            _memberNames[key.substring('member:'.length)] =
                Map<String, String>.from(jsonDecode(e.value as String) as Map);
            await _storage.kvSetSealed(key, e.value as String);
          } catch (_) {}
        }
      }
    }
  }
}
