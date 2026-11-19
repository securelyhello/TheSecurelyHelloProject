import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/core/stories/story_service.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/utils/chat_time_format.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';

/// Opens the stories of [owners] from [start] (and on through the next
/// owners), or our own with [mine].
Future<void> openStoryViewer(BuildContext context, {required List<String> owners, int start = 0, bool mine = false}) {
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: true,
    pageBuilder: (_, _, _) => StoryViewer(owners: owners, start: start, mine: mine),
    transitionsBuilder: (_, a, _, child) =>
        FadeTransition(opacity: a, child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(a), child: child)),
  ));
}

/// Full-screen stories: progress bars, tap right/left for next/previous,
/// hold to pause, swipe down to close. Others' stories have a reply field
/// and quick reactions (sent as chat messages quoting the story); our own
/// show who has seen them and can be deleted.
class StoryViewer extends StatefulWidget {
  const StoryViewer({super.key, required this.owners, this.start = 0, this.mine = false});

  final List<String> owners;
  final int start;
  final bool mine;

  @override
  State<StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends State<StoryViewer> with SingleTickerProviderStateMixin {
  static const photoDuration = Duration(seconds: 6);
  static const reactions = ['❤️', '😂', '😮', '😢', '👏', '🔥'];

  late int _owner = widget.start;
  int _index = 0;
  late final AnimationController _progress = AnimationController(vsync: this, duration: photoDuration)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _next();
    });
  final _reply = TextEditingController();
  final _replyFocus = FocusNode();
  Uint8List? _media;
  VideoPlayerController? _video;
  File? _videoFile;
  bool _loading = false;
  String? _loadedId;

  StoryService get _stories => context.read<StoryService>();

  List<Story> _storiesOf(StoryService s, String owner) => widget.mine ? s.mine : (s.byOwner[owner] ?? const []);

  @override
  void initState() {
    super.initState();
    _replyFocus.addListener(() => _replyFocus.hasFocus ? _progress.stop() : _progress.forward());
    WidgetsBinding.instance.addPostFrameCallback((_) => _show());
  }

  @override
  void dispose() {
    _progress.dispose();
    _reply.dispose();
    _replyFocus.dispose();
    unawaited(_disposeVideo());
    super.dispose();
  }

  Future<void> _disposeVideo() async {
    final v = _video;
    _video = null;
    await v?.dispose();
    final f = _videoFile;
    _videoFile = null;
    try {
      if (f != null && f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  Story? get _current {
    if (_owner >= widget.owners.length) return null;
    final list = _storiesOf(_stories, widget.owners[_owner]);
    return _index < list.length ? list[_index] : null;
  }

  /// Shows the current story: loads its media, starts the timer, marks it seen.
  Future<void> _show() async {
    final s = _current;
    if (s == null) {
      if (mounted) Navigator.of(context).maybePop();
      return;
    }
    _progress
      ..stop()
      ..reset();
    await _disposeVideo();
    setState(() {
      _media = null;
      _loading = s.type != 'text';
      _loadedId = s.id;
    });
    unawaited(_stories.markSeen(s));
    if (s.type == 'text') {
      _progress.duration = photoDuration;
      unawaited(_progress.forward());
      return;
    }
    try {
      final bytes = await _stories.media(s);
      if (!mounted || _loadedId != s.id) return;
      if (s.type == 'video' && _videoSupported) {
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/story-${s.id}.mp4')..writeAsBytesSync(bytes, flush: true);
        final v = VideoPlayerController.file(f);
        await v.initialize();
        if (!mounted || _loadedId != s.id) {
          await v.dispose();
          return;
        }
        _videoFile = f;
        _video = v;
        final d = v.value.duration;
        _progress.duration = d > Duration.zero && d < const Duration(seconds: 60) ? d : const Duration(seconds: 30);
        await v.play();
      } else {
        _progress.duration = photoDuration;
      }
      setState(() {
        _media = bytes;
        _loading = false;
      });
      unawaited(_progress.forward());
    } catch (e) {
      debugPrint('Story media failed: $e');
      if (!mounted) return;
      setState(() => _loading = false);
      _progress.duration = const Duration(seconds: 3);
      unawaited(_progress.forward());
    }
  }

  static bool get _videoSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  void _next() {
    final list = _storiesOf(_stories, widget.owners[_owner]);
    if (_index + 1 < list.length) {
      _index++;
    } else if (!widget.mine && _owner + 1 < widget.owners.length) {
      _owner++;
      _index = 0;
    } else {
      Navigator.of(context).maybePop();
      return;
    }
    unawaited(_show());
  }

  void _previous() {
    if (_index > 0) {
      _index--;
    } else if (_owner > 0 && !widget.mine) {
      _owner--;
      _index = _storiesOf(_stories, widget.owners[_owner]).length - 1;
    } else {
      _progress.reset();
      unawaited(_progress.forward());
      return;
    }
    unawaited(_show());
  }

  void _pause() {
    _progress.stop();
    unawaited(_video?.pause());
  }

  void _resume() {
    if (_replyFocus.hasFocus) return;
    unawaited(_progress.forward());
    unawaited(_video?.play());
  }

  /// A reply or reaction: a chat message to the owner quoting the story.
  Future<void> _send(String text) async {
    final s = _current;
    if (s == null || text.trim().isEmpty) return;
    final chat = context.read<ChatProvider>();
    final quote = switch (s.type) {
      'text' => 'Story: ${s.text}',
      'photo' => '📷 Story${s.caption == null ? '' : ': ${s.caption}'}',
      _ => '🎬 Story${s.caption == null ? '' : ': ${s.caption}'}',
    };
    final ok = await chat.sendMessage(s.ownerId, text,
        replyTo: {'id': 'story:${s.id}', 'from': s.ownerId, 'preview': quote});
    if (!mounted) return;
    _reply.clear();
    _replyFocus.unfocus();
    showAppSnackBar(context, ok ? 'Sent' : 'Not sent', error: !ok, success: ok);
  }

  Future<void> _showViewers(Story s) async {
    _pause();
    final contacts = context.read<ContactsProvider>();
    final viewers = _stories.viewersOf(s.id).toList();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(viewers.isEmpty ? 'Nobody has seen it yet' : 'Seen by ${viewers.length}',
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            for (final v in viewers)
              ListTile(
                leading: AvatarWidget(displayName: contacts.getContact(v)?.displayLabel ?? '?', seed: v),
                title: Text(contacts.getContact(v)?.displayLabel ?? 'Contact'),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    _resume();
  }

  Future<void> _menu(Story s) async {
    _pause();
    final stories = _stories;
    final mine = widget.mine;
    final muted = stories.mutedOwners.contains(s.ownerId);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (mine)
            ListTile(
              key: const ValueKey('story-delete'),
              leading: const Icon(LucideIcons.trash2),
              title: const Text('Delete this story'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            )
          else
            ListTile(
              leading: Icon(muted ? LucideIcons.bell : LucideIcons.bellOff),
              title: Text(muted ? 'Unmute their stories' : 'Mute their stories'),
              onTap: () => Navigator.pop(ctx, 'mute'),
            ),
        ]),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'delete':
        await stories.deleteMine(s);
        if (!mounted) return;
        if (stories.mine.isEmpty) {
          Navigator.of(context).maybePop();
        } else {
          _index = _index.clamp(0, stories.mine.length - 1);
          unawaited(_show());
        }
      case 'mute':
        await stories.setMuted(s.ownerId, !muted);
        _resume();
      default:
        _resume();
    }
  }

  @override
  Widget build(BuildContext context) {
    final stories = context.watch<StoryService>();
    final contacts = context.watch<ContactsProvider>();
    final s = _current;
    if (s == null) return const Scaffold(backgroundColor: Colors.black);
    final list = _storiesOf(stories, widget.owners[_owner]);
    final name = widget.mine ? 'My story' : (contacts.getContact(s.ownerId)?.displayLabel ?? 'Contact');
    final t = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;

    return Scaffold(
      key: const ValueKey('story-viewer'),
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      body: GestureDetector(
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) Navigator.of(context).maybePop();
        },
        onLongPressStart: (_) => _pause(),
        onLongPressEnd: (_) => _resume(),
        onTapUp: (d) => d.localPosition.dx < width / 3 ? _previous() : _next(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _content(s, t),
            // Legibility over bright photos.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x99000000), Colors.transparent, Colors.transparent, Color(0x99000000)],
                  stops: [0, 0.18, 0.75, 1],
                ),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                    child: Row(children: [
                      for (var i = 0; i < list.length; i++)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: AnimatedBuilder(
                                animation: _progress,
                                builder: (_, _) => LinearProgressIndicator(
                                  minHeight: 3,
                                  value: i < _index ? 1 : (i == _index ? _progress.value : 0),
                                  backgroundColor: Colors.white30,
                                  valueColor: const AlwaysStoppedAnimation(Colors.white),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ]),
                  ),
                  ListTile(
                    leading: AvatarWidget(displayName: name, seed: s.ownerId, size: AvatarSize.small),
                    title: Text(name, style: t.titleSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
                    subtitle: Text(ChatTimeFormat.relative(s.created),
                        style: t.bodySmall?.copyWith(color: Colors.white70)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: 'More',
                        onPressed: () => _menu(s),
                        icon: const Icon(LucideIcons.ellipsisVertical, color: Colors.white),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(LucideIcons.x, color: Colors.white),
                      ),
                    ]),
                  ),
                  const Spacer(),
                  if (s.caption != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      child: Text(s.caption!,
                          textAlign: TextAlign.center, style: t.bodyLarge?.copyWith(color: Colors.white)),
                    ),
                  if (widget.mine) _viewersBar(stories, s, t) else _replyBar(t),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(Story s, TextTheme t) {
    if (s.type == 'text') {
      return Container(
        color: Color(s.color ?? 0xFF2E7D6B),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(32),
        child: Text(
          s.text ?? '',
          textAlign: TextAlign.center,
          style: t.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700, height: 1.3),
        ),
      );
    }
    if (_loading) return const Center(child: CircularProgressIndicator(color: Colors.white));
    if (s.type == 'video') {
      final v = _video;
      if (v != null && v.value.isInitialized) {
        return Center(child: AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v)));
      }
      return Center(
        child: Text(_videoSupported ? "This video can't be played" : 'Videos play on your phone',
            style: t.bodyLarge?.copyWith(color: Colors.white70)),
      );
    }
    final m = _media;
    if (m == null) {
      return Center(child: Text("This photo couldn't be loaded", style: t.bodyLarge?.copyWith(color: Colors.white70)));
    }
    return Image.memory(m, fit: BoxFit.contain, gaplessPlayback: true);
  }

  Widget _replyBar(TextTheme t) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final r in reactions)
                InkResponse(
                  onTap: () => _send(r),
                  radius: 26,
                  child: Padding(padding: const EdgeInsets.all(8), child: Text(r, style: const TextStyle(fontSize: 26))),
                ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            key: const ValueKey('story-reply'),
            controller: _reply,
            focusNode: _replyFocus,
            style: const TextStyle(color: Colors.white),
            textInputAction: TextInputAction.send,
            onSubmitted: _send,
            decoration: InputDecoration(
              hintText: 'Reply…',
              hintStyle: const TextStyle(color: Colors.white70),
              filled: true,
              fillColor: Colors.white12,
              contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.pill), borderSide: BorderSide.none),
              suffixIcon: IconButton(
                tooltip: 'Send',
                onPressed: () => _send(_reply.text),
                icon: const Icon(LucideIcons.sendHorizontal, color: Colors.white),
              ),
            ),
          ),
        ]),
      );

  Widget _viewersBar(StoryService stories, Story s, TextTheme t) {
    final n = stories.viewersOf(s.id).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextButton.icon(
        key: const ValueKey('story-viewers'),
        onPressed: () => _showViewers(s),
        icon: const Icon(LucideIcons.eye, color: Colors.white),
        label: Text(n == 0 ? 'No views yet' : 'Seen by $n', style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}
