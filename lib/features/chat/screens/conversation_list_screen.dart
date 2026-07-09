import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/empty_state.dart';
import 'package:securelyhello/shared/widgets/skeleton_loader.dart';

class ConversationListScreen extends StatelessWidget {
  const ConversationListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final chatProvider = context.watch<ChatProvider>();
    final contactsProvider = context.watch<ContactsProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () {
              // Switch to contacts tab in home screen (handled externally ideally)
              // For now just push add contact
              Navigator.pushNamed(context, '/add-contact');
            },
          ),
        ],
      ),
      body: _buildBody(chatProvider, contactsProvider, context),
    );
  }

  Widget _buildBody(ChatProvider chatProvider, ContactsProvider contactsProvider, BuildContext context) {
    if (chatProvider.isLoading && chatProvider.conversations.isEmpty) {
      return SkeletonLoader.chatList();
    }

    if (chatProvider.conversations.isEmpty) {
      return Center(
        child: EmptyStateWidget.noMessages(),
      );
    }

    return ListView.builder(
      itemCount: chatProvider.conversations.length,
      itemBuilder: (context, index) {
        final conv = chatProvider.conversations[index];
        final contact = contactsProvider.getContact(conv.contactUserId);
        
        final displayName = contact?.displayLabel ?? 'Unknown';
        final avatarUrl = contact?.avatarUrl;
        final isOnline = contact?.isOnline ?? false;

        return Dismissible(
          key: Key(conv.id),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 24),
            color: const Color(0xFFEF4444),
            child: const Icon(LucideIcons.trash2, color: Colors.white),
          ),
          confirmDismiss: (direction) async {
            return await showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF1A1A2E),
                title: const Text('Delete chat?'),
                content: const Text('This will permanently delete message history from your device.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel', style: TextStyle(color: Color(0xFFB8B8CC))),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Delete', style: TextStyle(color: Color(0xFFEF4444))),
                  ),
                ],
              ),
            );
          },
          onDismissed: (direction) {
            chatProvider.deleteConversation(conv.id);
          },
          child: InkWell(
            onTap: () {
              Navigator.pushNamed(context, '/chat', arguments: conv.contactUserId);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  AvatarWidget(
                    displayName: displayName,
                    imageUrl: avatarUrl,
                    isOnline: isOnline,
                    size: AvatarSize.large,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                displayName,
                                style: GoogleFonts.inter(
                                  fontSize: 16,
                                  fontWeight: conv.unreadCount > 0 ? FontWeight.bold : FontWeight.w600,
                                  color: Colors.white,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (conv.lastMessageTime != null)
                              Text(
                                _formatTimestamp(conv.lastMessageTime!),
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  color: conv.unreadCount > 0 ? const Color(0xFF00E5CC) : const Color(0xFF6B6B80),
                                  fontWeight: conv.unreadCount > 0 ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                conv.lastMessage ?? 'No messages yet',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  color: conv.unreadCount > 0 ? Colors.white : const Color(0xFFB8B8CC),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (conv.unreadCount > 0)
                              Container(
                                margin: const EdgeInsets.only(left: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00E5CC),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  conv.unreadCount > 99 ? '99+' : conv.unreadCount.toString(),
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: const Color(0xFF0A0A0F),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _formatTimestamp(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (now.day == time.day && now.month == time.month && now.year == time.year) {
      return DateFormat.jm().format(time);
    }
    if (diff.inDays < 2) return 'Yesterday';
    if (diff.inDays < 7) return DateFormat.E().format(time);
    return DateFormat.MMMd().format(time);
  }
}
