import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';

/// People you blocked. They can't find or reach you until you unblock them.
class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    context.read<ContactsProvider>().loadBlocked().whenComplete(() {
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<ContactsProvider>();
    final blocked = contacts.blockedUsers;
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : blocked.isEmpty
              ? const Center(child: Text("You haven't blocked anyone."))
              : ListView(
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
                      child: Text(
                        "Blocked people can't find you, send you messages or contact requests, "
                        'or call you. They are not told.',
                      ),
                    ),
                    for (final b in blocked)
                      ListTile(
                        key: ValueKey('blocked-${b['user_id']}'),
                        leading: AvatarWidget(
                          displayName: b['display_name'] as String? ?? '?',
                          seed: b['user_id'] as String,
                        ),
                        title: Text(b['display_name'] as String? ?? ''),
                        subtitle: Text('@${b['username']}'),
                        trailing: TextButton.icon(
                          icon: const Icon(LucideIcons.lockOpen, size: 16),
                          label: const Text('Unblock'),
                          onPressed: () async {
                            final ok = await contacts.unblockUser(b['user_id'] as String);
                            if (context.mounted) {
                              showAppSnackBar(context,
                                  ok ? '${b['display_name']} unblocked' : 'Could not unblock',
                                  error: !ok);
                            }
                          },
                        ),
                      ),
                  ],
                ),
    );
  }
}
