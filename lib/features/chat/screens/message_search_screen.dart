import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/home/chat_navigation.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/utils/chat_time_format.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/empty_state.dart';
import 'package:securelyhello/shared/widgets/search_field.dart';

/// Searches messages on this device: in one chat ([chatId]) or in all of
/// them. Nothing leaves the device; messages are decrypted here.
class MessageSearchScreen extends StatefulWidget {
  const MessageSearchScreen({super.key, this.chatId, this.title});

  final String? chatId;
  final String? title;

  @override
  State<MessageSearchScreen> createState() => _MessageSearchScreenState();
}

class _MessageSearchScreenState extends State<MessageSearchScreen> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<Message> _hits = const [];
  bool _searching = false;
  String _last = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _run(v));
  }

  Future<void> _run(String v) async {
    final q = v.trim();
    _last = q;
    if (q.isEmpty) {
      setState(() => _hits = const []);
      return;
    }
    setState(() => _searching = true);
    final hits = await context.read<ChatProvider>().service.searchMessages(q, chatId: widget.chatId);
    if (!mounted || _last != q) return;
    setState(() {
      _hits = hits;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final chat = context.watch<ChatProvider>();
    final contacts = context.watch<ContactsProvider>();
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    String chatName(String id) => chat.groupOf(id)?.name ?? contacts.getContact(id)?.displayLabel ?? 'Chat';
    return Scaffold(
      appBar: AppBar(title: Text(widget.title == null ? 'Search messages' : 'Search in ${widget.title}')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: SearchField(
              key: const ValueKey('message-search'), controller: _q, hint: 'Search messages', onChanged: _changed),
        ),
        if (_searching) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _q.text.trim().isEmpty
              ? EmptyStateWidget(
                  icon: LucideIcons.search,
                  title: 'Search your messages',
                  subtitle: 'Search happens on this device. Your messages never leave it.',
                )
              : _hits.isEmpty && !_searching
                  ? EmptyStateWidget.noSearchResults(query: _q.text.trim())
                  : ListView.builder(
                      itemCount: _hits.length,
                      itemBuilder: (_, i) {
                        final m = _hits[i];
                        return ListTile(
                          leading: AvatarWidget(
                              displayName: chatName(m.conversationId),
                              seed: m.conversationId,
                              icon: chat.isGroup(m.conversationId) ? LucideIcons.users : null),
                          title: Text(chatName(m.conversationId), maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: _Snippet(text: m.content.isEmpty ? (m.attachment?['name'] as String? ?? '') : m.content, query: _q.text.trim()),
                          trailing: Text(ChatTimeFormat.listTimestamp(m.timestamp, use24h: use24h),
                              style: t.labelSmall?.copyWith(color: p.textMuted)),
                          onTap: () {
                            Navigator.of(context).popUntil((r) => r.isFirst);
                            openChat(context, m.conversationId);
                          },
                        );
                      },
                    ),
        ),
      ]),
    );
  }
}

/// The text around the first match, the match in bold.
class _Snippet extends StatelessWidget {
  const _Snippet({required this.text, required this.query});
  final String text;
  final String query;

  @override
  Widget build(BuildContext context) {
    final i = text.toLowerCase().indexOf(query.toLowerCase());
    if (i < 0) return Text(text, maxLines: 2, overflow: TextOverflow.ellipsis);
    final start = i > 30 ? i - 30 : 0;
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: '${start > 0 ? '…' : ''}${text.substring(start, i)}'),
        TextSpan(
            text: text.substring(i, i + query.length),
            style: TextStyle(fontWeight: FontWeight.w700, color: context.palette.accent)),
        TextSpan(text: text.substring(i + query.length)),
      ]),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Starred messages from every chat.
class StarredMessagesScreen extends StatefulWidget {
  const StarredMessagesScreen({super.key});

  @override
  State<StarredMessagesScreen> createState() => _StarredMessagesScreenState();
}

class _StarredMessagesScreenState extends State<StarredMessagesScreen> {
  List<Message>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await context.read<ChatProvider>().service.starredMessages();
    if (mounted) setState(() => _items = items);
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final contacts = context.watch<ContactsProvider>();
    final items = _items;
    String chatName(String id) => chat.groupOf(id)?.name ?? contacts.getContact(id)?.displayLabel ?? 'Chat';
    return Scaffold(
      appBar: AppBar(title: const Text('Starred messages')),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? EmptyStateWidget(
                  icon: LucideIcons.star,
                  title: 'No starred messages',
                  subtitle: 'Hold a message and tap Star to keep it here.',
                )
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final m = items[i];
                    return ListTile(
                      leading: const Icon(LucideIcons.star),
                      title: Text(m.content.isEmpty ? (m.attachment?['name'] as String? ?? 'Attachment') : m.content,
                          maxLines: 3, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${chatName(m.conversationId)} · ${ChatTimeFormat.listTimestamp(m.timestamp)}'),
                      trailing: IconButton(
                        tooltip: 'Unstar',
                        icon: const Icon(LucideIcons.starOff),
                        onPressed: () async {
                          await chat.setStarred(m, false);
                          await _load();
                        },
                      ),
                      onTap: () {
                        Navigator.of(context).popUntil((r) => r.isFirst);
                        openChat(context, m.conversationId);
                      },
                    );
                  },
                ),
    );
  }
}
