import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/chat/group_state.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/features/groups/contact_checklist.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';

/// Name a group and pick its first members. Pops with the new group's
/// conversation id.
class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key});

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _name = TextEditingController();
  Set<String> _members = {};
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _ready => _name.text.trim().isNotEmpty && _members.isNotEmpty && !_busy;

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final id = await context.read<ChatProvider>().createGroup(_name.text, _members.toList());
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, friendlyError(e.toString(), fallback: "Couldn't create the group"), error: true);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('New group'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              key: const ValueKey('group-create'),
              onPressed: _ready ? _create : null,
              child: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Create'),
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              key: const ValueKey('group-name'),
              controller: _name,
              autofocus: true,
              maxLength: GroupState.maxName,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Group name',
                prefixIcon: Icon(LucideIcons.users),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _members.isEmpty
                  ? 'Choose who to add. The group and everything said in it is end-to-end encrypted.'
                  : '${_members.length} selected',
              style: t.bodySmall?.copyWith(color: p.textSecondary),
            ),
          ),
          Expanded(
            child: ContactChecklist(
              selected: _members,
              onChanged: (s) => setState(() => _members = s),
            ),
          ),
        ],
      ),
    );
  }
}
