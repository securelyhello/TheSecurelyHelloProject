import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/l10n/app_localizations.dart';
import 'package:securelyhello/core/chat/chat_service.dart'
    show Conversation, Message;
import 'package:securelyhello/core/chat/group_state.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/chat/widgets/conversation_tile.dart';
import 'package:securelyhello/features/groups/group_info_screen.dart';
import 'package:securelyhello/features/groups/new_group_screen.dart';
import 'package:securelyhello/features/chat/widgets/new_chat_sheet.dart';
import 'package:securelyhello/features/contacts/widgets/contact_info_sheet.dart';
import 'package:securelyhello/features/home/chat_navigation.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/action_menu.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/chat_chips.dart';
import 'package:securelyhello/shared/widgets/empty_state.dart';
import 'package:securelyhello/shared/widgets/message_status_icon.dart';
import 'package:securelyhello/shared/widgets/search_field.dart';
import 'package:securelyhello/shared/widgets/skeleton_loader.dart';

/// Home tab: the list of conversations.
class ConversationListScreen extends StatefulWidget {
  const ConversationListScreen({super.key});

  @override
  State<ConversationListScreen> createState() => _ConversationListScreenState();
}

enum _Filter { all, unread }

enum _ConvAction { read, info, clear, delete }

enum _TopMenu { findPeople, requests }

class _ConversationListScreenState extends State<ConversationListScreen> {
  final _search = TextEditingController();
  String _query = '';
  _Filter _filter = _Filter.all;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final chat = context.read<ChatProvider>();
    final contacts = context.read<ContactsProvider>();
    await Future.wait([chat.loadConversations(), contacts.loadContacts()]);
  }

  Future<void> _startChat(String contactUserId) async {
    final chat = context.read<ChatProvider>();
    try {
      await chat.getOrCreateConversation(contactUserId);
    } catch (_) {
      // The chat screen creates the conversation on first send anyway.
    }
    if (mounted) openChat(context, contactUserId);
  }

  Future<void> _newChat() async {
    final id = await showNewChatSheet(context);
    if (id == null || !mounted) return;
    if (id == newGroupChoice) {
      final group = await Navigator.of(context)
          .push<String>(MaterialPageRoute(builder: (_) => const NewGroupScreen()));
      if (group != null && mounted) openChat(context, group);
      return;
    }
    await _startChat(id);
  }

  Future<void> _conversationMenu(
    Conversation conv,
    Contact? contact,
    String name, {
    Offset? position,
  }) async {
    final chat = context.read<ChatProvider>();
    final group = chat.groupOf(conv.id);
    final action = await showActionMenu<_ConvAction>(
      context,
      position: position,
      header: position != null
          ? null
          : ListTile(
              leading: AvatarWidget(
                displayName: name,
                seed: conv.contactUserId,
                icon: group != null ? LucideIcons.users : null,
                size: AvatarSize.medium,
              ),
              title: Text(
                name,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
      items: [
        if (conv.unreadCount > 0)
          ActionItem(
            value: _ConvAction.read,
            icon: LucideIcons.checkCheck,
            label: L10n.of(context).markAsRead,
          ),
        if (group != null)
          const ActionItem(value: _ConvAction.info, icon: LucideIcons.users, label: 'Group info')
        else if (contact != null)
          ActionItem(
            value: _ConvAction.info,
            icon: LucideIcons.user,
            label: L10n.of(context).contactInfo,
          ),
        ActionItem(
          value: _ConvAction.clear,
          icon: LucideIcons.eraser,
          label: L10n.of(context).clearChatHistory,
        ),
        ActionItem(
          value: _ConvAction.delete,
          icon: LucideIcons.trash2,
          label: L10n.of(context).deleteChat,
          destructive: true,
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _ConvAction.read:
        await chat.markConversationAsRead(conv.id);
      case _ConvAction.info when group != null:
        final result = await Navigator.of(context).push<(GroupInfoResult, String?)>(
            MaterialPageRoute(builder: (_) => GroupInfoScreen(conversationId: conv.id)));
        if (!mounted || result == null) return;
        if (result.$1 == GroupInfoResult.message && result.$2 != null) openChat(context, result.$2!);
        if (result.$1 == GroupInfoResult.deleted) closeChatIfOpen(context, conv.id);
      case _ConvAction.info:
        final result = await showContactInfoSheet(
          context,
          contact!,
          showMessageAction: true,
        );
        if (!mounted) return;
        if (result == ContactSheetAction.message) {
          openChat(context, conv.contactUserId);
        } else if ((result == ContactSheetAction.removed || result == ContactSheetAction.blocked)) {
          closeChatIfOpen(context, conv.contactUserId);
        }
      case _ConvAction.clear:
        final ok = await showConfirmDialog(
          context,
          title: 'Clear chat history?',
          message:
              'All messages with $name will be deleted from this device. '
              'The chat stays in your list.',
          confirmLabel: 'Clear',
          destructive: true,
        );
        if (!ok) return;
        await chat.clearConversation(conv.id);
        if (mounted) showAppSnackBar(context, 'Chat history cleared');
      case _ConvAction.delete:
        await _deleteConversation(conv, name, confirmed: false);
    }
  }

  Future<bool> _confirmDelete(String name, {bool group = false}) => showConfirmDialog(
    context,
    title: group ? 'Leave and delete “$name”?' : 'Delete chat with $name?',
    message: group
        ? "You'll leave the group if you're still in it, and its messages will be deleted from this device."
        : 'The conversation and its messages will be deleted from this '
              'device. This cannot be undone.',
    confirmLabel: 'Delete',
    destructive: true,
  );

  Future<void> _deleteConversation(
    Conversation conv,
    String name, {
    required bool confirmed,
  }) async {
    if (!confirmed && !await _confirmDelete(name, group: GroupState.isGroup(conv.id))) return;
    if (!mounted) return;
    final chat = context.read<ChatProvider>();
    closeChatIfOpen(context, conv.contactUserId);
    await chat.deleteConversation(conv.id);
    if (mounted) showAppSnackBar(context, 'Chat deleted');
  }

  /// The delivery tick for the preview, derived from the cached messages
  /// when the conversation's newest message is ours.
  ({MessageStatus? status, bool system}) _lastInfo(
    ChatProvider chat,
    Conversation conv,
  ) {
    final cached = chat.getMessages(conv.id);
    if (cached.isEmpty) return (status: null, system: false);
    final Message newest = cached.first;
    final sameAsPreview =
        newest.content == conv.lastMessage &&
        (conv.lastMessageTime == null ||
            newest.timestamp
                    .difference(conv.lastMessageTime!)
                    .inSeconds
                    .abs() <=
                2);
    if (!sameAsPreview) return (status: null, system: false);
    if (newest.isSystem) return (status: null, system: true);
    return (
      status: newest.isFromMe ? MessageStatus.fromString(newest.status) : null,
      system: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final chat = context.watch<ChatProvider>();
    final contactsProvider = context.watch<ContactsProvider>();
    final selectedId = TwoPaneScope.maybeOf(context)?.selectedContactId;
    final requestCount = contactsProvider.receivedRequests.length;

    final q = _query.trim().toLowerCase();
    bool matches(String? s) => s != null && s.toLowerCase().contains(q);

    final all = chat.conversations;
    final unreadChats = all.where((c) => c.unreadCount > 0).length;
    final visible = all.where((conv) {
      if (_filter == _Filter.unread && conv.unreadCount == 0) return false;
      if (q.isEmpty) return true;
      final c = contactsProvider.getContact(conv.contactUserId);
      return matches(chat.groupOf(conv.id)?.name) ||
          matches(c?.displayLabel) ||
          matches(c?.username) ||
          matches(conv.lastMessage);
    }).toList();

    final convIds = all.map((c) => c.contactUserId).toSet();
    final contactHits = q.isEmpty
        ? const <Contact>[]
        : contactsProvider.contacts
              .where(
                (c) =>
                    !convIds.contains(c.userId) &&
                    (matches(c.displayLabel) || matches(c.username)),
              )
              .toList();

    final loading = chat.isLoading && all.isEmpty;
    final loadError =
        all.isEmpty &&
        !chat.isLoading &&
        (chat.errorMessage?.startsWith('Failed to load conversations') ==
                true ||
            chat.errorMessage?.startsWith('Failed to initialize') == true);

    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: SearchField(
            controller: _search,
            hint: L10n.of(context).searchChats,
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: Text(L10n.of(context).filterAll),
                selected: _filter == _Filter.all,
                showCheckmark: false,
                onSelected: (_) => setState(() => _filter = _Filter.all),
              ),
              ChoiceChip(
                label: Text(
                  unreadChats > 0 ? L10n.of(context).filterUnreadCount(unreadChats) : L10n.of(context).filterUnread,
                ),
                selected: _filter == _Filter.unread,
                showCheckmark: false,
                onSelected: (_) => setState(() => _filter = _Filter.unread),
              ),
            ],
          ),
        ),
      ),
      if (requestCount > 0 && q.isEmpty)
        SliverToBoxAdapter(
          child: ListTile(
            leading: CircleAvatar(
              radius: 26,
              backgroundColor: p.accentContainer,
              child: Icon(
                LucideIcons.userPlus,
                color: p.onAccentContainer,
                size: 22,
              ),
            ),
            title: Text(
              L10n.of(context).contactRequests,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              requestCount == 1
                  ? '1 person wants to connect'
                  : '$requestCount people want to connect',
            ),
            trailing: UnreadBadge(count: requestCount),
            onTap: () => Navigator.pushNamed(context, '/contact-requests'),
          ),
        ),
    ];

    if (loading) {
      slivers.add(SliverToBoxAdapter(child: SkeletonLoader.chatList()));
    } else if (loadError) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyStateWidget.error(
            title: "Couldn't load your chats",
            message: friendlyError(chat.errorMessage),
            onRetry: () => chat.loadConversations(),
          ),
        ),
      );
    } else if (all.isEmpty) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyStateWidget.noMessages(onAction: _newChat),
        ),
      );
    } else if (visible.isEmpty && contactHits.isEmpty) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: q.isNotEmpty
              ? EmptyStateWidget.noSearchResults(query: _query.trim())
              : EmptyStateWidget(
                  icon: LucideIcons.mailCheck,
                  title: "You're all caught up",
                  subtitle: L10n.of(context).noUnreadChats,
                ),
        ),
      );
    } else {
      slivers.add(
        SliverList.builder(
          itemCount: visible.length,
          itemBuilder: (context, i) =>
              _buildTile(chat, contactsProvider, visible[i], selectedId),
        ),
      );
      if (contactHits.isNotEmpty) {
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
              child: Text(
                'CONTACTS',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: p.accent,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9,
                ),
              ),
            ),
          ),
        );
        slivers.add(
          SliverList.builder(
            itemCount: contactHits.length,
            itemBuilder: (context, i) {
              final c = contactHits[i];
              return ListTile(
                leading: AvatarWidget(
                  displayName: c.displayLabel,
                  seed: c.userId,
                  isOnline: c.isOnline,
                  ringColor: p.background,
                ),
                title: Text(c.displayLabel),
                subtitle: Text('@${c.username}'),
                onTap: () => _startChat(c.userId),
              );
            },
          ),
        );
      }
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 88)));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.of(context).tabChats),
        actions: [
          PopupMenuButton<_TopMenu>(
            tooltip: L10n.of(context).moreOptions,
            icon: const Icon(LucideIcons.ellipsisVertical),
            onSelected: (v) {
              switch (v) {
                case _TopMenu.findPeople:
                  Navigator.pushNamed(context, '/add-contact');
                case _TopMenu.requests:
                  Navigator.pushNamed(context, '/contact-requests');
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _TopMenu.findPeople,
                child: Text(L10n.of(context).findPeople),
              ),
              PopupMenuItem(
                value: _TopMenu.requests,
                child: Text(
                  requestCount > 0
                      ? L10n.of(context).contactRequestsCount(requestCount)
                      : L10n.of(context).contactRequests,
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'new-chat-fab',
        tooltip: L10n.of(context).newChat,
        onPressed: _newChat,
        child: const Icon(LucideIcons.squarePen),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: Scrollbar(
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: slivers,
          ),
        ),
      ),
    );
  }

  Widget _buildTile(
    ChatProvider chat,
    ContactsProvider contacts,
    Conversation conv,
    String? selectedId,
  ) {
    final group = chat.groupOf(conv.id);
    final contact = group != null ? null : contacts.getContact(conv.contactUserId);
    final name =
        group?.name ??
        contact?.displayLabel ??
        (contacts.isLoading && contacts.contacts.isEmpty
            ? '…'
            : 'Unknown contact');
    final info = _lastInfo(chat, conv);

    return Dismissible(
      key: ValueKey('conv-${conv.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        color: context.palette.danger,
        child: const Icon(LucideIcons.trash2, color: Colors.white),
      ),
      confirmDismiss: (_) => _confirmDelete(name, group: group != null),
      onDismissed: (_) =>
          unawaited(_deleteConversation(conv, name, confirmed: true)),
      child: ConversationTile(
        contactUserId: conv.contactUserId,
        isGroup: group != null,
        name: name,
        isOnline: contact?.isOnline ?? false,
        lastMessage: conv.lastMessage,
        lastMessageTime: conv.lastMessageTime,
        unreadCount: conv.unreadCount,
        isTyping: chat.isContactTyping(conv.contactUserId),
        lastOwnStatus: info.status,
        lastIsSystem: info.system,
        selected: selectedId == conv.contactUserId,
        onTap: () => openChat(context, conv.contactUserId),
        onLongPress: () => _conversationMenu(conv, contact, name),
        onSecondaryTapDown: (d) =>
            _conversationMenu(conv, contact, name, position: d.globalPosition),
      ),
    );
  }
}
