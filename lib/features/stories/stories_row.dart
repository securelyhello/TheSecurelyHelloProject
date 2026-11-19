import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/core/stories/story_service.dart';
import 'package:securelyhello/features/stories/story_composer.dart';
import 'package:securelyhello/features/stories/story_viewer.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';

/// The stories row at the top of the chat list: "My story" first, then
/// contacts with stories, a ring round the ones not seen yet.
class StoriesRowSliver extends StatelessWidget {
  const StoriesRowSliver({super.key});

  @override
  Widget build(BuildContext context) {
    final stories = context.watch<StoryService?>();
    if (stories == null) return const SliverToBoxAdapter(child: SizedBox.shrink());
    final contacts = context.watch<ContactsProvider>();
    final me = context.read<AuthProvider>();
    final owners = stories.owners;
    final mine = stories.mine;
    return SliverToBoxAdapter(
      child: SizedBox(
        key: const ValueKey('stories-row'),
        height: 106,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          children: [
            _StoryBubble(
              key: const ValueKey('my-story'),
              name: 'My story',
              seed: me.myUserId ?? '',
              displayName: me.displayName,
              ring: mine.isEmpty ? _Ring.none : _Ring.seen,
              add: true,
              onTap: () => mine.isEmpty
                  ? openStoryComposer(context)
                  : openStoryViewer(context, owners: [me.myUserId!], mine: true),
              onLongPress: () => openStoryComposer(context),
            ),
            for (var i = 0; i < owners.length; i++)
              _StoryBubble(
                key: ValueKey('story-owner-${owners[i]}'),
                name: contacts.getContact(owners[i])?.displayLabel ?? 'Contact',
                seed: owners[i],
                displayName: contacts.getContact(owners[i])?.displayLabel ?? '?',
                ring: stories.hasUnseen(owners[i]) ? _Ring.unseen : _Ring.seen,
                onTap: () => openStoryViewer(context, owners: owners, start: i),
              ),
          ],
        ),
      ),
    );
  }
}

enum _Ring { none, seen, unseen }

class _StoryBubble extends StatelessWidget {
  const _StoryBubble({
    super.key,
    required this.name,
    required this.seed,
    required this.displayName,
    required this.ring,
    required this.onTap,
    this.onLongPress,
    this.add = false,
  });

  final String name;
  final String seed;
  final String displayName;
  final _Ring ring;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool add;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final gradient = switch (ring) {
      _Ring.unseen => LinearGradient(
          colors: [p.accent, Color.lerp(p.accent, const Color(0xFFFFB347), 0.7)!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      _Ring.seen => LinearGradient(colors: [p.border, p.border]),
      _Ring.none => null,
    };
    return Semantics(
      button: true,
      label: ring == _Ring.unseen ? '$name, new story' : name,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: SizedBox(
          width: 76,
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(shape: BoxShape.circle, gradient: gradient),
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(shape: BoxShape.circle, color: p.background),
                      child: AvatarWidget(displayName: displayName, seed: seed, size: AvatarSize.list),
                    ),
                  ),
                  if (add)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: p.accent,
                          shape: BoxShape.circle,
                          border: Border.all(color: p.background, width: 2),
                        ),
                        child: Icon(LucideIcons.plus, size: 13, color: p.onAccent),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontWeight: ring == _Ring.unseen ? FontWeight.w700 : FontWeight.w500,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
