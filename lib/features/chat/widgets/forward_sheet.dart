import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/search_field.dart';

/// Picks up to [max] chats (recent chats first, then other contacts) to
/// forward a message to. Null when dismissed.
Future<List<String>?> pickForwardTargets(BuildContext context, {String? exclude, int max = 5}) =>
    showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: _ForwardSheet(exclude: exclude, max: max)),
    );

class _ForwardSheet extends StatefulWidget {
  const _ForwardSheet({this.exclude, required this.max});
  final String? exclude;
  final int max;

  @override
  State<_ForwardSheet> createState() => _ForwardSheetState();
}

class _ForwardSheetState extends State<_ForwardSheet> {
  final _picked = <String>[];
  final _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final contacts = context.watch<ContactsProvider>();
    String nameOf(String id) => chat.groupOf(id)?.name ?? contacts.getContact(id)?.displayLabel ?? 'Contact';
    final ids = <String>[
      for (final c in chat.conversations) c.id,
      for (final c in contacts.contacts)
        if (!chat.conversations.any((x) => x.id == c.userId)) c.userId,
    ].where((id) => id != widget.exclude && (_q.isEmpty || nameOf(id).toLowerCase().contains(_q))).toList();
    final full = _picked.length >= widget.max;
    return Column(children: [
      ListTile(
        title: Text('Forward to…', style: Theme.of(context).textTheme.titleLarge),
        trailing: FilledButton.icon(
          key: const ValueKey('forward-send'),
          onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, _picked),
          icon: const Icon(LucideIcons.forward, size: 18),
          label: Text(_picked.isEmpty ? 'Send' : 'Send (${_picked.length})'),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: SearchField(controller: _search, hint: 'Search', onChanged: (v) => setState(() => _q = v.trim().toLowerCase())),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: ids.length,
          itemBuilder: (_, i) {
            final id = ids[i];
            final on = _picked.contains(id);
            return CheckboxListTile(
              key: ValueKey('forward-$id'),
              value: on,
              onChanged: !on && full ? null : (_) => setState(() => on ? _picked.remove(id) : _picked.add(id)),
              secondary: AvatarWidget(
                  displayName: nameOf(id), seed: id, icon: chat.isGroup(id) ? LucideIcons.users : null),
              title: Text(nameOf(id), maxLines: 1, overflow: TextOverflow.ellipsis),
            );
          },
        ),
      ),
    ]);
  }
}
