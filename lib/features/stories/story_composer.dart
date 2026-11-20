import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/chat/attachment_service.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/core/stories/story_service.dart';
import 'package:securelyhello/features/groups/contact_checklist.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';

/// Asks what kind of story to post, then opens the composer.
Future<void> openStoryComposer(BuildContext context) async {
  final kind = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text('New story', style: Theme.of(ctx).textTheme.titleMedium),
        ),
        ListTile(
          key: const ValueKey('story-new-text'),
          leading: const Icon(LucideIcons.type),
          title: const Text('Text'),
          onTap: () => Navigator.pop(ctx, 'text'),
        ),
        ListTile(
          key: const ValueKey('story-new-photo'),
          leading: const Icon(LucideIcons.image),
          title: const Text('Photo'),
          onTap: () => Navigator.pop(ctx, 'photo'),
        ),
        ListTile(
          leading: const Icon(LucideIcons.clapperboard),
          title: const Text('Video'),
          subtitle: const Text('Up to 16 MB'),
          onTap: () => Navigator.pop(ctx, 'video'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Text('Stories are end-to-end encrypted and disappear after 24 hours.',
              style: Theme.of(ctx).textTheme.bodySmall),
        ),
      ]),
    ),
  );
  if (kind == null || !context.mounted) return;
  Uint8List? bytes;
  String? name;
  if (kind != 'text') {
    try {
      final f = await FilePicker.pickFile(
          dialogTitle: kind == 'photo' ? 'Choose a photo' : 'Choose a video',
          type: kind == 'photo' ? FileType.image : FileType.video);
      if (f == null) return;
      bytes = await f.readAsBytes();
      name = f.name;
    } catch (e) {
      if (context.mounted) showAppSnackBar(context, 'Could not open files: $e', error: true);
      return;
    }
    if (bytes.length > AttachmentService.maxBytes) {
      if (context.mounted) showAppSnackBar(context, 'That file is too large for a story (16 MB at most)', error: true);
      return;
    }
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => StoryComposer(kind: kind, bytes: bytes, fileName: name),
  ));
}

/// Writes a text story on a colour, or adds a caption to a photo or video,
/// and shows who will see it.
class StoryComposer extends StatefulWidget {
  const StoryComposer({super.key, required this.kind, this.bytes, this.fileName});

  final String kind;
  final Uint8List? bytes;
  final String? fileName;

  /// Text story backgrounds: the brand colours (pear, coral, blue, mint, ink,
  /// kraft). Stored as ARGB ints in the story; the viewer renders any int.
  static final colors = <int>[
    AppPalette.light.brand.toARGB32(),
    AppPalette.ember.toARGB32(),
    AppPalette.light.accent.toARGB32(),
    AppPalette.light.avatarColors[3].toARGB32(),
    AppPalette.light.textPrimary.toARGB32(),
    AppPalette.light.avatarColors[4].toARGB32(),
  ];

  /// Colour used when a text story carries no colour.
  static final defaultColor = AppPalette.light.textPrimary.toARGB32();

  /// Ink or cream text, whichever reads better on [background] (any colour:
  /// older stories and other clients use their own).
  static Color onColor(Color background) {
    const dark = AppPalette.dark;
    final ink = dark.onBrand;
    final cream = dark.textPrimary;
    double ratio(Color a, Color b) {
      final l1 = a.computeLuminance(), l2 = b.computeLuminance();
      final hi = l1 > l2 ? l1 : l2, lo = l1 > l2 ? l2 : l1;
      return (hi + 0.05) / (lo + 0.05);
    }

    return ratio(background, ink) >= ratio(background, cream) ? ink : cream;
  }

  @override
  State<StoryComposer> createState() => _StoryComposerState();
}

class _StoryComposerState extends State<StoryComposer> {
  final _text = TextEditingController();
  int _color = 0;
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    final stories = context.read<StoryService>();
    final contacts = [for (final c in context.read<ContactsProvider>().contacts) c.userId];
    setState(() => _sending = true);
    try {
      if (widget.kind == 'text') {
        await stories.postText(_text.text, StoryComposer.colors[_color], contacts: contacts);
      } else {
        await stories.postMedia(widget.bytes!,
            video: widget.kind == 'video', caption: _text.text, name: widget.fileName, contacts: contacts);
      }
      if (!mounted) return;
      showAppSnackBar(context, 'Story posted', success: true);
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      showAppSnackBar(context, friendlyError(e.toString(), fallback: 'Story not posted'), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final stories = context.watch<StoryService>();
    final text = widget.kind == 'text';
    const night = AppPalette.dark;
    final bg = text ? Color(StoryComposer.colors[_color]) : night.background;
    final fg = text ? StoryComposer.onColor(bg) : night.textPrimary;
    final fgMuted = fg.withValues(alpha: 0.7);
    final t = Theme.of(context).textTheme;
    return Scaffold(
      key: const ValueKey('story-composer'),
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: fg,
        iconTheme: IconThemeData(color: fg),
        actionsIconTheme: IconThemeData(color: fg),
        title: Text('New story', style: t.titleLarge?.copyWith(color: fg)),
        actions: [
          if (text)
            IconButton(
              tooltip: 'Colour',
              icon: const Icon(LucideIcons.palette),
              onPressed: () => setState(() => _color = (_color + 1) % StoryComposer.colors.length),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: text
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: TextField(
                          key: const ValueKey('story-text'),
                          controller: _text,
                          autofocus: true,
                          maxLines: null,
                          maxLength: StoryService.maxText,
                          textAlign: TextAlign.center,
                          onChanged: (_) => setState(() {}),
                          style: t.headlineSmall?.copyWith(color: fg),
                          cursorColor: fg,
                          decoration: InputDecoration(
                            hintText: 'Type something…',
                            hintStyle: TextStyle(color: fgMuted),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            counterStyle: TextStyle(color: fgMuted),
                          ),
                        ),
                      ),
                    )
                  : widget.kind == 'photo'
                  ? Image.memory(widget.bytes!, fit: BoxFit.contain)
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.clapperboard, color: fg, size: 56),
                          const SizedBox(height: 10),
                          Text(widget.fileName ?? 'Video', style: t.bodyLarge?.copyWith(color: fg)),
                          Text(
                            AttachmentService.formatSize(widget.bytes!.length),
                            style: t.bodySmall?.copyWith(color: fgMuted),
                          ),
                        ],
                      ),
                    ),
            ),
            if (!text)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: TextField(
                  controller: _text,
                  maxLength: 200,
                  style: TextStyle(color: fg),
                  decoration: InputDecoration(
                    hintText: 'Add a caption…',
                    hintStyle: TextStyle(color: fgMuted),
                    filled: true,
                    fillColor: night.elevated,
                    counterStyle: TextStyle(color: fgMuted),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: ActionChip(
                      key: const ValueKey('story-audience'),
                      avatar: const Icon(LucideIcons.users, size: 16),
                      label: Text(_audienceLabel(stories.audience), overflow: TextOverflow.ellipsis),
                      onPressed: () => pickStoryAudience(context),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FloatingActionButton(
                    key: const ValueKey('story-post'),
                    tooltip: 'Post story',
                    onPressed: _sending || (text && _text.text.trim().isEmpty) ? null : _post,
                    child: _sending
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                        : const Icon(LucideIcons.sendHorizontal),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _audienceLabel(StoryAudience a) => switch (a.mode) {
        AudienceMode.allContacts => 'All contacts',
        AudienceMode.allExcept => 'Contacts except ${a.users.length}',
        AudienceMode.onlyShareWith => 'Only ${a.users.length} ${a.users.length == 1 ? 'person' : 'people'}',
      };
}

/// Who sees your stories: all contacts, all except some, or only some.
Future<void> pickStoryAudience(BuildContext context) async {
  final stories = context.read<StoryService>();
  var mode = stories.audience.mode;
  var users = {...stories.audience.users};
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text('Who sees your stories', style: Theme.of(ctx).textTheme.titleMedium),
            ),
            RadioGroup<AudienceMode>(
              groupValue: mode,
              onChanged: (v) => setSheet(() => mode = v ?? mode),
              child: const Column(children: [
                RadioListTile(value: AudienceMode.allContacts, title: Text('All my contacts')),
                RadioListTile(value: AudienceMode.allExcept, title: Text('My contacts except…')),
                RadioListTile(value: AudienceMode.onlyShareWith, title: Text('Only share with…')),
              ]),
            ),
            if (mode != AudienceMode.allContacts)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  child: ContactChecklist(
                    selected: users,
                    limit: 10000,
                    onChanged: (s) => users = s,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Done')),
            ),
          ]),
        ),
      ),
    ),
  );
  if (ok == true) await stories.setAudience(StoryAudience(mode, mode == AudienceMode.allContacts ? {} : users));
}
