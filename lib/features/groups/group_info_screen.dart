import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/chat/group_state.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/chat/chat_names.dart';
import 'package:securelyhello/features/groups/contact_checklist.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/action_menu.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';

/// What the info screen asks the chat to do when it closes.
enum GroupInfoResult { message, left, deleted }

/// Members, admins and settings of a group. Pops with a [GroupInfoResult]
/// (and, for [GroupInfoResult.message], the person to message).
class GroupInfoScreen extends StatefulWidget {
  const GroupInfoScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

enum _MemberAction { message, makeAdmin, dismissAdmin, remove }

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    context.read<ChatProvider>().refreshGroupMembers(widget.conversationId);
  }

  Future<void> _run(Future<void> Function() change, String failure) async {
    setState(() => _busy = true);
    try {
      await change();
    } catch (e) {
      if (mounted) showAppSnackBar(context, friendlyError(e.toString(), fallback: failure), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename(GroupState g) async {
    final controller = TextEditingController(text: g.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Group name'),
        content: TextField(
          key: const ValueKey('group-rename-input'),
          controller: controller,
          autofocus: true,
          maxLength: GroupState.maxName,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;
    final chat = context.read<ChatProvider>();
    await _run(() => chat.renameGroup(widget.conversationId, name), "Couldn't rename the group");
  }

  Future<void> _add(GroupState g) async {
    final picked = await Navigator.of(context).push<Set<String>>(MaterialPageRoute(
      builder: (_) => _AddMembersScreen(exclude: g.members.toSet(), room: GroupState.maxMembers - g.members.length),
    ));
    if (picked == null || picked.isEmpty || !mounted) return;
    final chat = context.read<ChatProvider>();
    await _run(() => chat.addGroupMembers(widget.conversationId, picked.toList()), "Couldn't add them");
  }

  Future<void> _memberMenu(GroupState g, String userId, String name, bool isContact) async {
    final chat = context.read<ChatProvider>();
    final iAmAdmin = g.isAdmin(chat.myUserId ?? '');
    final action = await showActionMenu<_MemberAction>(
      context,
      header: ListTile(title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700))),
      items: [
        if (isContact)
          const ActionItem(value: _MemberAction.message, icon: LucideIcons.messageCircle, label: 'Message'),
        if (iAmAdmin && !g.isAdmin(userId))
          const ActionItem(value: _MemberAction.makeAdmin, icon: LucideIcons.shieldCheck, label: 'Make group admin'),
        if (iAmAdmin && g.isAdmin(userId))
          const ActionItem(value: _MemberAction.dismissAdmin, icon: LucideIcons.shieldOff, label: 'Dismiss as admin'),
        if (iAmAdmin)
          const ActionItem(
              value: _MemberAction.remove, icon: LucideIcons.userMinus, label: 'Remove from group', destructive: true),
      ],
    );
    if (!mounted || action == null) return;
    final id = widget.conversationId;
    switch (action) {
      case _MemberAction.message:
        Navigator.pop(context, (GroupInfoResult.message, userId));
      case _MemberAction.makeAdmin:
        await _run(() => chat.setGroupAdmin(id, userId, true), "Couldn't make them an admin");
      case _MemberAction.dismissAdmin:
        await _run(() => chat.setGroupAdmin(id, userId, false), "Couldn't change that");
      case _MemberAction.remove:
        final ok = await showConfirmDialog(context,
            title: 'Remove $name?',
            message: "They won't get new messages in this group.",
            confirmLabel: 'Remove',
            destructive: true);
        if (ok) await _run(() => chat.removeGroupMember(id, userId), "Couldn't remove them");
    }
  }

  Future<void> _leave(GroupState g) async {
    final ok = await showConfirmDialog(context,
        title: 'Leave “${g.name}”?',
        message: "You won't get new messages from this group. Its history stays on this device.",
        confirmLabel: 'Leave',
        destructive: true);
    if (!ok || !mounted) return;
    final chat = context.read<ChatProvider>();
    await _run(() => chat.leaveGroup(widget.conversationId), "Couldn't leave the group");
    if (mounted && !(chat.groupOf(widget.conversationId)?.isMember(chat.myUserId ?? '') ?? false)) {
      Navigator.pop(context, (GroupInfoResult.left, null));
    }
  }

  Future<void> _delete(GroupState g) async {
    final ok = await showConfirmDialog(context,
        title: 'Delete “${g.name}”?',
        message: 'Its messages will be deleted from this device.',
        confirmLabel: 'Delete',
        destructive: true);
    if (!ok || !mounted) return;
    await context.read<ChatProvider>().deleteConversation(widget.conversationId);
    if (mounted) Navigator.pop(context, (GroupInfoResult.deleted, null));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final chat = context.watch<ChatProvider>();
    final contacts = context.watch<ContactsProvider>();
    final g = chat.groupOf(widget.conversationId);
    if (g == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('This group is not on this device')));
    }
    final me = chat.myUserId ?? '';
    final member = g.isMember(me);
    final admin = g.isAdmin(me);
    // You first, then admins, then everyone else in join order.
    final people = [
      if (member) me,
      ...g.members.where((u) => u != me && g.isAdmin(u)),
      ...g.members.where((u) => u != me && !g.isAdmin(u)),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Group info')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (_busy) const LinearProgressIndicator(),
          const SizedBox(height: 20),
          Center(
            child: AvatarWidget(
              displayName: g.name,
              seed: widget.conversationId,
              icon: LucideIcons.users,
              size: AvatarSize.xlarge,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  g.name,
                  key: const ValueKey('group-info-name'),
                  textAlign: TextAlign.center,
                  style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              if (admin)
                IconButton(
                  key: const ValueKey('group-rename'),
                  tooltip: 'Rename group',
                  icon: Icon(LucideIcons.pencil, size: 18, color: p.textSecondary),
                  onPressed: _busy ? null : () => _rename(g),
                ),
            ],
          ),
          Text(
            'Group · ${g.members.length} ${g.members.length == 1 ? 'member' : 'members'}',
            textAlign: TextAlign.center,
            style: t.bodyMedium?.copyWith(color: p.textSecondary),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
            child: Text(
              'Messages and the group name are end-to-end encrypted. The server knows who is in the group.',
              textAlign: TextAlign.center,
              style: t.bodySmall?.copyWith(color: p.textMuted, height: 1.4),
            ),
          ),
          if (!member)
            Container(
              key: const ValueKey('group-not-member'),
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: p.border),
              ),
              child: Text("You're no longer in this group.", style: t.bodyMedium),
            ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              '${g.members.length} MEMBERS',
              style: t.labelMedium?.copyWith(color: p.accent, fontWeight: FontWeight.w700, letterSpacing: 0.9),
            ),
          ),
          if (admin && g.members.length < GroupState.maxMembers)
            ListTile(
              key: const ValueKey('group-add'),
              leading: CircleAvatar(
                radius: 22,
                backgroundColor: p.accent,
                child: Icon(LucideIcons.userPlus, color: p.onAccent, size: 20),
              ),
              title: const Text('Add members'),
              onTap: _busy ? null : () => _add(g),
            ),
          for (final u in people)
            ListTile(
              key: ValueKey('member-$u'),
              leading: AvatarWidget(displayName: personName(chat, contacts, u), seed: u, ringColor: p.background),
              title: Text(u == me ? 'You' : personName(chat, contacts, u), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: u == me
                  ? null
                  : Text(contacts.getContact(u) != null ? '@${contacts.getContact(u)!.username}' : 'Not in your contacts'),
              trailing: g.isAdmin(u)
                  ? Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: p.accentContainer,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Text('Admin', style: t.labelSmall?.copyWith(color: p.onAccentContainer)),
                    )
                  : null,
              onTap: u == me || _busy || (!admin && contacts.getContact(u) == null)
                  ? null
                  : () => _memberMenu(g, u, personName(chat, contacts, u), contacts.getContact(u) != null),
            ),
          const SizedBox(height: 12),
          if (member)
            ListTile(
              key: const ValueKey('group-leave'),
              leading: Icon(LucideIcons.logOut, color: p.danger),
              title: Text('Leave group', style: TextStyle(color: p.danger)),
              onTap: _busy ? null : () => _leave(g),
            )
          else
            ListTile(
              key: const ValueKey('group-delete'),
              leading: Icon(LucideIcons.trash2, color: p.danger),
              title: Text('Delete group chat', style: TextStyle(color: p.danger)),
              onTap: _busy ? null : () => _delete(g),
            ),
        ],
      ),
    );
  }
}

class _AddMembersScreen extends StatefulWidget {
  const _AddMembersScreen({required this.exclude, required this.room});

  final Set<String> exclude;
  final int room;

  @override
  State<_AddMembersScreen> createState() => _AddMembersScreenState();
}

class _AddMembersScreenState extends State<_AddMembersScreen> {
  Set<String> _picked = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add members'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              key: const ValueKey('group-add-confirm'),
              onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, _picked),
              child: Text(_picked.isEmpty ? 'Add' : 'Add ${_picked.length}'),
            ),
          ),
        ],
      ),
      body: ContactChecklist(
        selected: _picked,
        exclude: widget.exclude,
        limit: widget.room,
        onChanged: (s) => setState(() => _picked = s),
      ),
    );
  }
}
