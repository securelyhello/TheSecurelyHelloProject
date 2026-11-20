import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:securelyhello/core/security/app_lock.dart';
import 'package:securelyhello/features/chat/widgets/forward_sheet.dart';
import 'package:securelyhello/features/chat/screens/message_search_screen.dart';
import 'package:securelyhello/shared/widgets/mute_picker.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/features/chat/widgets/voice_note.dart';
import 'package:securelyhello/core/media/voice.dart';
import 'package:securelyhello/core/chat/chat_service.dart' show ChatService, Message, Verification;
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';
import 'package:securelyhello/core/notifications/notification_service.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/connection_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/core/calls/call_service.dart';
import 'package:securelyhello/core/chat/group_state.dart';
import 'package:securelyhello/features/calls/call_screen.dart';
import 'package:securelyhello/features/chat/chat_names.dart';
import 'package:securelyhello/features/chat/chat_quote.dart';
import 'package:securelyhello/features/chat/widgets/attachment_view.dart';
import 'package:securelyhello/features/chat/widgets/chat_header.dart';
import 'package:securelyhello/features/chat/widgets/composer.dart';
import 'package:securelyhello/features/chat/widgets/message_info_sheet.dart';
import 'package:securelyhello/features/contacts/widgets/contact_info_sheet.dart';
import 'package:securelyhello/features/groups/group_info_screen.dart';
import 'package:securelyhello/features/home/chat_navigation.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/utils/chat_time_format.dart';
import 'package:securelyhello/shared/widgets/action_menu.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/chat_chips.dart';
import 'package:securelyhello/shared/widgets/connection_badge.dart';
import 'package:securelyhello/shared/widgets/message_bubble.dart';
import 'package:securelyhello/shared/widgets/skeleton_loader.dart';

/// A conversation: 1:1 with a contact, or a group.
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

enum _MsgAction { reply, react, copy, star, forward, edit, delete, info, retry }

/// Quick reactions offered in the message menu.
const quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

enum _MenuAction { info, search, mute, secure, timer, connect, clear }

class _ChatScreenState extends State<ChatScreen> {
  /// The provider pages history in steps of this size.
  static const _pageSize = 50;

  /// Messages closer together than this (same sender, same day) are grouped.
  static const _groupGap = Duration(minutes: 5);

  late final TextEditingController _input = TextEditingController();
  AppLockService? _lock;
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

  /// Disappearing-messages timer of this chat (seconds, 0 = off).
  int _timer = 0;

  Future<void> _loadTimer() async {
    final t = await _chat.disappearAfter(_id);
    if (mounted && t != _timer) setState(() => _timer = t);
  }

  Future<void> _chooseTimer() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Disappearing messages'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('New messages in this chat disappear for both of you, on every device, '
                'after the time you choose.'),
          ),
          RadioGroup<int>(
            groupValue: _timer,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final s in ChatService.disappearChoices)
                RadioListTile<int>(
                  key: ValueKey('timer-$s'),
                  value: s,
                  title: Text(ChatService.disappearLabel(s)),
                ),
            ]),
          ),
        ],
      ),
    );
    if (picked == null || picked == _timer) return;
    setState(() => _timer = picked);
    await _chat.setDisappearing(_id, picked);
  }

  /// The message being replied to, or edited, from the composer.
  Message? _replyTo;
  Message? _editing;

  String get _id => widget.contactUserId;
  bool get _isGroup => GroupState.isGroup(_id);

  @override
  void initState() {
    super.initState();
    _chat = context.read<ChatProvider>();
    context.read<NotificationService>().clearFor(_id);
    for (final c in _chat.conversations) {
      if (c.contactUserId == _id) _initialUnread = c.unreadCount;
    }
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (Composer.enterSends) _focus.requestFocus();
      final draft = await _chat.draftOf(_id);
      if (draft != null && mounted && _input.text.isEmpty) {
        _input.text = draft;
        _input.selection = TextSelection.collapsed(offset: draft.length);
      }
      await _chat.openConversation(_id);
      if (mounted) {
        _lock = context.read<AppLockService>();
        unawaited(_lock!.chatOpened(_id));
      }
      _chat.addListener(_loadTimer);
      await _loadTimer();
      if (mounted) setState(() => _opened = true);
    });
  }

  @override
  void dispose() {
    unawaited(_lock?.chatOpened(null));
    // Unsent text is kept per chat (sealed on this device) until sent.
    if (_editing == null) unawaited(_chat.saveDraft(_id, _input.text));
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
    _chat.removeListener(_loadTimer);
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
      _scroll.animateTo(
        0,
        duration: AppMotion.of(context, AppMotion.slow),
        curve: AppMotion.curve,
      );
    } else {
      _scroll.jumpTo(0);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    unawaited(HapticFeedback.lightImpact());
    _input.clear();
    final editing = _editing;
    if (editing != null) {
      setState(() => _editing = null);
      final ok = await _chat.editMessage(_id, editing.id, text);
      if (!ok && mounted) {
        showAppSnackBar(context, 'Messages can only be edited for 24 hours', error: true);
      }
      return;
    }
    final reply = _replyTo;
    setState(() => _replyTo = null);
    _jumpToBottom();
    final ok = await _chat.sendMessage(_id, text,
        replyTo: reply == null ? null : _replyRef(reply));
    if (!ok && mounted) {
      showAppSnackBar(
        context,
        friendlyError(_chat.errorMessage, fallback: 'Message not sent'),
        error: true,
      );
    }
  }

  Map<String, dynamic> _replyRef(Message m) => {
        'id': m.id,
        'from': m.senderId,
        'preview': m.hasAttachment && m.content.isEmpty
            ? ChatService.previewText('', m.attachment)
            : m.content,
      };

  String _authorName(String userId, Contact? contact) => _isGroup
      ? personName(_chat, context.read<ContactsProvider>(), userId)
      : userId == _chat.myUserId
          ? 'You'
          : (contact?.displayLabel ?? 'Them');

  /// Quoted messages not in the loaded page, read from storage (null while
  /// loading or when this device doesn't have them).
  final Map<String, Message?> _quotedFromStorage = {};

  /// This device's copy of the quoted message [id]: from the loaded page,
  /// else from storage (loaded once, then the quote is rebuilt).
  Message? _localQuoted(String id) {
    final inPage = _chat.getMessages(_id).where((m) => m.id == id).firstOrNull;
    if (inPage != null) return inPage;
    if (_quotedFromStorage.containsKey(id)) return _quotedFromStorage[id];
    _quotedFromStorage[id] = null;
    _chat.service.getMessage(id).then((m) {
      if (m != null && mounted) setState(() => _quotedFromStorage[id] = m);
    }).catchError((Object e) => debugPrint('Quoted message not read: $e'));
    return null;
  }

  /// [inSentBubble]: drawn inside one of our pear bubbles (ink on pear); false
  /// inside a card bubble or in the composer header.
  /// A sender's name colour: their avatar colour, pulled towards the text
  /// colour until it reads on a card bubble.
  Color _senderColor(AppPalette p, String senderId) {
    final light = p.background.computeLuminance() > 0.5;
    return Color.lerp(p.avatarColorFor(senderId), p.textPrimary, light ? 0.55 : 0.3)!;
  }

  Widget _quote(
    Map<String, dynamic> r,
    Contact? contact, {
    VoidCallback? onClose,
    bool? inSentBubble,
  }) {
    final p = context.palette;
    final id = r['id'];
    // The local copy (same chat) decides who wrote it and what it says.
    final q = resolveQuote(r, id is String ? _localQuoted(id) : null, conversationId: _id);
    final onPear = inSentBubble == true;
    final bar = onPear ? p.bubbleOutText : p.accent;
    final nameColor = onPear ? p.bubbleOutText : p.accent;
    final textColor = onPear ? p.bubbleOutText : p.textSecondary;
    final fill = onPear
        ? p.bubbleOutText.withAlpha(26)
        : inSentBubble == false
            ? p.textPrimary.withAlpha(16)
            : p.surface;
    return Container(
      key: ValueKey('quote-${r['id']}'),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border(left: BorderSide(color: bar, width: 3)),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_authorName(q.from, contact),
                style: TextStyle(color: nameColor, fontWeight: FontWeight.w600, fontSize: 12.5)),
            Text(q.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: textColor, fontSize: 13)),
          ]),
        ),
        if (onClose != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(LucideIcons.x, size: 18),
            onPressed: onClose,
          ),
      ]),
    );
  }

  Future<void> _pickReaction(Message m, {Offset? position}) async {
    final mine = m.reactions[_chat.myUserId];
    final emoji = await showActionMenu<String>(
      context,
      position: position,
      items: [
        for (final e in quickReactions)
          ActionItem(value: e, icon: LucideIcons.smile, label: e == mine ? '$e  (remove)' : e),
      ],
    );
    if (emoji == null) return;
    unawaited(HapticFeedback.selectionClick());
    await _chat.react(_id, m.id, emoji == mine ? '' : emoji);
  }

  Future<void> _delete(Message m) async {
    final everyone = ChatService.canEdit(m);
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete message?'),
        content: Text(everyone
            ? 'Delete it for everyone in this chat, or only on this device?'
            : 'It will be removed from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'me'), child: const Text('Delete for me')),
          if (everyone)
            TextButton(
              key: const ValueKey('delete-everyone'),
              onPressed: () => Navigator.pop(ctx, 'all'),
              child: const Text('Delete for everyone'),
            ),
        ],
      ),
    );
    if (choice == 'all') {
      await _chat.deleteForEveryone(_id, m.id);
    } else if (choice == 'me') {
      await _chat.deleteForMe(_id, m.id);
    }
  }

  Future<void> _sendVoice(VoiceClip clip) async {
    final ok = await _chat.sendVoiceNote(_id, clip);
    if (!ok && mounted) showAppSnackBar(context, friendlyError(_chat.errorMessage), error: true);
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
    if (_isGroup) return _openGroupInfo();
    if (contact == null) {
      showAppSnackBar(context, 'Contact details are not available');
      return;
    }
    final result = await showContactInfoSheet(context, contact);
    if (!mounted) return;
    if ((result == ContactSheetAction.removed || result == ContactSheetAction.blocked)) _close();
  }

  Future<void> _call({required bool video}) async {
    final calls = context.read<CallService?>();
    if (calls == null) return;
    if (calls.busy) {
      await showCallScreen(context);
      return;
    }
    final starting = calls.start(_id, video: video);
    // The screen opens at once and shows "Ringing…" while the offer goes out.
    unawaited(showCallScreen(context));
    try {
      await starting;
    } catch (e) {
      if (mounted) showAppSnackBar(context, friendlyError(e.toString(), fallback: "Couldn't start the call"), error: true);
    }
  }

  Future<void> _openGroupInfo() async {
    final result = await Navigator.of(context).push<(GroupInfoResult, String?)>(
        MaterialPageRoute(builder: (_) => GroupInfoScreen(conversationId: _id)));
    if (!mounted || result == null) return;
    switch (result.$1) {
      case GroupInfoResult.message:
        if (result.$2 != null) openChat(context, result.$2!);
      case GroupInfoResult.deleted:
        _close();
      case GroupInfoResult.left:
        break;
    }
  }

  void _close() {
    if (widget.embedded) {
      widget.onClose?.call();
    } else {
      Navigator.maybePop(context);
    }
  }

  Future<void> _toggleMute() async {
    final n = context.read<NotificationService>();
    if (n.isMuted(_id)) {
      await n.unmute(_id);
      if (mounted) showAppSnackBar(context, 'Notifications on');
    } else {
      final choice = await pickMuteDuration(context);
      if (choice == null) return;
      await n.mute(_id, choice.duration);
      if (mounted) showAppSnackBar(context, 'Muted: ${choice.label.toLowerCase()}');
    }
    if (mounted) setState(() {});
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
        if (!m.deleted) ...[
          const ActionItem(value: _MsgAction.reply, icon: LucideIcons.reply, label: 'Reply'),
          const ActionItem(value: _MsgAction.react, icon: LucideIcons.smilePlus, label: 'React'),
        ],
        if (!m.deleted && m.content.isNotEmpty)
          const ActionItem(
            value: _MsgAction.copy,
            icon: LucideIcons.copy,
            label: 'Copy',
          ),
        if (!m.deleted && !m.isSystem) ...[
          ActionItem(
              value: _MsgAction.star,
              icon: m.starred ? LucideIcons.starOff : LucideIcons.star,
              label: m.starred ? 'Unstar' : 'Star'),
          const ActionItem(value: _MsgAction.forward, icon: LucideIcons.forward, label: 'Forward'),
        ],
        if (ChatService.canEdit(m) && m.content.isNotEmpty)
          const ActionItem(value: _MsgAction.edit, icon: LucideIcons.pencil, label: 'Edit'),
        const ActionItem(value: _MsgAction.delete, icon: LucideIcons.trash2, label: 'Delete'),
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
      case _MsgAction.reply:
        setState(() {
          _editing = null;
          _replyTo = m;
        });
        _focus.requestFocus();
      case _MsgAction.react:
        await _pickReaction(m, position: position);
      case _MsgAction.edit:
        setState(() {
          _replyTo = null;
          _editing = m;
          _input.text = m.content;
          _input.selection = TextSelection.collapsed(offset: m.content.length);
        });
        _focus.requestFocus();
      case _MsgAction.star:
        await _chat.setStarred(m, !m.starred);
        if (mounted) showAppSnackBar(context, m.starred ? 'Unstarred' : 'Starred');
      case _MsgAction.forward:
        final to = await pickForwardTargets(context, exclude: _id);
        if (to == null || to.isEmpty || !mounted) return;
        try {
          await _chat.forward(m, to);
          if (mounted) showAppSnackBar(context, to.length == 1 ? 'Forwarded' : 'Forwarded to ${to.length} chats');
        } catch (e) {
          if (mounted) showAppSnackBar(context, friendlyError(e.toString(), fallback: 'Not forwarded'), error: true);
        }
      case _MsgAction.delete:
        await _delete(m);
      case _MsgAction.copy:
        await Clipboard.setData(ClipboardData(text: m.content));
        if (mounted) showAppSnackBar(context, 'Message copied');
      case _MsgAction.info:
        if (_isGroup && m.isFromMe) {
          final receipts = await _chat.groupReceiptsOf(m.id);
          if (!mounted) return;
          final contacts = context.read<ContactsProvider>();
          await showMessageInfoSheet(context, m,
              receipts: receipts, nameOf: (u) => personName(_chat, contacts, u));
        } else {
          await showMessageInfoSheet(context, m);
        }
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

    final contact = _isGroup ? null : contacts.getContact(_id);
    final group = chat.groupOf(_id);
    final name = group?.name ?? contact?.displayLabel ?? 'this contact';
    final inGroup = group?.isMember(chat.myUserId ?? '') ?? false;
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
    } else if (messages.isEmpty && _isGroup) {
      list = Center(child: EncryptionBanner(group: true, onTap: _openGroupInfo));
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
        title: _isGroup
            ? GroupHeader(
                conversationId: _id,
                name: group?.name ?? 'Group',
                subtitle: !inGroup
                    ? "You're no longer in this group"
                    : [
                        'You',
                        for (final u in group!.members)
                          if (u != chat.myUserId) personName(chat, contacts, u),
                      ].join(', '),
                onTap: _openGroupInfo,
              )
            : ChatHeader(
                contactUserId: _id,
                contact: contact,
                contactsLoading: contacts.isLoading,
                isTyping: chat.isContactTyping(_id),
                transport: transport,
                onTap: () => _openInfo(contact),
              ),
        actions: [
          if (!_isGroup && contact != null && context.watch<CallService?>() != null) ...[
            IconButton(
              key: const ValueKey('call-video'),
              tooltip: 'Video call',
              icon: const Icon(LucideIcons.video),
              onPressed: () => _call(video: true),
            ),
            IconButton(
              key: const ValueKey('call-voice'),
              tooltip: 'Voice call',
              icon: const Icon(LucideIcons.phone),
              onPressed: () => _call(video: false),
            ),
          ],
          if (_timer > 0)
            Tooltip(
              message: 'Messages disappear after ${ChatService.disappearLabel(_timer).toLowerCase()}',
              child: Padding(
                key: const ValueKey('timer-badge'),
                padding: const EdgeInsets.only(right: 2),
                child: Icon(LucideIcons.timer, size: 20, color: p.accent),
              ),
            ),
          PopupMenuButton<_MenuAction>(
            tooltip: 'More options',
            icon: const Icon(LucideIcons.ellipsisVertical),
            onSelected: (v) {
              switch (v) {
                case _MenuAction.info:
                  _openInfo(contact);
                case _MenuAction.search:
                  Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => MessageSearchScreen(chatId: _id, title: name)));
                case _MenuAction.mute:
                  _toggleMute();
                case _MenuAction.secure:
                  final lock = context.read<AppLockService>();
                  final on = !lock.isChatSecure(_id);
                  lock.setChatSecure(_id, on).then((_) => lock.chatOpened(_id));
                  showAppSnackBar(context, on ? 'Screenshots blocked in this chat' : 'Screenshots allowed in this chat');
                case _MenuAction.timer:
                  _chooseTimer();
                case _MenuAction.connect:
                  conn.reconnect(_id);
                  showAppSnackBar(context, 'Trying a direct connection…');
                case _MenuAction.clear:
                  _confirmClearChat(name);
              }
            },
            itemBuilder: (context) => [
              _isGroup
                  ? _menuItem(_MenuAction.info, LucideIcons.users, 'Group info')
                  : _menuItem(
                      _MenuAction.info,
                      LucideIcons.shieldCheck,
                      'Contact info & safety number',
                    ),
              _menuItem(_MenuAction.search, LucideIcons.search, 'Search in chat'),
              _menuItem(
                _MenuAction.mute,
                context.read<NotificationService>().isMuted(_id) ? LucideIcons.bell : LucideIcons.bellOff,
                context.read<NotificationService>().isMuted(_id) ? 'Unmute notifications' : 'Mute notifications',
              ),
              if (defaultTargetPlatform == TargetPlatform.android)
                _menuItem(
                  _MenuAction.secure,
                  LucideIcons.scanEye,
                  context.read<AppLockService>().isChatSecure(_id) ? 'Allow screenshots' : 'Block screenshots',
                ),
              _menuItem(
                _MenuAction.timer,
                LucideIcons.timer,
                _timer == 0
                    ? 'Disappearing messages'
                    : 'Disappearing: ${ChatService.disappearLabel(_timer)}',
              ),
              if (!_isGroup && transport == PeerConnectionState.offline)
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
          if (_isGroup && !inGroup)
            const _LeftGroupBar()
          else if (chat.verificationCached(_id) == Verification.changed)
            _KeysChangedBar(
              name: name,
              onReview: () => _openInfo(contact),
              onAccept: () async {
                final ok = await showConfirmDialog(
                  context,
                  title: 'Trust the new keys?',
                  message: "Messages will be encrypted to $name's new keys without "
                      'comparing safety numbers. They will show as not verified.',
                  confirmLabel: 'Trust',
                );
                if (ok) await _chat.clearVerified(_id);
              },
            )
          else
            Composer(
              controller: _input,
              focusNode: _focus,
              onSend: _send,
              onAttach: _editing == null ? _attach : null,
              onVoice: _editing == null ? _sendVoice : null,
              header: _editing != null
                  ? _quote({'id': _editing!.id, 'from': _chat.myUserId, 'preview': 'Editing: ${_editing!.content}'},
                      contact, onClose: () {
                      setState(() => _editing = null);
                      _input.clear();
                    })
                  : _replyTo != null
                      ? _quote(_replyRef(_replyTo!), contact, onClose: () => setState(() => _replyTo = null))
                      : null,
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
              ? EncryptionBanner(group: _isGroup, onTap: () => _openInfo(contact))
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
      a.senderId == b.senderId &&
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
        onTap: _isGroup ? _openGroupInfo : contact == null ? null : () => _openInfo(contact),
      );
    } else {
      final status = MessageStatus.fromString(m.status);
      body = Padding(
        padding: EdgeInsets.only(top: first ? 6 : 2),
        child: MessageBubble(
          senderName: _isGroup && first && !m.isFromMe
              ? personName(_chat, context.read<ContactsProvider>(), m.senderId)
              : null,
          senderColor: _isGroup ? _senderColor(context.palette, m.senderId) : null,
          replyQuote: m.replyTo == null
              ? null
              : _quote(m.replyTo!, contact, inSentBubble: m.isFromMe),
          edited: m.editedAt != null,
          forwarded: m.forwarded,
          starred: m.starred,
          deleted: m.deleted,
          reactions: m.reactions.values.toList(),
          onReactionsTap: () => _pickReaction(m),
          attachment: m.attachment == null
              ? null
              : VoiceNote.isVoice(m.attachment)
              ? VoiceNoteView(
                  key: ValueKey('voice-${m.id}'),
                  meta: m.attachment!,
                  service: _chat.attachments,
                  isSent: m.isFromMe,
                )
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
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: p.border),
        ),
        child: Text(
          '$count unread ${count == 1 ? 'message' : 'messages'}',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: p.textPrimary,
            fontWeight: FontWeight.w700,
          ),
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
        duration: AppMotion.of(context, AppMotion.medium),
        curve: AppMotion.curve,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: AppMotion.of(context, AppMotion.medium),
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
                style: t.titleLarge,
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

/// Replaces the composer once we've left or been removed from a group.
class _LeftGroupBar extends StatelessWidget {
  const _LeftGroupBar();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SafeArea(
      top: false,
      child: Container(
        key: const ValueKey('left-group-bar'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(color: p.surface, border: Border(top: BorderSide(color: p.border))),
        child: Text(
          "You can't send messages to this group because you're no longer a member.",
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: p.textSecondary),
        ),
      ),
    );
  }
}

/// Replaces the composer when a verified contact's keys changed.
class _KeysChangedBar extends StatelessWidget {
  const _KeysChangedBar({required this.name, required this.onReview, required this.onAccept});
  final String name;
  final VoidCallback onReview;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SafeArea(
      top: false,
      child: Container(
        key: const ValueKey('keys-changed-bar'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        decoration: BoxDecoration(
          color: p.surface,
          border: Border(top: BorderSide(color: p.danger.withValues(alpha: 0.6))),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.shieldAlert, size: 18, color: p.danger),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "$name's safety number changed",
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              "You verified $name before. Sending is paused until you check the new number. "
              'This is usually a new phone, but it could be someone intercepting.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: onAccept, child: const Text('Trust new keys')),
                const SizedBox(width: 4),
                FilledButton(
                  key: const ValueKey('keys-changed-review'),
                  onPressed: onReview,
                  child: const Text('Verify'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
