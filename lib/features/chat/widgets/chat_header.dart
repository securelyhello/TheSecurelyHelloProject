import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/utils/chat_time_format.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/chat_chips.dart';
import 'package:securelyhello/shared/widgets/connection_badge.dart';

/// App-bar title for a conversation: avatar, name and a live status line
/// (typing… / online / last seen) with a subtle transport indicator.
class ChatHeader extends StatelessWidget {
  const ChatHeader({
    super.key,
    required this.contactUserId,
    required this.contact,
    required this.contactsLoading,
    required this.isTyping,
    required this.transport,
    this.onTap,
  });

  final String contactUserId;
  final Contact? contact;
  final bool contactsLoading;
  final bool isTyping;
  final PeerConnectionState transport;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final c = contact;
    final name = c?.displayLabel ?? (contactsLoading ? '' : 'Unknown contact');

    final Widget status;
    final hasStatus = isTyping || c != null;
    if (isTyping) {
      status = Row(
        key: const ValueKey('typing'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'typing',
            style: t.bodySmall?.copyWith(
              color: p.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          TypingDots(color: p.accent, size: 4),
        ],
      );
    } else {
      final text = c == null
          ? ''
          : c.isOnline
          ? 'online'
          : ChatTimeFormat.lastSeen(c.lastSeen, use24h: use24h);
      status = Text(
        text,
        key: ValueKey(text),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: t.bodySmall?.copyWith(
          color: c?.isOnline == true ? p.online : p.textSecondary,
        ),
      );
    }

    return Semantics(
      button: onTap != null,
      label: onTap != null ? 'Contact info for $name' : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          child: Row(
            children: [
              AvatarWidget(
                displayName: name.isEmpty ? '?' : name,
                seed: contactUserId,
                isOnline: c?.isOnline ?? false,
                size: AvatarSize.medium,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleMedium?.copyWith(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Row(
                      children: [
                        if (hasStatus) ...[
                          Flexible(
                            flex: 2,
                            child: AnimatedSwitcher(
                              duration: AppMotion.fast,
                              layoutBuilder: (current, previous) => Stack(
                                alignment: Alignment.centerLeft,
                                children: [...previous, ?current],
                              ),
                              child: status,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Text(
                              '·',
                              style: t.bodySmall?.copyWith(color: p.textMuted),
                            ),
                          ),
                        ],
                        // Shares the line with the status instead of
                        // squeezing it to nothing on narrow screens.
                        Flexible(child: ConnectionBadge(connectionState: transport)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// App-bar title for a group: its name and who is in it.
class GroupHeader extends StatelessWidget {
  const GroupHeader({
    super.key,
    required this.conversationId,
    required this.name,
    required this.subtitle,
    this.onTap,
  });

  final String conversationId;
  final String name;

  /// Member names, or a note that we left.
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: onTap != null,
      label: onTap != null ? 'Group info for $name' : null,
      child: InkWell(
        key: const ValueKey('group-header'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          child: Row(
            children: [
              AvatarWidget(displayName: name, seed: conversationId, icon: LucideIcons.users, size: AvatarSize.medium),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleMedium?.copyWith(fontSize: 16.5, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(color: p.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
