import 'dart:convert';

import 'package:securelyhello/core/crypto/ratchet.dart' show Kdf;

/// A group as its members know it: name, members in join order, admins and
/// a revision number. It travels end to end in `group` payloads, and every
/// member's app decides on its own whether to accept a change (see
/// [GroupState.accept]). The server keeps a separate member list only to
/// decide who may relay to whom; it never sees the name.
class GroupState {
  /// Conversation ids of groups start with this; user ids are bare UUIDs.
  static const prefix = 'g_';
  static const maxMembers = 64;
  static const maxName = 64;

  /// The group's UUID (as the server knows it).
  final String id;
  final String name;

  /// Members in the order they joined.
  final List<String> members;
  final Set<String> admins;
  final int rev;

  GroupState({
    required this.id,
    required this.name,
    required List<String> members,
    required Set<String> admins,
    required this.rev,
  })  : members = List.unmodifiable(members),
        admins = Set.unmodifiable(admins);

  String get conversationId => '$prefix$id';

  static bool isGroup(String conversationId) => conversationId.startsWith(prefix);

  /// The group UUID of a group conversation id.
  static String idOf(String conversationId) => conversationId.substring(prefix.length);

  bool isMember(String userId) => members.contains(userId);
  bool isAdmin(String userId) => admins.contains(userId);

  factory GroupState.create({
    required String id,
    required String name,
    required String creator,
    required List<String> others,
  }) =>
      GroupState(id: id, name: name.trim(), members: [creator, ...others], admins: {creator}, rev: 1);

  GroupState copyWith({String? name, List<String>? members, Set<String>? admins}) => GroupState(
        id: id,
        name: name ?? this.name,
        members: members ?? this.members,
        admins: admins ?? this.admins,
        rev: rev + 1,
      );

  GroupState rename(String name) => copyWith(name: name.trim());

  GroupState adding(List<String> users) =>
      copyWith(members: [...members, ...users.where((u) => !members.contains(u))]);

  GroupState setAdmin(String user, bool admin) =>
      copyWith(admins: admin ? {...admins, user} : ({...admins}..remove(user)));

  /// [user] removed or gone. If no admin is left, the longest-standing
  /// member becomes one (the server applies the same rule).
  GroupState without(String user) {
    final rest = [...members]..remove(user);
    final keep = {...admins}..remove(user);
    if (keep.isEmpty && rest.isNotEmpty) keep.add(rest.first);
    return copyWith(members: rest, admins: keep);
  }

  /// Decides whether [next], sent by [actor], replaces [current] on the
  /// device of [me]. Returns the state to keep, or null to ignore [next].
  ///
  /// - Our own other devices are trusted (same account, same keys).
  /// - A group we don't know yet is accepted from one of its admins.
  /// - Otherwise the change must come from an admin of the current state,
  ///   or be a member leaving, and move the revision forward. Two admins
  ///   changing the group at once both produce the same revision; every
  ///   member then keeps the same one of the two (the larger digest), so
  ///   the group doesn't split.
  static GroupState? accept(GroupState? current, GroupState next, {required String actor, required String me}) {
    if (current != null && current.id != next.id) return null;
    if (!next.isMember(actor) && !(current?.isMember(actor) ?? false) && actor != me) return null;
    if (current == null) {
      if (actor == me) return next;
      return next.isAdmin(actor) && next.isMember(me) ? next : null;
    }
    final newer = next.rev > current.rev || (next.rev == current.rev && next.digest.compareTo(current.digest) > 0);
    if (!newer) return null;
    if (actor == me) return next;
    if (current.isAdmin(actor)) return next;
    final leaving = current.without(actor);
    return current.isMember(actor) && next.sameAs(leaving) ? next : null;
  }

  /// Same name, members and admins (any revision).
  bool sameAs(GroupState other) =>
      other.id == id &&
      other.name == name &&
      _listEquals(other.members, members) &&
      other.admins.length == admins.length &&
      other.admins.containsAll(admins);

  /// Order-independent fingerprint, for breaking ties between revisions.
  String get digest => base64Encode(Kdf.sha256(utf8.encode(jsonEncode(toJson()))));

  /// What changed from [before] to this state, as lines for the chat.
  List<String> describe(GroupState? before, String actor, String Function(String userId) nameOf) {
    final who = nameOf(actor);
    if (before == null) return ['$who created the group “$name”'];
    final out = <String>[];
    if (before.name != name) out.add('$who renamed the group to “$name”');
    for (final u in members.where((u) => !before.isMember(u))) {
      out.add('$who added ${nameOf(u)}');
    }
    for (final u in before.members.where((u) => !isMember(u))) {
      out.add(u == actor ? '$who left' : '$who removed ${nameOf(u)}');
    }
    for (final u in admins.where((u) => !before.isAdmin(u) && before.isMember(u))) {
      out.add(u == actor ? '$who is now an admin' : '${nameOf(u)} is now an admin');
    }
    for (final u in before.admins.where((u) => !isAdmin(u) && isMember(u))) {
      out.add('${nameOf(u)} is no longer an admin');
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'members': members,
        'admins': (admins.toList()..sort()),
        'rev': rev,
      };

  /// Parses and checks a state from the network or storage; anything
  /// malformed is a [FormatException].
  static GroupState fromJson(Map<String, dynamic> json) {
    try {
      final id = json['id'] as String;
      final name = (json['name'] as String).trim();
      final members = (json['members'] as List).cast<String>();
      final admins = (json['admins'] as List).cast<String>().toSet();
      final rev = json['rev'] as int;
      if (!_uuid.hasMatch(id) ||
          name.isEmpty ||
          name.length > maxName ||
          members.isEmpty ||
          members.length > maxMembers ||
          members.toSet().length != members.length ||
          !members.every(_uuid.hasMatch) ||
          !members.toSet().containsAll(admins) ||
          rev < 1) {
        throw const FormatException('Malformed group');
      }
      return GroupState(id: id, name: name, members: members, admins: admins, rev: rev);
    } on TypeError {
      throw const FormatException('Malformed group');
    }
  }

  static final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
