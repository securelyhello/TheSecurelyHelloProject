import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/chat/chat_service.dart' show Message;
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/connection_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/chat/widgets/attachment_view.dart';
import 'package:securelyhello/features/chat/widgets/chat_header.dart';
import 'package:securelyhello/features/chat/widgets/composer.dart';
import 'package:securelyhello/features/chat/widgets/message_info_sheet.dart';
import 'package:securelyhello/features/contacts/widgets/contact_info_sheet.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/utils/chat_time_format.dart';
import 'package:securelyhello/shared/widgets/action_menu.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/chat_chips.dart';
import 'package:securelyhello/shared/widgets/connection_badge.dart';
import 'package:securelyhello/shared/widgets/message_bubble.dart';
import 'package:securelyhello/shared/widgets/skeleton_loader.dart';

/// A 1:1 conversation.
///
/// Used both as the `/chat` route (phones) and, with [embedded], inside the
/// right-hand pane of the two-pane home layout (wide windows).
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.contactUserId,
    this.embedded = false,
    this.onClose,
  });

  final String contactUserId;

  /// Shown inside the home screen's conversation pane (no back button).
  final bool embedded;

  /// Closes the embedded conversation.
  final VoidCallback? onClose;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

enum _MsgAction { copy, info, retry }

enum _MenuAction { info, connect, clear }

class _ChatScreenState extends State<ChatScreen> {
  /// Unsent text per conversation, kept while the app runs.
  static final Map<String, String> _drafts = {};

  /// The provider pages history in steps of this size.
  static const _pageSize = 50;

  /// Messages closer together than this (same sender, same day) are grouped.
  static const _groupGap = Duration(minutes: 5);

  late final TextEditingController _input = TextEditingController(
    text: _drafts[widget.contactUserId] ?? '',
  );
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();
  late final ChatProvider _chat;
  final DateTime _openedAt = DateTime.now();

  bool _opened = false;
  bool _showJump = false;
  DateTime? _seenUpTo;
  int _initialUnread = 0;
  bool _markerResolved = false;
  String? _unreadMarkerId;
  String? _highlightId;

  String get _id => widget.contactUserId;

  @override
  void initState() {
    super.initState();
    _chat = context.read<ChatProvider>();
    for (final c in _chat.conversations) {
      if (c.contactUserId == _id) _initialUnread = c.unreadCount;
    }
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (Composer.enterSends) _focus.requestFocus();
      await _chat.openConversation(_id);
      if (mounted) setState(() => _opened = true);
    });
  }

  @override
  void dispose() {
    final draft = _input.text;
    if (draft.trim().isEmpty) {
      _drafts.remove(_id);
    } else {
      _drafts[_id] = draft;
    }
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    final chat = _chat;
    final id = _id;
    // Tell the peer we stopped typing (no listener notification).
    chat.onComposerChanged(id, '');
    // Defer so we don't notify listeners while the tree is being torn down.
    // In the two-pane layout the next conversation may already have been
    // opened by then, so only close if this one is still the active one.
    Future.microtask(() {
      if (chat.activeConversationId == id) chat.closeConversation();
    });
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final away = _scroll.offset > 280;
    if (away != _showJump) setState(() => _showJump = away);
    // The list is reversed: the far end is the oldest message.
    if (_scroll.position.extentAfter < 400) {
      _chat.loadOlderMessages(_id);
    }
  }

  void _jumpToBottom({bool animate = true}) {
    if (!_scroll.hasClients) return;
    if (animate && _scroll.offset < 3000) {
      _scroll.animateTo(0, duration: AppMotion.slow, curve: AppMotion.curve);
    } else {
      _scroll.jumpTo(0);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _drafts.remove(_id);
    _jumpToBottom();
    final ok = await _chat.sendMessage(_id, text);
    if (!ok && mounted) {
      showAppSnackBar(
        context,
        friendlyError(_chat.errorMessage, fallback: 'Message not sent'),
        error: true,
      );
    }
  }

  /// Picks a file and sends it, encrypted, with whatever is typed as the
  /// caption.
  Future<void> _attach() async {
    PlatformFile? file;
    try {
      file = await FilePicker.pickFile(dialogTitle: 'Send a file');
    } catch (e) {
      if (mounted) showAppSnackBar(context, 'Could not open files: $e', error: true);
      return;
    }
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    final caption = _input.text.trim();
    _input.clear();
    _drafts.remove(_id);
    _jumpToBottom();
    final ok = await _chat.sendAttachment(_id, bytes: bytes, name: file.name, caption: caption);
    if (!ok && mounted) {
      if (caption.isNotEmpty) _input.text = caption;
      showAppSnackBar(
        context,
        friendlyError(_chat.errorMessage, fallback: 'File not sent'),
        error: true,
      );
    }
  }

  Future<void> _openInfo(Contact? contact) async {
    if (contact == null) {
      showAppSnackBar(context, 'Contact details are not available');
      return;
    }
    final result = await showContactInfoSheet(context, contact);
    if (!mounted) return;
    if (result == ContactSheetAction.removed) _close();
  }

  void _close() {
    if (widget.embedded) {
      widget.onClose?.call();
    } else {
      Navigator.maybePop(context);
    }
  }

  Future<void> _confirmClearChat(String name) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Clear chat history?',
      message:
          'All messages with $name will be deleted from this device. '
          'This cannot be undone.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await _chat.clearConversation(_id);
      if (mounted) showAppSnackBar(context, 'Chat history cleared');
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, 'Could not clear the chat', error: true);
      }
    }
  }

  Future<void> _messageMenu(Message m, {Offset? position}) async {
    setState(() => _highlightId = m.id);
    final failed = m.isFromMe && m.status == 'failed';
    final action = await showActionMenu<_MsgAction>(
      context,
      position: position,
      items: [
        if (failed)
          const ActionItem(
            value: _MsgAction.retry,
            icon: LucideIcons.rotateCw,
            label: 'Retry sending',
          ),
        const ActionItem(
          value: _MsgAction.copy,
          icon: LucideIcons.copy,
          label: 'Copy',
        ),
        const ActionItem(
          value: _MsgAction.info,
          icon: LucideIcons.info,
          label: 'Info',
        ),
      ],
    );
    if (!mounted) return;
    setState(() => _highlightId = null);
    switch (action) {
      case _MsgAction.copy:
        await Clipboard.setData(ClipboardData(text: m.content));
        if (mounted) showAppSnackBar(context, 'Message copied');
      case _MsgAction.info:
        await showMessageInfoSheet(context, m);
      case _MsgAction.retry:
        await _chat.retryFailed();
      case null:
        break;
    }
  }

  PeerConnectionState _transport(P2PConnectionState s) => switch (s) {
    P2PConnectionState.connected => PeerConnectionState.connected,
    P2PConnectionState.connecting => PeerConnectionState.connecting,
    _ => PeerConnectionState.offline,
  };

  /// Finds the oldest of the messages that were unread when the chat was
  /// opened, so an "unread messages" divider can sit above it.
  void _resolveUnreadMarker(List<Message> messages) {
    // Wait for the fresh load: a cached list from an earlier visit may not
    // contain the new messages yet.
    if (_markerResolved || !_opened || messages.isEmpty) return;
    _markerResolved = true;
    if (_initialUnread <= 0) return;
    var seen = 0;
    for (final m in messages) {
      if (m.isFromMe || m.isSystem) continue;
      seen++;
      if (seen == _initialUnread) {
        _unreadMarkerId = m.id;
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final chat = context.watch<ChatProvider>();
    final contacts = context.watch<ContactsProvider>();
    final conn = context.watch<ConnectionProvider>();

    final contact = contacts.getContact(_id);
    final name = contact?.displayLabel ?? 'this contact';
    final messages = chat.getMessages(_id);
    final transport = _transport(conn.getConnectionState(_id));

    _resolveUnreadMarker(messages);
    if (messages.isNotEmpty && !_showJump) {
      _seenUpTo = messages.first.timestamp;
    }
    var newBelow = 0;
    if (_showJump && _seenUpTo != null) {
      for (final m in messages) {
        if (!m.timestamp.isAfter(_seenUpTo!)) break;
        if (!m.isFromMe && !m.isSystem) newBelow++;
      }
    }

    final Widget list;
    if (messages.isEmpty && !_opened) {
      list = SkeletonLoader.messageList();
    } else if (messages.isEmpty) {
      list = _EmptyConversation(
        contact: contact,
        contactUserId: _id,
        onTap: () => _openInfo(contact),
      );
    } else {
      list = _buildList(messages, contact);
    }

    return Scaffold(
      backgroundColor: p.chatBackground,
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        titleSpacing: widget.embedded ? 8 : 0,
        toolbarHeight: 62,
        title: ChatHeader(
          contactUserId: _id,
          contact: contact,
          contactsLoading: contacts.isLoading,
          isTyping: chat.isContactTyping(_id),
          transport: transport,
          onTap: () => _openInfo(contact),
        ),
        actions: [
          PopupMenuButton<_MenuAction>(
            tooltip: 'More options',
            icon: const Icon(LucideIcons.ellipsisVertical),
            onSelected: (v) {
              switch (v) {
                case _MenuAction.info:
                  _openInfo(contact);
                case _MenuAction.connect:
                  conn.reconnect(_id);
                  showAppSnackBar(context, 'Trying a direct connection…');
                case _MenuAction.clear:
                  _confirmClearChat(name);
              }
            },
            itemBuilder: (context) => [
              _menuItem(
                _MenuAction.info,
                LucideIcons.shieldCheck,
                'Contact info & safety number',
              ),
              if (transport == PeerConnectionState.offline)
                _menuItem(
                  _MenuAction.connect,
                  LucideIcons.zap,
                  'Connect directly',
                ),
              if (messages.isNotEmpty)
                _menuItem(
                  _MenuAction.clear,
                  LucideIcons.eraser,
                  'Clear chat history',
                ),
            ],
          ),
          if (widget.embedded)
            IconButton(
              tooltip: 'Close chat (Esc)',
              icon: const Icon(LucideIcons.x),
              onPressed: widget.onClose,
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: list),
                Positioned(
                  right: 14,
                  bottom: 14,
                  child: _JumpToBottomButton(
                    visible: _showJump,
                    count: newBelow,
                    onPressed: _jumpToBottom,
                  ),
                ),
              ],
            ),
          ),
          Composer(
            controller: _input,
            focusNode: _focus,
            onSend: _send,
            onAttach: _attach,
            uploading: context.select<ChatProvider, bool>((c) => c.isUploading(_id)),
            onChanged: (text) => _chat.onComposerChanged(_id, text),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<_MenuAction> _menuItem(
    _MenuAction value,
    IconData icon,
    String label,
  ) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18, color: context.palette.textSecondary),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }

  Widget _buildList(List<Message> messages, Contact? contact) {
    final allLoaded = messages.length % _pageSize != 0;
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      itemCount: messages.length + 1,
      itemBuilder: (context, i) {
        if (i == messages.length) {
          return allLoaded
              ? EncryptionBanner(onTap: () => _openInfo(contact))
              : const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
        }
        return _buildItem(messages, i, contact);
      },
    );
  }

  bool _joins(Message a, Message b) =>
      !a.isSystem &&
      !b.isSystem &&
      a.isFromMe == b.isFromMe &&
      ChatTimeFormat.isSameDay(a.timestamp, b.timestamp) &&
      a.timestamp.difference(b.timestamp).abs() < _groupGap;

  Widget _buildItem(List<Message> messages, int i, Contact? contact) {
    final m = messages[i];
    final older = i + 1 < messages.length ? messages[i + 1] : null;
    final newer = i > 0 ? messages[i - 1] : null;

    final showDate =
        older == null ||
        !ChatTimeFormat.isSameDay(older.timestamp, m.timestamp);
    final showUnread = m.id == _unreadMarkerId;
    final first = older == null || showUnread || !_joins(m, older);
    final last =
        newer == null || newer.id == _unreadMarkerId || !_joins(m, newer);

    final Widget body;
    if (m.isSystem) {
      body = SystemNoticeChip(
        text: m.content,
        onTap: contact == null ? null : () => _openInfo(contact),
      );
    } else {
      final status = MessageStatus.fromString(m.status);
      body = Padding(
        padding: EdgeInsets.only(top: first ? 6 : 2),
        child: MessageBubble(
          attachment: m.attachment == null
              ? null
              : AttachmentView(
                  key: ValueKey('att-${m.id}'),
                  meta: m.attachment!,
                  service: _chat.attachments,
                  isSent: m.isFromMe,
                ),
          message: m.content,
          timestamp: m.timestamp,
          isSent: m.isFromMe,
          status: status,
          isFirstInGroup: first,
          isLastInGroup: last,
          animateIn: m.timestamp.isAfter(_openedAt),
          highlighted: _highlightId == m.id,
          onTap: status == MessageStatus.failed && m.isFromMe
              ? () => _chat.retryFailed()
              : null,
          onLongPress: () => _messageMenu(m),
          onSecondaryTapDown: (d) =>
              _messageMenu(m, position: d.globalPosition),
        ),
      );
    }

    return KeyedSubtree(
      key: ValueKey(m.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showDate)
            DateSeparatorChip(label: ChatTimeFormat.dateSeparator(m.timestamp)),
          if (showUnread) _UnreadDivider(count: _initialUnread),
          body,
        ],
      ),
    );
  }
}

class _UnreadDivider extends StatelessWidget {
  const _UnreadDivider({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(vertical: 5),
      color: p.surface.withAlpha(200),
      alignment: Alignment.center,
      child: Text(
        '$count unread ${count == 1 ? 'message' : 'messages'}',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: p.accent,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _JumpToBottomButton extends StatelessWidget {
  const _JumpToBottomButton({
    required this.visible,
    required this.count,
    required this.onPressed,
  });

  final bool visible;
  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedScale(
        scale: visible ? 1 : 0.6,
        duration: AppMotion.medium,
        curve: AppMotion.curve,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: AppMotion.medium,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Material(
                color: p.elevated,
                shape: CircleBorder(side: BorderSide(color: p.border)),
                elevation: 3,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onPressed,
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(
                      LucideIcons.chevronsDown,
                      size: 20,
                      color: p.textPrimary,
                      semanticLabel: count > 0
                          ? 'Scroll to latest, $count new'
                          : 'Scroll to latest',
                    ),
                  ),
                ),
              ),
              if (count > 0)
                Positioned(
                  top: -6,
                  right: -4,
                  child: UnreadBadge(count: count),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation({
    required this.contact,
    required this.contactUserId,
    required this.onTap,
  });

  final Contact? contact;
  final String contactUserId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final name = contact?.displayLabel ?? 'your contact';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AvatarWidget(
                displayName: contact?.displayLabel ?? '?',
                seed: contactUserId,
                size: AvatarSize.xlarge,
              ),
              const SizedBox(height: 14),
              Text(
                contact?.displayLabel ?? '',
                style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (contact != null && contact!.username.isNotEmpty)
                Text(
                  '@${contact!.username}',
                  style: t.bodyMedium?.copyWith(color: p.textSecondary),
                ),
              const SizedBox(height: 8),
              EncryptionBanner(onTap: contact == null ? null : onTap),
              const SizedBox(height: 4),
              Text(
                'Say hello to $name.',
                style: t.bodyMedium?.copyWith(color: p.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
