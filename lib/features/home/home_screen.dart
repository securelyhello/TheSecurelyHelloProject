import 'dart:async';

import 'package:flutter/material.dart';

import 'package:securelyhello/features/whats_new/whats_new.dart';

import 'package:securelyhello/shared/widgets/brand_logo.dart';

import 'package:securelyhello/core/update/app_updater.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/features/calls/call_screen.dart';
import 'package:securelyhello/features/chat/chat_names.dart';
import 'package:securelyhello/features/settings/widgets/history_transfer.dart';
import 'package:securelyhello/l10n/app_localizations.dart';
import 'package:securelyhello/features/contacts/widgets/invite_prompt.dart';
import 'package:securelyhello/core/calls/call_service.dart';
import 'package:securelyhello/core/invites/invites.dart';
import 'package:securelyhello/core/calls/call_system.dart';
import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/stories/story_service.dart';
import 'package:securelyhello/core/chat/profile_service.dart';
import 'package:securelyhello/core/crypto/device_manager.dart';
import 'package:securelyhello/core/notifications/notification_service.dart';
import 'package:securelyhello/core/notifications/push_service.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/chat/screens/chat_screen.dart';
import 'package:securelyhello/features/contacts/screens/add_contact_screen.dart';
import 'package:securelyhello/features/chat/screens/conversation_list_screen.dart';
import 'package:securelyhello/features/calls/calls_screen.dart';
import 'package:securelyhello/features/home/chat_navigation.dart';
import 'package:securelyhello/features/settings/screens/settings_screen.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';

/// Signed-in shell.
///
/// * Phones / narrow windows: tabs (Chats, Find people, Calls, Settings) with
///   a bottom navigation bar; conversations open as the `/chat` route.
/// * Wide windows (≥ [AppBreakpoints.twoPane]): navigation rail, the list
///   pane on the left and the open conversation on the right.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver implements HomeTabSelector {
  HomeTab _tab = HomeTab.chats;
  ModalRoute<dynamic>? _route;
  String? _selectedChat;
  StreamSubscription<String>? _newRequestSub;
  StreamSubscription<Message>? _messageSub;
  StreamSubscription<Map<String, dynamic>>? _deviceSub;
  late final NotificationService _notifications;

  /// Missed calls since the Calls tab was last opened (its badge).
  int _missed = 0;
  StreamSubscription<void>? _callLogSub;

  Future<void> _countMissed() async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getInt('calls_seen_at') ?? 0;
    final log = await _chat.service.callLog();
    final n = log.where((c) => c.missed && c.at.millisecondsSinceEpoch > seen).length;
    if (mounted && n != _missed) setState(() => _missed = n);
  }

  /// From anywhere in the app (a screen pushed over the shell included):
  /// back to the shell, then [tab].
  @override
  void select(HomeTab tab) {
    if (!mounted) return;
    unawaited(_selectFromAnywhere(tab));
  }

  Future<void> _selectFromAnywhere(HomeTab tab) async {
    // Stays where it is (tab unchanged) when the call screen is showing on a
    // locked phone and the user hasn't unlocked it.
    if (!await popToShell(context, _route) || !mounted) return;
    await _selectTab(tab);
  }

  Future<void> _selectTab(HomeTab tab) async {
    setState(() => _tab = tab);
    if (tab == HomeTab.calls && _missed > 0) {
      setState(() => _missed = 0);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('calls_seen_at', DateTime.now().millisecondsSinceEpoch);
    }
  }
  CallService? _calls;
  CallSystemHolder? _callSystem;
  ProfileService? _profiles;
  late final AuthProvider _auth;
  late final ChatProvider _chat;
  late final ContactsProvider _contacts;

  /// In [HomeTab] order.
  static const _tabs = <Widget>[
    ConversationListScreen(),
    AddContactScreen(embedded: true),
    CallsScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _auth = context.read<AuthProvider>();
    _chat = context.read<ChatProvider>();
    _contacts = context.read<ContactsProvider>();
    _notifications = context.read<NotificationService>();
    _profiles = context.read<ProfileService?>();
    _notifications.onOpenChat = _openFromNotification;
    WidgetsBinding.instance.addObserver(this);
    _auth.addListener(_onAuthChanged);
    HomeTabRegistry.attach(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startSession());
  }

  /// The session ended without the user asking (token revoked or expired,
  /// account deleted elsewhere): go back to the login screen.
  void _onAuthChanged() {
    if (!mounted || _auth.status != AuthStatus.unauthenticated) return;
    _auth.removeListener(_onAuthChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
    });
  }

  Future<void> _startSession() async {
    final identity = _auth.identity;
    final myUserId = _auth.myUserId;
    final deviceId = _auth.deviceId;
    if (identity == null || myUserId == null || deviceId == null) return;
    final push = context.read<PushService?>();
    _invites = context.read<PendingInvites?>();
    _calls = context.read<CallService?>();
    _callSystem = context.read<CallSystemHolder?>();
    final stories = context.read<StoryService?>();
    _callSub ??= _calls?.onIncoming.listen(_onIncomingCall);

    // Subscribe before the socket opens so no presence or request push is
    // missed, then start messaging and load the lists.
    _contacts.init();
    await _chat.init(identity: identity, myUserId: myUserId, deviceId: deviceId);
    unawaited(stories?.start(myUserId, deviceId: deviceId));
    await _contacts.loadContacts();
    // After an update (not a fresh sign-up): what's new, once.
    final hadAccount = _contacts.contacts.isNotEmpty || _chat.conversations.isNotEmpty;
    if (await WhatsNew.due(hadAccountBefore: hadAccount) && mounted) {
      unawaited(WhatsNew.show(context));
    }
    _callLogSub ??= _chat.service.onCallLogChanged.listen((_) => unawaited(_countMissed()));
    unawaited(_countMissed());
    // A call that rang while the app was closed (push): pick it up.
    unawaited(_calls?.replayStashedOffer());
    _contacts.addListener(_syncProfiles);
    _syncProfiles();

    // Notifications are composed here, after decryption: names and previews
    // never pass through the server or a push provider.
    _messageSub ??= _chat.onMessageReceived.listen((m) {
      final preview = ChatService.previewText(m.content, m.attachment);
      final group = _chat.groupOf(m.conversationId);
      _notifications.showMessage(
        contactId: m.conversationId,
        sender: group == null
            ? _contacts.getContact(m.conversationId)?.displayLabel ?? 'New message'
            : personName(_chat, _contacts, m.senderId),
        senderId: m.senderId,
        groupName: group?.name,
        senderPhoto: _profiles?.photoOf(m.senderId),
        preview: preview,
        activeConversation: _chat.activeConversationId,
        time: m.timestamp,
      );
    });
    // Reply / Mark as read from a notification.
    _notifications.onAction = (a) async {
      switch (a.kind) {
        case NotificationActionKind.reply:
          await _chat.sendMessage(a.chatId, a.text);
          await _chat.markRead(a.chatId);
        case NotificationActionKind.markRead:
          await _chat.markRead(a.chatId);
        case NotificationActionKind.acceptCall:
          final calls = _calls;
          if (calls?.call?.id == a.chatId) {
            await calls!.accept();
            if (mounted) unawaited(showCallScreen(context));
          }
        case NotificationActionKind.declineCall:
          if (_calls?.call?.id == a.chatId) await _calls!.decline();
      }
    };
    _notifications.onWake = () => unawaited(_chat.onResume());
    // Tapping the ongoing-call notification shows the call.
    _callSystem?.onOpen = () {
      if (mounted) unawaited(showCallScreen(context));
    };
    unawaited(_notifications.requestPermission());
    unawaited(push?.start());

    _invites?.addListener(_onInvite);
    _historySub ??= _chat.onHistoryImported.listen((n) {
      if (mounted && n > 0) showAppSnackBar(context, '$n messages copied from your other device');
    });
    unawaited(_onInvite());

    _deviceSub ??= _auth.deviceEvents.listen((e) {
      if (e['type'] == 'device_pending') unawaited(_askApproval(e['device_id'] as String?));
    });

    _newRequestSub ??= _contacts.onNewRequest.listen((msg) {
      _notifications.showContactRequest(msg);
      if (!mounted) return;
      showAppSnackBar(
        context,
        msg,
        action: SnackBarAction(
          label: 'View',
          onPressed: () => Navigator.pushNamed(context, '/contact-requests'),
        ),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _notifications.appInForeground = state == AppLifecycleState.resumed;
    if (!_auth.isAuthenticated) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(context.read<AppUpdater?>()?.check()); // at most every 12 h
        _auth.setPresence(true);
        _chat.onResume();
        _contacts.loadContacts();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _auth.setPresence(false);
      default:
        break;
    }
  }

  PendingInvites? _invites;
  StreamSubscription<int>? _historySub;
  StreamSubscription<ActiveCall>? _callSub;

  /// An invite link was opened (now, or before signing in).
  Future<void> _onInvite() async {
    if (_invites?.token == null || !mounted) return;
    final token = await _invites!.take();
    if (token != null && mounted) await openInvite(context, token);
  }

  /// New contacts get our profile photo and about line.
  void _syncProfiles() {
    unawaited(_chat.syncProfiles([for (final c in _contacts.contacts) c.userId]));
  }

  void _onIncomingCall(ActiveCall c) {
    if (!mounted) return;
    // The ringing notification (full screen when locked) comes from
    // CallSystem; in the app, the call screen.
    unawaited(showCallScreen(context));
  }

  @override
  void dispose() {
    HomeTabRegistry.detach(this);
    _contacts.removeListener(_syncProfiles);
    _historySub?.cancel();
    _callLogSub?.cancel();
    _callSub?.cancel();
    _invites?.removeListener(_onInvite);
    WidgetsBinding.instance.removeObserver(this);
    _auth.removeListener(_onAuthChanged);
    _newRequestSub?.cancel();
    _messageSub?.cancel();
    _deviceSub?.cancel();
    if (_notifications.onOpenChat == _openFromNotification) {
      _notifications.onOpenChat = null;
    }
    _notifications.onAction = null;
    _notifications.onWake = null;
    super.dispose();
  }

  /// Someone signed in on a new device: approve it here or remove it.
  Future<void> _askApproval(String? deviceId) async {
    if (!mounted || deviceId == null) return;
    // Not over a call shown on the lock screen: whoever holds a locked phone
    // must not approve devices (H1). It stays pending under Linked devices.
    if (callScreenShowing && (await _callSystem?.system.keyguardLocked() ?? false)) return;
    if (!mounted) return;
    final devices = await _auth.listDevices();
    final d = devices.where((x) => x['device_id'] == deviceId).firstOrNull;
    if (d == null || d['approved'] == true || !mounted) return;
    final name = (d['name'] as String? ?? '').isEmpty ? 'A new device' : d['name'] as String;
    final fp = DeviceManager.fingerprint(d['signing_public_key'] as String);
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('approve-dialog'),
        title: Text('Approve $name?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Someone signed in to your account on a new device. Approve it only if it '
              'is yours and shows this code:'),
          const SizedBox(height: 14),
          Center(
            child: SelectableText(fp,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 20, letterSpacing: 1.5)),
          ),
          const SizedBox(height: 14),
          const Text("If you don't recognise it, remove it and change your password."),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'later'), child: const Text('Later')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'remove'),
            child: Text('Remove', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
          ),
          FilledButton(
            key: const ValueKey('approve-device'),
            onPressed: () => Navigator.pop(ctx, 'approve'),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'approve') {
      final ok = await _auth.approveDevice(d);
      if (!mounted) return;
      showAppSnackBar(context, ok ? '$name approved' : 'Could not approve it', error: !ok);
      if (ok) await offerHistoryTransfer(context, name);
    } else if (choice == 'remove') {
      final ok = await _auth.removeDevice(deviceId);
      if (mounted) showAppSnackBar(context, ok ? '$name removed' : 'Could not remove it', error: !ok);
    }
  }

  /// A notification was tapped: show that conversation.
  Future<void> _openFromNotification(String contactUserId) async {
    if (!mounted) return;
    // During a call the app may be showing over the lock screen: the chat
    // opens only once the phone is unlocked (security review H1).
    if (!await unlockToLeaveCallScreen(context) || !mounted) return;
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.twoPane;
    if (wide) {
      _openChat(contactUserId);
    } else {
      Navigator.of(context).pushNamed('/chat', arguments: contactUserId);
    }
  }

  void _openChat(String contactUserId) {
    setState(() {
      _selectedChat = contactUserId;
      // Conversations live in the Chats tab; jump there when opening one
      // from Find people so the list and the pane agree.
      if (_tab == HomeTab.findPeople) _tab = HomeTab.chats;
    });
  }

  void _closeChat() => setState(() => _selectedChat = null);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.twoPane;

    // Going from wide to narrow with a conversation open: keep it open as a
    // regular route.
    if (!wide && _selectedChat != null) {
      final id = _selectedChat!;
      _selectedChat = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pushNamed(context, '/chat', arguments: id);
      });
    }

    final unread = context.select<ChatProvider, int>((c) => c.totalUnreadCount);
    final requests = context.select<ContactsProvider, int>(
      (c) => c.receivedRequests.length,
    );

    // The probe, not this State, depends on the route: pushing or popping a
    // page over the shell doesn't rebuild it.
    return RouteProbe(
      onRoute: (r) => _route = r,
      child: wide ? _buildWide(context, unread, requests) : _buildNarrow(context, unread, requests),
    );
  }


  Widget _buildNarrow(BuildContext context, int unread, int requests) {
    return Scaffold(
      body: IndexedStack(index: _tab.index, children: _tabs),
      bottomNavigationBar: HomeNavigationBar(
        selected: _tab,
        onSelected: _selectTab,
        unread: unread,
        requests: requests,
        missed: _missed,
      ),
    );
  }

  Widget _buildWide(BuildContext context, int unread, int requests) {
    final p = context.palette;
    final width = MediaQuery.sizeOf(context).width;
    final extended = width >= AppBreakpoints.extendedRail;
    final selected = _selectedChat;

    return PopScope(
      // System back closes the open conversation before leaving the app.
      canPop: selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectedChat != null) _closeChat();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_selectedChat != null) _closeChat();
          },
        },
        child: TwoPaneScope(
          selectedContactId: selected,
          onOpenChat: _openChat,
          onCloseChat: _closeChat,
          child: Scaffold(
            body: SafeArea(
              child: Row(
                children: [
                  NavigationRail(
                    backgroundColor: p.chatBackground,
                    selectedIndex: _tab.index,
                    extended: extended,
                    minExtendedWidth: 200,
                    labelType: extended
                        ? NavigationRailLabelType.none
                        : NavigationRailLabelType.all,
                    onDestinationSelected: (i) => _selectTab(HomeTab.values[i]),
                    leading: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: _BrandMark(extended: extended),
                    ),
                    destinations: [
                      for (final tab in HomeTab.values)
                        NavigationRailDestination(
                          icon: _tabIcon(tab, unread: unread, requests: requests, missed: _missed),
                          label: Text(_tabLabel(L10n.of(context), tab)),
                        ),
                    ],
                  ),
                  VerticalDivider(width: 1, color: p.divider),
                  SizedBox(
                    width: AppBreakpoints.listPaneWidth,
                    child: IndexedStack(index: _tab.index, children: _tabs),
                  ),
                  VerticalDivider(width: 1, color: p.divider),
                  // No cross-fade here: the outgoing ChatScreen must be
                  // disposed (closing its conversation) before the incoming
                  // one opens, or it would clear the new active conversation.
                  Expanded(
                    child: selected == null
                        ? const _NoChatSelected()
                        : ChatScreen(
                            key: ValueKey('pane-$selected'),
                            contactUserId: selected,
                            embedded: true,
                            onClose: _closeChat,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

IconData _iconData(HomeTab tab) => switch (tab) {
  HomeTab.chats => LucideIcons.messageCircle,
  HomeTab.findPeople => LucideIcons.userSearch,
  HomeTab.calls => LucideIcons.phone,
  HomeTab.settings => LucideIcons.settings,
};

String _tabLabel(L10n l, HomeTab tab) => switch (tab) {
  HomeTab.chats => l.tabChats,
  HomeTab.findPeople => l.tabFindPeople,
  HomeTab.calls => l.tabCalls,
  HomeTab.settings => l.tabSettings,
};

/// Chats: unread messages. Find people: contact requests waiting. Calls:
/// missed calls.
Widget _tabIcon(HomeTab tab, {required int unread, required int requests, required int missed}) {
  final count = switch (tab) {
    HomeTab.chats => unread,
    HomeTab.findPeople => requests,
    HomeTab.calls => missed,
    HomeTab.settings => null,
  };
  if (count == null) return Icon(_iconData(tab));
  return Badge(
    isLabelVisible: count > 0,
    label: Text(count > 99 ? '99+' : '$count'),
    child: Icon(_iconData(tab)),
  );
}

/// The bottom bar of the phone layout.
class HomeNavigationBar extends StatelessWidget {
  const HomeNavigationBar({
    super.key,
    required this.selected,
    required this.onSelected,
    this.unread = 0,
    this.requests = 0,
    this.missed = 0,
  });

  final HomeTab selected;
  final ValueChanged<HomeTab> onSelected;
  final int unread;
  final int requests;
  final int missed;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final p = context.palette;
    // Paper-dark bar with a hairline on top; the theme gives the pear pill.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.chatBackground,
        border: Border(top: BorderSide(color: p.divider)),
      ),
      child: NavigationBar(
        backgroundColor: p.chatBackground,
        animationDuration: AppMotion.of(context, AppMotion.medium),
        selectedIndex: selected.index,
        onDestinationSelected: (i) => onSelected(HomeTab.values[i]),
        destinations: [
          for (final tab in HomeTab.values)
            NavigationDestination(
              key: ValueKey('tab-${_keyName(tab)}'),
              icon: _tabIcon(tab, unread: unread, requests: requests, missed: missed),
              label: _tabLabel(l, tab),
              tooltip: '',
            ),
        ],
      ),
    );
  }

  static String _keyName(HomeTab tab) => switch (tab) {
    HomeTab.chats => 'chats',
    HomeTab.findPeople => 'find-people',
    HomeTab.calls => 'calls',
    HomeTab.settings => 'settings',
  };
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.extended});

  final bool extended;

  @override
  Widget build(BuildContext context) {
    const logo = BrandLogo(size: 40);
    if (!extended) return const Tooltip(message: 'Securely Hello', child: logo);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        logo,
        const SizedBox(width: 10),
        Text('Securely Hello', style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}

class _NoChatSelected extends StatelessWidget {
  const _NoChatSelected();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    return ColoredBox(
      color: p.chatBackground,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const BrandLogo(size: 88),
                const SizedBox(height: 20),
                Text('Securely Hello', style: t.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  'Select a chat to start messaging, or start a new one from '
                  'the chat list.',
                  textAlign: TextAlign.center,
                  style: t.bodyMedium?.copyWith(color: p.textSecondary),
                ),
                const SizedBox(height: 28),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.lock, size: 13, color: p.textMuted),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        L10n.of(context).e2eNote,
                        style: t.bodySmall?.copyWith(color: p.textMuted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
