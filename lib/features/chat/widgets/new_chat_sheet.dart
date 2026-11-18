import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/utils/chat_time_format.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/search_field.dart';

/// What [showNewChatSheet] returns when "New group" was chosen.
const newGroupChoice = '#new-group';

/// Contact picker for starting a conversation.
///
/// Resolves to the chosen contact's user id, [newGroupChoice], or `null`
/// (dismissed, or the user went to "Find people" instead).
Future<String?> showNewChatSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) =>
        const FractionallySizedBox(heightFactor: 0.88, child: _NewChatSheet()),
  );
}

class _NewChatSheet extends StatefulWidget {
  const _NewChatSheet();

  @override
  State<_NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<_NewChatSheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final provider = context.watch<ContactsProvider>();
    final q = _query.trim().toLowerCase();
    final contacts = provider.contacts
        .where(
          (c) =>
              q.isEmpty ||
              c.displayLabel.toLowerCase().contains(q) ||
              c.username.toLowerCase().contains(q),
        )
        .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'New chat',
                  style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(LucideIcons.x),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SearchField(
            controller: _search,
            hint: 'Search contacts',
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              ListTile(
                key: const ValueKey('new-group'),
                leading: CircleAvatar(
                  radius: 22,
                  backgroundColor: p.accent,
                  child: Icon(LucideIcons.users, color: p.onAccent, size: 20),
                ),
                title: const Text('New group'),
                subtitle: const Text('Chat with several contacts at once'),
                onTap: () => Navigator.pop(context, newGroupChoice),
              ),
              ListTile(
                leading: CircleAvatar(
                  radius: 22,
                  backgroundColor: p.accent,
                  child: Icon(
                    LucideIcons.userPlus,
                    color: p.onAccent,
                    size: 20,
                  ),
                ),
                title: const Text('Find people'),
                subtitle: const Text('Search by username and send a request'),
                onTap: () {
                  final nav = Navigator.of(context);
                  nav.pop();
                  nav.pushNamed('/add-contact');
                },
              ),
              if (provider.isLoading && provider.contacts.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (contacts.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    q.isEmpty
                        ? 'You have no contacts yet. Use “Find people” to add '
                              'someone.'
                        : 'No contacts match “$_query”.',
                    textAlign: TextAlign.center,
                    style: t.bodyMedium?.copyWith(color: p.textSecondary),
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'CONTACTS',
                    style: t.labelMedium?.copyWith(
                      color: p.accent,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.9,
                    ),
                  ),
                ),
                for (final c in contacts)
                  ListTile(
                    leading: AvatarWidget(
                      displayName: c.displayLabel,
                      seed: c.userId,
                      isOnline: c.isOnline,
                      ringColor: p.elevated,
                    ),
                    title: Text(
                      c.displayLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      c.isOnline
                          ? 'online'
                          : '@${c.username} · '
                                '${ChatTimeFormat.lastSeen(c.lastSeen, use24h: use24h)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: c.isOnline ? TextStyle(color: p.online) : null,
                    ),
                    onTap: () => Navigator.pop(context, c.userId),
                  ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      ],
    );
  }
}
