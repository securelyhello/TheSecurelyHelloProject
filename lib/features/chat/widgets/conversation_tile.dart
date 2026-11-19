import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/utils/chat_time_format.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/chat_chips.dart';
import 'package:securelyhello/shared/widgets/message_status_icon.dart';

/// One row of the chat list.
class ConversationTile extends StatelessWidget {
  const ConversationTile({
    super.key,
    required this.contactUserId,
    required this.name,
    required this.isOnline,
    required this.lastMessage,
    required this.lastMessageTime,
    required this.unreadCount,
    this.isTyping = false,
    this.lastOwnStatus,
    this.lastIsSystem = false,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.isGroup = false,
    this.pinned = false,
    this.muted = false,
    this.draft,
  });

  final bool pinned;
  final bool muted;

  /// Typed and not sent: shown instead of the last message.
  final String? draft;

  final String contactUserId;
  final bool isGroup;
  final String name;
  final bool isOnline;
  final String? lastMessage;
  final DateTime? lastMessageTime;
  final int unreadCount;
  final bool isTyping;

  /// Delivery status of the last message when it is one of ours; `null` when
  /// the last message is incoming or unknown.
  final MessageStatus? lastOwnStatus;

  /// The last entry is a local notice (e.g. safety number changed).
  final bool lastIsSystem;

  /// Highlighted as the open conversation (two-pane layout).
  final bool selected;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final unread = unreadCount > 0;

    final Widget preview;
    if (isTyping) {
      preview = Row(
        children: [
          Text(
            'typing',
            style: t.bodyMedium?.copyWith(
              color: p.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 5),
          TypingDots(color: p.accent, size: 4.5),
        ],
      );
    } else if (draft != null && draft!.trim().isNotEmpty) {
      preview = Text.rich(
        TextSpan(children: [
          TextSpan(text: 'Draft: ', style: TextStyle(color: p.danger, fontWeight: FontWeight.w600)),
          TextSpan(text: draft!.replaceAll('\n', ' ')),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: t.bodyMedium?.copyWith(color: p.textSecondary),
      );
    } else if (lastMessage == null || lastMessage!.isEmpty) {
      preview = Text(
        'No messages yet',
        maxLines: 1,
        style: t.bodyMedium?.copyWith(
          color: p.textMuted,
          fontStyle: FontStyle.italic,
        ),
      );
    } else {
      preview = Row(
        children: [
          if (lastOwnStatus != null) ...[
            MessageStatusIcon(
              status: lastOwnStatus!,
              color: p.textMuted,
              readColor: p.tickRead,
              errorColor: p.danger,
              size: 16,
            ),
            const SizedBox(width: 3),
          ] else if (lastIsSystem) ...[
            Icon(LucideIcons.shieldAlert, size: 14, color: p.warning),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              lastMessage!.replaceAll('\n', ' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.bodyMedium?.copyWith(
                color: unread ? p.textPrimary : p.textSecondary,
                fontWeight: unread ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ),
        ],
      );
    }

    return Semantics(
      selected: selected,
      label: [
        name,
        if (unread) '$unreadCount unread',
        if (isTyping) 'typing',
      ].join(', '),
      child: Material(
        color: selected ? p.selection : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTapDown: onSecondaryTapDown,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                AvatarWidget(
                  displayName: name,
                  seed: contactUserId,
                  isOnline: isOnline,
                  icon: isGroup ? LucideIcons.users : null,
                  size: AvatarSize.list,
                  ringColor: selected ? p.selection : p.background,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.titleMedium?.copyWith(
                                fontSize: 16,
                                fontWeight: unread
                                    ? FontWeight.w800
                                    : FontWeight.w700,
                              ),
                            ),
                          ),
                          if (lastMessageTime != null) ...[
                            const SizedBox(width: 8),
                            Text(
                              ChatTimeFormat.listTimestamp(
                                lastMessageTime!,
                                use24h: use24h,
                              ),
                              style: t.labelSmall?.copyWith(
                                fontSize: 12,
                                color: unread ? p.accent : p.textMuted,
                                fontWeight: unread
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Expanded(
                            child: AnimatedSwitcher(
                              duration: AppMotion.fast,
                              layoutBuilder: (current, previous) => Stack(
                                alignment: Alignment.centerLeft,
                                children: [...previous, ?current],
                              ),
                              child: KeyedSubtree(
                                key: ValueKey(isTyping),
                                child: preview,
                              ),
                            ),
                          ),
                          if (muted) ...[
                            const SizedBox(width: 6),
                            Icon(LucideIcons.bellOff, size: 15, color: p.textMuted, semanticLabel: 'muted'),
                          ],
                          if (pinned) ...[
                            const SizedBox(width: 6),
                            Icon(LucideIcons.pin, size: 15, color: p.textMuted, semanticLabel: 'pinned'),
                          ],
                          if (unread) ...[
                            const SizedBox(width: 8),
                            UnreadBadge(count: unreadCount),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
