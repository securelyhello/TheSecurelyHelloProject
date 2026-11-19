import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/home/chat_navigation.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';

/// Shows who sent the invite [token] and, if the user agrees, adds them as a
/// contact and opens the chat.
Future<void> openInvite(BuildContext context, String token) async {
  final contacts = context.read<ContactsProvider>();
  Map<String, dynamic> info;
  try {
    info = await contacts.inviteInfo(token);
  } catch (e) {
    if (context.mounted) showAppSnackBar(context, friendlyError(e.toString()), error: true);
    return;
  }
  if (!context.mounted) return;
  final inviter = Map<String, dynamic>.from(info['inviter'] as Map);
  final id = inviter['user_id'] as String;
  final username = inviter['username'] as String? ?? '';
  final name = (inviter['display_name'] as String?)?.trim().isNotEmpty == true
      ? inviter['display_name'] as String
      : '@$username';
  if (info['own'] == true) {
    showAppSnackBar(context, 'That is your own invite link. Send it to someone else.');
    return;
  }
  if (info['already_contacts'] == true) {
    showAppSnackBar(context, '$name is already a contact');
    return;
  }
  final ok = await showInviteSheet(context, userId: id, name: name, username: username);
  if (ok != true || !context.mounted) return;
  try {
    await contacts.acceptInvite(token);
    if (!context.mounted) return;
    showAppSnackBar(context, '$name added');
    openChat(context, id);
  } catch (e) {
    if (context.mounted) showAppSnackBar(context, friendlyError(e.toString()), error: true);
  }
}

/// A compact, dismissible sheet asking whether to add the inviter. Returns
/// true to accept, false for "Not now", null when dismissed.
Future<bool?> showInviteSheet(
  BuildContext context, {
  required String userId,
  required String name,
  required String username,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) => InviteCard(userId: userId, name: name, username: username),
  );
}

/// The content of [showInviteSheet].
class InviteCard extends StatelessWidget {
  const InviteCard({super.key, required this.userId, required this.name, required this.username});

  final String userId;
  final String name;
  final String username;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    return SingleChildScrollView(
      key: const ValueKey('invite-dialog'),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AvatarWidget(displayName: name, seed: userId, size: AvatarSize.large),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Add $name?',
                        maxLines: 2, overflow: TextOverflow.ellipsis, style: t.titleLarge),
                    if (username.isNotEmpty)
                      Text('@$username',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodyMedium?.copyWith(color: p.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.shieldCheck, size: 18, color: p.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'They invited you to chat. You will be contacts right away. '
                  "Compare safety numbers in their contact info to be sure it's really them.",
                  style: t.bodyMedium?.copyWith(color: p.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Not now'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const ValueKey('invite-accept'),
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Add contact'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
