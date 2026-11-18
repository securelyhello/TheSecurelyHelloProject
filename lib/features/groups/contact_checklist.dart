import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/chat/group_state.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/search_field.dart';

/// Contacts with checkboxes, for picking group members. People in
/// [exclude] (already members) aren't listed.
class ContactChecklist extends StatefulWidget {
  const ContactChecklist({
    super.key,
    required this.selected,
    required this.onChanged,
    this.exclude = const {},
    this.limit = GroupState.maxMembers - 1,
  });

  /// The initial selection; the checklist keeps its own from then on.
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  final Set<String> exclude;

  /// How many more people the group can take.
  final int limit;

  @override
  State<ContactChecklist> createState() => _ContactChecklistState();
}

class _ContactChecklistState extends State<ContactChecklist> {
  final _search = TextEditingController();
  String _query = '';
  // Kept here rather than read back from the parent, so two quick taps
  // before a rebuild both count.
  late final Set<String> _selected = {...widget.selected};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id) && _selected.length < widget.limit) _selected.add(id);
    });
    widget.onChanged(Set.of(_selected));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final provider = context.watch<ContactsProvider>();
    final q = _query.trim().toLowerCase();
    final contacts = provider.contacts
        .where((c) => !widget.exclude.contains(c.userId))
        .where((c) => q.isEmpty || c.displayLabel.toLowerCase().contains(q) || c.username.toLowerCase().contains(q))
        .toList();
    final full = _selected.length >= widget.limit;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: SearchField(
            controller: _search,
            hint: 'Search contacts',
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        if (full)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('A group can have up to ${GroupState.maxMembers} people.',
                style: t.bodySmall?.copyWith(color: p.warning)),
          ),
        Expanded(
          child: contacts.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      q.isNotEmpty
                          ? 'No contacts match “$_query”.'
                          : widget.exclude.isEmpty
                              ? 'Groups are made from your contacts. Add someone first.'
                              : 'All your contacts are already in this group.',
                      textAlign: TextAlign.center,
                      style: t.bodyMedium?.copyWith(color: p.textSecondary),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: contacts.length,
                  itemBuilder: (context, i) {
                    final c = contacts[i];
                    final on = _selected.contains(c.userId);
                    return CheckboxListTile(
                      key: ValueKey('pick-${c.username}'),
                      value: on,
                      onChanged: on || !full ? (_) => _toggle(c.userId) : null,
                      secondary: AvatarWidget(displayName: c.displayLabel, seed: c.userId, ringColor: p.background),
                      title: Text(c.displayLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('@${c.username}', maxLines: 1, overflow: TextOverflow.ellipsis),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
