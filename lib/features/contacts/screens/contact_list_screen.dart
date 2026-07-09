import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/empty_state.dart';
import 'package:securelyhello/shared/widgets/skeleton_loader.dart';

class ContactListScreen extends StatelessWidget {
  const ContactListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final contactsProvider = context.watch<ContactsProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Contacts',
              style: GoogleFonts.manrope(fontWeight: FontWeight.bold),
            ),
            if (!contactsProvider.isLoading)
              Text(
                '${contactsProvider.onlineCount} online',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: const Color(0xFF00E5CC),
                  fontWeight: FontWeight.w500,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.userPlus),
            onPressed: () => Navigator.pushNamed(context, '/add-contact'),
          ),
        ],
      ),
      body: _buildBody(context, contactsProvider),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.pushNamed(context, '/add-contact'),
        child: const Icon(LucideIcons.userPlus),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ContactsProvider provider) {
    if (provider.isLoading && provider.contacts.isEmpty) {
      return SkeletonLoader.contactList();
    }

    if (provider.contacts.isEmpty) {
      return Center(
        child: EmptyStateWidget.noContacts(
          onAction: () => Navigator.pushNamed(context, '/add-contact'),
        ),
      );
    }

    return RefreshIndicator(
      color: const Color(0xFF00E5CC),
      backgroundColor: const Color(0xFF1A1A2E),
      onRefresh: () => provider.loadContacts(),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: provider.contacts.length,
        itemBuilder: (context, index) {
          final contact = provider.contacts[index];
          
          return InkWell(
            onTap: () async {
              final chatProvider = context.read<ChatProvider>();
              await chatProvider.getOrCreateConversation(contact.userId);
              if (context.mounted) {
                Navigator.pushNamed(context, '/chat', arguments: contact.userId);
              }
            },
            onLongPress: () {
              _showContactOptions(context, contact, provider);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  AvatarWidget(
                    displayName: contact.displayLabel,
                    imageUrl: contact.avatarUrl,
                    isOnline: contact.isOnline,
                    size: AvatarSize.medium,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          contact.displayLabel,
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '@${contact.username}',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            color: const Color(0xFFB8B8CC),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showContactOptions(BuildContext context, Contact contact, ContactsProvider provider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A3E),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(LucideIcons.userMinus, color: Color(0xFFEF4444)),
                title: const Text('Remove Contact', style: TextStyle(color: Color(0xFFEF4444))),
                onTap: () async {
                  Navigator.pop(context);
                  final success = await provider.removeContact(contact.userId);
                  if (success && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('${contact.displayLabel} removed from contacts')),
                    );
                  }
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }
}
