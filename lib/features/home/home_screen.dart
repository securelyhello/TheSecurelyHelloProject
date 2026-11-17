import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/notifications/notification_service.dart';
import 'package:securelyhello/core/notifications/push_service.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/chat/screens/chat_screen.dart';
import 'package:securelyhello/features/chat/screens/conversation_list_screen.dart';
import 'package:securelyhello/features/contacts/screens/contact_list_screen.dart';
import 'package:securelyhello/features/home/chat_navigation.dart';
import 'package:securelyhello/features/settings/screens/settings_screen.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';

/// Signed-in shell.
///
/// * Phones / narrow windows: tabs (Chats, Contacts, Settings) with a bottom
///   navigation bar; conversations open as the `/chat` route.
/// * Wide windows (≥ [AppBreakpoints.twoPane]): navigation rail, the list
///   pane on the left and the open conversation on the right.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;
  String? _selectedChat;
  StreamSubscription<String>? _newRequestSub;
  StreamSubscription<Message>? _messageSub;
  late final NotificationService _notifications;
  late final AuthProvider _auth;
  late final ChatProvider _chat;
  late final ContactsProvider _contacts;

  static const _tabs = <Widget>[
    ConversationListScreen(),
    ContactListScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _auth = context.read<AuthProvider>();
    _chat = context.read<ChatProvider>();
    _contacts = context.read<ContactsProvider>();
    _notifications = context.read<NotificationService>();
    _notifications.onOpenChat = _openFromNotification;
    WidgetsBinding.instance.addObserver(this);
    _auth.addListener(_onAuthChanged);
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

    // Subscribe before the socket opens so no presence or request push is
    // missed, then start messaging and load the lists.
    _contacts.init();
    await _chat.init(identity: identity, myUserId: myUserId, deviceId: deviceId);
    await _contacts.loadContacts();

    // Notifications are composed here, after decryption: names and previews
    // never pass through the server or a push provider.
    _messageSub ??= _chat.onMessageReceived.listen((m) {
      _notifications.showMessage(
        contactId: m.conversationId,
        sender: _contacts.getContact(m.conversationId)?.displayLabel ?? 'New message',
        preview: ChatService.previewText(m.content, m.attachment),
        activeConversation: _chat.activeConversationId,
      );
    });
    unawaited(_notifications.requestPermission());
    unawaited(push?.start());

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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _auth.removeListener(_onAuthChanged);
    _newRequestSub?.cancel();
    _messageSub?.cancel();
    if (_notifications.onOpenChat == _openFromNotification) {
      _notifications.onOpenChat = null;
    }
    super.dispose();
  }

  /// A notification was tapped: show that conversation.
  void _openFromNotification(String contactUserId) {
    if (!mounted) return;
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
      // from Contacts so the list and the pane agree.
      if (_currentIndex == 1) _currentIndex = 0;
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

    return wide
        ? _buildWide(context, unread, requests)
        : _buildNarrow(context, unread, requests);
  }

  Widget _badgeIcon(IconData icon, int count) => Badge(
    isLabelVisible: count > 0,
    label: Text(count > 99 ? '99+' : '$count'),
    child: Icon(icon),
  );

  Widget _buildNarrow(BuildContext context, int unread, int requests) {
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _tabs),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: context.palette.divider)),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (i) => setState(() => _currentIndex = i),
          destinations: [
            NavigationDestination(
              icon: _badgeIcon(LucideIcons.messageCircle, unread),
              label: 'Chats',
              tooltip: '',
            ),
            NavigationDestination(
              icon: _badgeIcon(LucideIcons.users, requests),
              label: 'Contacts',
              tooltip: '',
            ),
            const NavigationDestination(
              icon: Icon(LucideIcons.settings),
              label: 'Settings',
              tooltip: '',
            ),
          ],
        ),
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
                    selectedIndex: _currentIndex,
                    extended: extended,
                    minExtendedWidth: 200,
                    labelType: extended
                        ? NavigationRailLabelType.none
                        : NavigationRailLabelType.all,
                    onDestinationSelected: (i) =>
                        setState(() => _currentIndex = i),
                    leading: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: _BrandMark(extended: extended),
                    ),
                    destinations: [
                      NavigationRailDestination(
                        icon: _badgeIcon(LucideIcons.messageCircle, unread),
                        label: const Text('Chats'),
                      ),
                      NavigationRailDestination(
                        icon: _badgeIcon(LucideIcons.users, requests),
                        label: const Text('Contacts'),
                      ),
                      const NavigationRailDestination(
                        icon: Icon(LucideIcons.settings),
                        label: Text('Settings'),
                      ),
                    ],
                  ),
                  VerticalDivider(width: 1, color: p.divider),
                  SizedBox(
                    width: AppBreakpoints.listPaneWidth,
                    child: IndexedStack(index: _currentIndex, children: _tabs),
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

class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.extended});

  final bool extended;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final logo = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: p.accentContainer,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Icon(LucideIcons.shieldCheck, color: p.accent, size: 22),
    );
    if (!extended) return Tooltip(message: 'Securely Hello', child: logo);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        logo,
        const SizedBox(width: 10),
        Text(
          'Securely Hello',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
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
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: p.accentContainer.withAlpha(150),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    LucideIcons.messagesSquare,
                    size: 42,
                    color: p.onAccentContainer,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Securely Hello',
                  style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
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
                        'Your messages are end-to-end encrypted',
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
