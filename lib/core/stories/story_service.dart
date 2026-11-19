import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';

import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/chat/wire_protocol.dart';
import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/storage/local_storage.dart';

/// A story: text on a colour, or a photo or video with a caption. Gone 24
/// hours after it was posted.
class Story {
  Story({
    required this.id,
    required this.ownerId,
    required this.created,
    required this.expires,
    required this.type,
    this.text,
    this.color,
    this.caption,
    this.attachment,
    this.seen = false,
  });

  final String id;
  final String ownerId;
  final DateTime created;
  final DateTime expires;

  /// text, photo or video.
  final String type;
  final String? text;

  /// ARGB background of a text story.
  final int? color;
  final String? caption;

  /// The encrypted attachment holding the photo or video (with its key).
  final Map<String, dynamic>? attachment;
  bool seen;

  bool expiredAt(DateTime now) => !expires.isAfter(now);

  /// What the story carries on the wire.
  Map<String, dynamic> toPayload() => {
        'id': id,
        'type': type,
        if (text != null) 'text': text,
        if (color != null) 'color': color,
        if (caption != null) 'caption': caption,
        if (attachment != null) 'att': attachment,
        'exp': expires.millisecondsSinceEpoch,
      };

  Map<String, dynamic> toJson() => {
        ...toPayload(),
        'owner': ownerId,
        'created': created.millisecondsSinceEpoch,
        'seen': seen,
      };

  static Story? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return Story(
        id: j['id'] as String,
        ownerId: j['owner'] as String,
        created: DateTime.fromMillisecondsSinceEpoch(j['created'] as int),
        expires: DateTime.fromMillisecondsSinceEpoch(j['exp'] as int),
        type: j['type'] as String,
        text: j['text'] as String?,
        color: j['color'] as int?,
        caption: j['caption'] as String?,
        attachment: j['att'] is Map ? Map<String, dynamic>.from(j['att'] as Map) : null,
        seen: j['seen'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// From a decrypted payload sent by [owner] at [sentAt]. Stories claiming
  /// to live longer than a day are cut to a day.
  static Story fromPayload(String owner, int sentAt, Map<String, dynamic> p) {
    final created = DateTime.fromMillisecondsSinceEpoch(sentAt);
    final claimed = DateTime.fromMillisecondsSinceEpoch(p['exp'] as int);
    final latest = created.add(StoryService.lifetime);
    return Story(
      id: p['id'] as String,
      ownerId: owner,
      created: created,
      expires: claimed.isAfter(latest) ? latest : claimed,
      type: p['type'] as String,
      text: p['text'] as String?,
      color: p['color'] is int ? p['color'] as int : null,
      caption: p['caption'] is String ? p['caption'] as String : null,
      attachment: p['att'] is Map ? Map<String, dynamic>.from(p['att'] as Map) : null,
    );
  }
}

/// Who sees your stories.
enum AudienceMode { allContacts, allExcept, onlyShareWith }

class StoryAudience {
  const StoryAudience(this.mode, [this.users = const {}]);
  final AudienceMode mode;
  final Set<String> users;

  static const everyone = StoryAudience(AudienceMode.allContacts);

  /// The contacts (of [contacts]) a story goes to.
  Set<String> resolve(Iterable<String> contacts) => switch (mode) {
        AudienceMode.allContacts => contacts.toSet(),
        AudienceMode.allExcept => contacts.where((c) => !users.contains(c)).toSet(),
        AudienceMode.onlyShareWith => contacts.where(users.contains).toSet(),
      };

  String encode() => jsonEncode({'m': mode.name, 'u': users.toList()});

  static StoryAudience decode(String? raw) {
    try {
      final j = jsonDecode(raw ?? '');
      final mode = AudienceMode.values.firstWhere((m) => m.name == j['m']);
      return StoryAudience(mode, {for (final u in j['u'] as List) '$u'});
    } catch (_) {
      return everyone;
    }
  }
}

/// Owners with stories, in the order the stories row shows them: unseen
/// first, then the most recent.
List<String> orderOwners(Map<String, List<Story>> byOwner) {
  final owners = byOwner.keys.toList();
  bool unseen(String o) => byOwner[o]!.any((s) => !s.seen);
  DateTime latest(String o) => byOwner[o]!.map((s) => s.created).reduce((a, b) => a.isAfter(b) ? a : b);
  owners.sort((a, b) {
    final u = (unseen(b) ? 1 : 0) - (unseen(a) ? 1 : 0);
    return u != 0 ? u : latest(b).compareTo(latest(a));
  });
  return owners;
}

/// Stories, end to end encrypted.
///
/// A story's content (and, for a photo or video, the key of its encrypted
/// attachment) is sealed for each audience device with the session we
/// already have with it, and posted to the server, which keeps only those
/// envelopes and deletes them after 24 hours (server/src/stories.js). Only
/// devices that say they can take stories (the `stories` capability, 1.1
/// and later) get one. Who viewed a story goes back as an end-to-end
/// receipt; replies and reactions are ordinary messages quoting it.
class StoryService extends ChangeNotifier {
  StoryService({required ChatService chat, required DirectoryService directory, required LocalStorage storage})
      : _chat = chat,
        _directory = directory,
        _storage = storage;

  static const lifetime = Duration(hours: 24);
  static const maxText = 700;
  static const maxPhotoSide = 1600;

  final ChatService _chat;
  final DirectoryService _directory;
  final LocalStorage _storage;
  final _uuid = const Uuid();

  String? _me;
  String? _myDevice;
  final Map<String, Story> _stories = {};
  final Map<String, Set<String>> _views = {};
  Set<String> _muted = {};
  StoryAudience _audience = StoryAudience.everyone;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _sweep;
  bool _refreshing = false;

  StoryAudience get audience => _audience;
  Set<String> get mutedOwners => Set.unmodifiable(_muted);

  /// Our own stories, oldest first.
  List<Story> get mine => _sorted(_stories.values.where((s) => s.ownerId == _me));

  /// Other people's stories by owner, oldest first within each owner.
  Map<String, List<Story>> get byOwner {
    final out = <String, List<Story>>{};
    for (final s in _stories.values) {
      if (s.ownerId == _me) continue;
      out.putIfAbsent(s.ownerId, () => []).add(s);
    }
    return {for (final e in out.entries) e.key: _sorted(e.value)};
  }

  /// Owners for the stories row (muted ones last and apart).
  List<String> get owners => orderOwners(byOwner).where((o) => !_muted.contains(o)).toList();
  List<String> get mutedWithStories => orderOwners(byOwner).where(_muted.contains).toList();

  bool hasUnseen(String owner) => byOwner[owner]?.any((s) => !s.seen) ?? false;

  /// Who has viewed our story [storyId].
  Set<String> viewersOf(String storyId) => _views[storyId] ?? const {};

  static List<Story> _sorted(Iterable<Story> list) => list.toList()..sort((a, b) => a.created.compareTo(b.created));

  /// Loads stored stories and starts listening (after sign-in).
  Future<void> start(String me, {required String deviceId}) async {
    _me = me;
    _myDevice = deviceId;
    _stories.clear();
    _views.clear();
    for (final row in await _storage.kvSealedByPrefix('story:')) {
      final s = Story.fromJson(jsonDecode(row.value));
      if (s != null) _stories[s.id] = s;
    }
    for (final row in await _storage.kvSealedByPrefix('story_views:')) {
      _views[row.key.substring('story_views:'.length)] = {for (final v in jsonDecode(row.value) as List) '$v'};
    }
    try {
      _muted = {for (final m in jsonDecode(await _storage.kvGet('stories_muted') ?? '[]') as List) '$m'};
    } catch (_) {
      _muted = {};
    }
    _audience = StoryAudience.decode(await _storage.kvGet('story_audience'));
    await sweepExpired();
    _subs
      ..add(_directory.onStoryPosted.listen((_) => unawaited(refresh())))
      ..add(_chat.onStoryViewed.listen((v) => unawaited(_viewed(v.$1, v.$2))));
    _sweep = Timer.periodic(const Duration(minutes: 1), (_) => unawaited(sweepExpired()));
    notifyListeners();
    unawaited(refresh());
  }

  void stop() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    _sweep?.cancel();
    _me = null;
    _stories.clear();
    _views.clear();
    notifyListeners();
  }

  /// Fetches story keys for this device and opens the new ones.
  Future<void> refresh() async {
    if (_me == null || _refreshing) return;
    _refreshing = true;
    try {
      var changed = false;
      for (final row in await _directory.fetchStories()) {
        final id = row['story_id'] as String?;
        final owner = row['owner_id'] as String?;
        if (id == null || owner == null || _stories.containsKey(id)) continue;
        final payload = await _chat.openStoryEnvelope(row['envelope'] as String);
        final p = payload?.story;
        if (payload == null || p == null || p['id'] != id || payload.from != owner) continue;
        final s = Story.fromPayload(owner, payload.timestampMs, p);
        if (s.expiredAt(DateTime.now())) continue;
        await _save(s);
        changed = true;
      }
      if (changed) notifyListeners();
    } catch (e) {
      debugPrint('Stories not refreshed: $e');
    } finally {
      _refreshing = false;
    }
  }

  /// Posts a text story to [contacts] (narrowed by the audience setting).
  Future<Story> postText(String text, int color, {required Iterable<String> contacts}) {
    final t = text.trim();
    if (t.isEmpty || t.length > maxText) throw ArgumentError('A text story has 1-$maxText characters');
    return _post(type: 'text', text: t, color: color, contacts: contacts);
  }

  /// Posts a photo or video story. Photos are re-encoded (at most
  /// [maxPhotoSide] px, no metadata such as location).
  Future<Story> postMedia(Uint8List bytes,
      {required bool video, String? caption, String? name, String? mime, required Iterable<String> contacts}) async {
    final data = video ? bytes : await compute(shrinkPhoto, bytes);
    final meta = await _chat.attachments.upload(data,
        name: name ?? (video ? 'story.mp4' : 'story.jpg'),
        mime: mime ?? (video ? 'video/mp4' : 'image/jpeg'),
        forceUpload: true);
    final c = caption?.trim();
    return _post(
        type: video ? 'video' : 'photo',
        caption: c == null || c.isEmpty ? null : c,
        attachment: meta,
        contacts: contacts);
  }

  /// A photo as a JPEG of at most [maxPhotoSide] px, without metadata.
  static Uint8List shrinkPhoto(Uint8List input) {
    final decoded = img.decodeImage(input);
    if (decoded == null) throw const FormatException('Not an image');
    final oriented = img.bakeOrientation(decoded);
    final big = oriented.width > oriented.height ? oriented.width : oriented.height;
    final scaled = big <= maxPhotoSide
        ? oriented
        : img.copyResize(oriented,
            width: oriented.width >= oriented.height ? maxPhotoSide : null,
            height: oriented.height > oriented.width ? maxPhotoSide : null);
    scaled.exif = img.ExifData();
    return Uint8List.fromList(img.encodeJpg(scaled, quality: 82));
  }

  Future<Story> _post({
    required String type,
    String? text,
    int? color,
    String? caption,
    Map<String, dynamic>? attachment,
    required Iterable<String> contacts,
  }) async {
    final me = _me;
    if (me == null) throw StateError('Not signed in');
    final now = DateTime.now();
    final story = Story(
      id: _uuid.v4(),
      ownerId: me,
      created: now,
      expires: now.add(lifetime),
      type: type,
      text: text,
      color: color,
      caption: caption,
      attachment: attachment == null ? null : (Map.of(attachment)..removeWhere((k, _) => k.startsWith('local_'))),
      seen: true,
    );
    final envelopes = <String, String>{};
    // The audience, plus our own other devices.
    for (final user in [..._audience.resolve(contacts), me]) {
      try {
        final able = <String>{
          for (final d in await _directory.getUserDevices(user))
            if ((d['capabilities'] as List?)?.contains('stories') == true) d['device_id'] as String,
        };
        if (user == me) able.remove(_myDevice);
        if (able.isEmpty) continue;
        // Addressed to each recipient (receivers check that).
        final payload =
            WirePayload.story(from: me, to: user, timestampMs: now.millisecondsSinceEpoch, story: story.toPayload());
        envelopes.addAll(await _chat.sealForDevices(user, able, payload));
      } catch (e) {
        debugPrint('Story not sealed for $user: $e');
      }
    }
    if (envelopes.isNotEmpty) {
      final ids = attachment?['id'] is String ? [attachment!['id'] as String] : const <String>[];
      await _directory.postStory(story.id, envelopes, attachmentIds: ids);
    }
    await _save(story);
    notifyListeners();
    return story;
  }

  /// We looked at [s]: mark it seen and tell its owner.
  Future<void> markSeen(Story s) async {
    if (s.seen || s.ownerId == _me) return;
    s.seen = true;
    await _save(s);
    notifyListeners();
    try {
      await _chat.sendStoryViewed(s.ownerId, s.id);
    } catch (e) {
      debugPrint('Story view not sent: $e');
    }
  }

  Future<void> _viewed(String viewer, String storyId) async {
    final s = _stories[storyId];
    if (s == null || s.ownerId != _me) return;
    final set = _views.putIfAbsent(storyId, () => {});
    if (!set.add(viewer)) return;
    await _storage.kvSetSealed('story_views:$storyId', jsonEncode(set.toList()));
    notifyListeners();
  }

  /// Deletes one of our stories before it expires (also on the server).
  Future<void> deleteMine(Story s) async {
    if (s.ownerId != _me) return;
    try {
      await _directory.deleteStory(s.id);
    } on ApiException catch (e) {
      if (e.status != 404) rethrow;
    }
    await _forget(s.id);
    notifyListeners();
  }

  Future<void> setMuted(String owner, bool muted) async {
    muted ? _muted.add(owner) : _muted.remove(owner);
    await _storage.kvSet('stories_muted', jsonEncode(_muted.toList()));
    notifyListeners();
  }

  Future<void> setAudience(StoryAudience a) async {
    _audience = a;
    await _storage.kvSet('story_audience', a.encode());
    notifyListeners();
  }

  /// Forgets expired stories (and their view lists).
  Future<void> sweepExpired() async {
    final now = DateTime.now();
    final gone = _stories.values.where((s) => s.expiredAt(now)).map((s) => s.id).toList();
    for (final id in gone) {
      await _forget(id);
    }
    if (gone.isNotEmpty) notifyListeners();
  }

  Future<void> _save(Story s) async {
    _stories[s.id] = s;
    await _storage.kvSetSealed('story:${s.id}', jsonEncode(s.toJson()));
  }

  Future<void> _forget(String id) async {
    _stories.remove(id);
    _views.remove(id);
    await _storage.kvDelete('story:$id');
    await _storage.kvDelete('story_views:$id');
  }

  /// The photo or video of [s] (decrypted).
  Future<Uint8List> media(Story s) => _chat.attachments.load(s.attachment!);

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
