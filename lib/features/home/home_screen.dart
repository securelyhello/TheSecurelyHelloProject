import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/chat/screens/conversation_list_screen.dart';
import 'package:securelyhello/features/contacts/screens/contact_list_screen.dart';
import 'package:securelyhello/features/settings/screens/settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  
  final List<Widget> _screens = const [
    ConversationListScreen(),
    ContactListScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    // Load initial data
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ContactsProvider>().loadContacts();
      context.read<ChatProvider>().init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final unreadCount = context.watch<ChatProvider>().totalUnreadCount;
    
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: Color(0xFF1F1F30), width: 1),
          ),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) {
            setState(() {
              _currentIndex = index;
            });
          },
          backgroundColor: const Color(0xFF12121A),
          indicatorColor: const Color(0xFF00E5CC).withValues(alpha: 0.2),
          destinations: [
            NavigationDestination(
              icon: Badge(
                isLabelVisible: unreadCount > 0,
                label: Text(unreadCount > 99 ? '99+' : unreadCount.toString()),
                backgroundColor: const Color(0xFF00E5CC),
                textColor: const Color(0xFF0A0A0F),
                child: const Icon(LucideIcons.messageCircle),
              ),
              selectedIcon: Badge(
                isLabelVisible: unreadCount > 0,
                label: Text(unreadCount > 99 ? '99+' : unreadCount.toString()),
                backgroundColor: const Color(0xFF00E5CC),
                textColor: const Color(0xFF0A0A0F),
                child: const Icon(LucideIcons.messageCircle, color: Color(0xFF00E5CC)),
              ),
              label: 'Chats',
            ),
            const NavigationDestination(
              icon: Icon(LucideIcons.users),
              selectedIcon: Icon(LucideIcons.users, color: Color(0xFF00E5CC)),
              label: 'Contacts',
            ),
            const NavigationDestination(
              icon: Icon(LucideIcons.settings),
              selectedIcon: Icon(LucideIcons.settings, color: Color(0xFF00E5CC)),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}
