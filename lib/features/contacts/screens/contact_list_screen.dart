import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/contacts/widgets/contact_info_sheet.dart';
import 'package:securelyhello/features/home/chat_navigation.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/utils/chat_time_format.dart';
import 'package:securelyhello/shared/widgets/action_menu.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/chat_chips.dart';
import 'package:securelyhello/shared/widgets/empty_state.dart';
import 'package:securelyhello/shared/widgets/search_field.dart';
import 'package:securelyhello/shared/widgets/skeleton_loader.dart';

/// Home tab: the user's contacts, with incoming requests at the top.
class ContactListScreen extends StatefulWidget {
  const ContactListScreen({super.key});

  @override
  State<ContactListScreen> createState() => _ContactListScreenState();
}

enum _ContactAction { message, info, remove }

class _ContactListScreenState extends State<ContactListScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _message(Contact c) async {
    try {
      await context.read<ChatProvider>().getOrCreateConversation(c.userId);
    } catch (_) {
      // The chat screen still works; the row is created on first message.
    }
    if (mounted) openChat(context, c.userId);
  }

  Future<void> _info(Contact c) async {
    final result = await showContactInfoSheet(
      context,
      c,
      showMessageAction: true,
    );
    if (!mounted) return;
    if (result == ContactSheetAction.message) {
      await _message(c);
    } else if (result == ContactSheetAction.removed) {
      closeChatIfOpen(context, c.userId);
    }
  }

  Future<void> _remove(Contact c) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Remove ${c.displayLabel}?',
      message:
          'They will be removed from your contacts. Your chat history on '
          'this device stays until you delete it.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final provider = context.read<ContactsProvider>();
    final success = await provider.removeContact(c.userId);
    if (!mounted) return;
    if (success) {
      closeChatIfOpen(context, c.userId);
      showAppSnackBar(context, '${c.displayLabel} removed from contacts');
    } else {
      showAppSnackBar(
        context,
        friendlyError(
          provider.errorMessage,
          fallback: 'Could not remove contact',
        ),
        error: true,
      );
    }
  }

  Future<void> _menu(Contact c, {Offset? position}) async {
    final action = await showActionMenu<_ContactAction>(
      context,
      position: position,
      header: position != null
          ? null
          : ListTile(
              leading: AvatarWidget(
                displayName: c.displayLabel,
                seed: c.userId,
              ),
              title: Text(
                c.displayLabel,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text('@${c.username}'),
            ),
      items: const [
        ActionItem(
          value: _ContactAction.message,
          icon: LucideIcons.messageCircle,
          label: 'Message',
        ),
        ActionItem(
          value: _ContactAction.info,
          icon: LucideIcons.shieldCheck,
          label: 'Contact info & safety number',
        ),
        ActionItem(
          value: _ContactAction.remove,
          icon: LucideIcons.userMinus,
          label: 'Remove contact',
          destructive: true,
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case _ContactAction.message:
        await _message(c);
      case _ContactAction.info:
        await _info(c);
      case _ContactAction.remove:
        await _remove(c);
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final provider = context.watch<ContactsProvider>();
    final requests = provider.receivedRequests.length;
    final pendingSent = provider.sentRequests.length;

    final q = _query.trim().toLowerCase();
    final filtered = provider.contacts
        .where(
          (c) =>
              q.isEmpty ||
              c.displayLabel.toLowerCase().contains(q) ||
              c.username.toLowerCase().contains(q),
        )
        .toList();
    final online = filtered.where((c) => c.isOnline).toList();
    final offline = filtered.where((c) => !c.isOnline).toList();

    final loading = provider.isLoading && provider.contacts.isEmpty;
    final loadError =
        provider.contacts.isEmpty &&
        !provider.isLoading &&
        provider.errorMessage?.startsWith('Failed to load contacts') == true;

    Widget contactTile(Contact c) => ListTile(
      leading: AvatarWidget(
        displayName: c.displayLabel,
        seed: c.userId,
        isOnline: c.isOnline,
        ringColor: p.background,
      ),
      title: Text(
        c.displayLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
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
      trailing: IconButton(
        tooltip: 'Message ${c.displayLabel}',
        icon: Icon(LucideIcons.messageCircle, color: p.accent, size: 20),
        onPressed: () => _message(c),
      ),
      onTap: () => _info(c),
      onLongPress: () => _menu(c),
    );

    Widget withRightClick(Contact c) => GestureDetector(
      onSecondaryTapDown: (d) => _menu(c, position: d.globalPosition),
      child: contactTile(c),
    );

    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: SearchField(
            controller: _search,
            hint: 'Search contacts',
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: ListTile(
          leading: CircleAvatar(
            radius: 22,
            backgroundColor: p.accent,
            child: Icon(LucideIcons.userPlus, color: p.onAccent, size: 20),
          ),
          title: const Text(
            'Find people',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: const Text('Search by username'),
          onTap: () => Navigator.pushNamed(context, '/add-contact'),
        ),
      ),
      SliverToBoxAdapter(
        child: ListTile(
          leading: CircleAvatar(
            radius: 22,
            backgroundColor: requests > 0 ? p.accentContainer : p.inputFill,
            child: Icon(
              LucideIcons.inbox,
              color: requests > 0 ? p.onAccentContainer : p.textSecondary,
              size: 20,
            ),
          ),
          title: const Text(
            'Contact requests',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            requests > 0
                ? '$requests waiting for you'
                : pendingSent > 0
                ? '$pendingSent sent, awaiting reply'
                : 'No pending requests',
          ),
          trailing: requests > 0
              ? UnreadBadge(count: requests)
              : Icon(LucideIcons.chevronRight, color: p.textMuted, size: 20),
          onTap: () => Navigator.pushNamed(context, '/contact-requests'),
        ),
      ),
      const SliverToBoxAdapter(child: Divider()),
    ];

    if (loading) {
      slivers.add(SliverToBoxAdapter(child: SkeletonLoader.contactList()));
    } else if (loadError) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyStateWidget.error(
            title: "Couldn't load contacts",
            message: friendlyError(provider.errorMessage),
            onRetry: provider.loadContacts,
          ),
        ),
      );
    } else if (provider.contacts.isEmpty) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyStateWidget.noContacts(
            onAction: () => Navigator.pushNamed(context, '/add-contact'),
          ),
        ),
      );
    } else if (filtered.isEmpty) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyStateWidget.noSearchResults(query: _query.trim()),
        ),
      );
    } else {
      if (online.isNotEmpty) {
        slivers
          ..add(
            SliverToBoxAdapter(
              child: SectionHeader('Online — ${online.length}'),
            ),
          )
          ..add(
            SliverList.builder(
              itemCount: online.length,
              itemBuilder: (_, i) => withRightClick(online[i]),
            ),
          );
      }
      if (offline.isNotEmpty) {
        slivers
          ..add(
            SliverToBoxAdapter(
              child: SectionHeader(
                online.isEmpty
                    ? 'Contacts — ${offline.length}'
                    : 'Offline — ${offline.length}',
              ),
            ),
          )
          ..add(
            SliverList.builder(
              itemCount: offline.length,
              itemBuilder: (_, i) => withRightClick(offline[i]),
            ),
          );
      }
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 88)));
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Contacts'),
            if (!loading && provider.contacts.isNotEmpty)
              Text(
                '${provider.contactCount} '
                '${provider.contactCount == 1 ? 'contact' : 'contacts'}'
                ' · ${provider.onlineCount} online',
                style: t.bodySmall?.copyWith(color: p.textSecondary),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'add-contact-fab',
        tooltip: 'Find people',
        onPressed: () => Navigator.pushNamed(context, '/add-contact'),
        child: const Icon(LucideIcons.userPlus),
      ),
      body: RefreshIndicator(
        onRefresh: provider.loadContacts,
        child: Scrollbar(
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: slivers,
          ),
        ),
      ),
    );
  }
}
