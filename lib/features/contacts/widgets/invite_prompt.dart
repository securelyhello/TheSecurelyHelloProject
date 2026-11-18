import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/home/chat_navigation.dart';
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
  final name = (inviter['display_name'] as String?)?.trim().isNotEmpty == true
      ? inviter['display_name'] as String
      : '@${inviter['username']}';
  if (info['own'] == true) {
    showAppSnackBar(context, 'That is your own invite link. Send it to someone else.');
    return;
  }
  if (info['already_contacts'] == true) {
    showAppSnackBar(context, '$name is already a contact');
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('invite-dialog'),
      icon: AvatarWidget(displayName: name, seed: id),
      title: Text('Add $name?'),
      content: Text(
        '@${inviter['username']} invited you to chat on Securely Hello. You will be '
        'contacts right away. Compare safety numbers in their contact info to be sure '
        "it's really them.",
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
        FilledButton(
          key: const ValueKey('invite-accept'),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Add contact'),
        ),
      ],
    ),
  );
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
