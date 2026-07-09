import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/core/providers/connection_provider.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/message_bubble.dart' show MessageBubble, MessageStatus;
import 'package:securelyhello/shared/widgets/connection_badge.dart';

class ChatScreen extends StatefulWidget {
  final String contactUserId;

  const ChatScreen({super.key, required this.contactUserId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _showScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatProvider>().openConversation(widget.contactUserId);
    });

    _scrollController.addListener(() {
      if (_scrollController.hasClients) {
        setState(() {
          _showScrollToBottom = _scrollController.offset > 200;
        });
      }
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    // Use Future.microtask to avoid modifying provider during build
    Future.microtask(() {
      if (mounted) context.read<ChatProvider>().closeConversation();
    });
    super.dispose();
  }

  void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();
    
    final chatProvider = context.read<ChatProvider>();
    await chatProvider.sendMessage(widget.contactUserId, text);
    
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final contact = context.watch<ContactsProvider>().getContact(widget.contactUserId);
    final chatProvider = context.watch<ChatProvider>();
    final connectionProvider = context.watch<ConnectionProvider>();
    
    final messages = chatProvider.getMessages(widget.contactUserId);
    final connectionState = connectionProvider.getConnectionState(widget.contactUserId);
    
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            AvatarWidget(
              displayName: contact?.displayLabel ?? 'Unknown',
              imageUrl: contact?.avatarUrl,
              isOnline: contact?.isOnline ?? false,
              size: AvatarSize.medium,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact?.displayLabel ?? 'Unknown',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  ConnectionBadge(
                    connectionState: _mapConnectionState(connectionState),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            color: const Color(0xFF1A1A2E),
            onSelected: (value) {
              if (value == 'clear') {
                // Clear chat logic
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'info', child: Text('Contact info')),
              const PopupMenuItem(value: 'clear', child: Text('Clear chat')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                messages.isEmpty && !chatProvider.isLoading
                    ? const Center(
                        child: Text(
                          'Say hello! 👋',
                          style: TextStyle(color: Color(0xFFB8B8CC), fontSize: 16),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final msg = messages[index];
                          
                          // Grouping logic (simplified)
                          bool showTail = true;
                          if (index > 0) {
                            final nextMsg = messages[index - 1];
                            if (nextMsg.isFromMe == msg.isFromMe &&
                                nextMsg.timestamp.difference(msg.timestamp).inMinutes < 2) {
                              showTail = false;
                            }
                          }
                          
                          return Padding(
                            padding: EdgeInsets.only(bottom: showTail ? 8.0 : 2.0),
                            child: MessageBubble(
                              message: msg.content,
                              timestamp: msg.timestamp,
                              isSent: msg.isFromMe,
                              status: _mapMessageStatus(msg.status),
                              showTail: showTail,
                            ),
                          );
                        },
                      ),
                if (_showScrollToBottom)
                  Positioned(
                    bottom: 16,
                    right: 16,
                    child: FloatingActionButton.small(
                      backgroundColor: const Color(0xFF1A1A2E),
                      onPressed: () {
                        _scrollController.animateTo(
                          0.0,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        );
                      },
                      child: const Icon(LucideIcons.chevronDown, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
          _buildComposer(),
        ],
      ),
    );
  }

  Widget _buildComposer() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8).copyWith(
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF12121A),
        border: Border(top: BorderSide(color: Color(0xFF1F1F30))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            icon: const Icon(LucideIcons.paperclip, color: Color(0xFFB8B8CC)),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Attachments coming in Phase 2')),
              );
            },
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      maxLines: 5,
                      minLines: 1,
                      textCapitalization: TextCapitalization.sentences,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: 'Type a message...',
                        hintStyle: TextStyle(color: Color(0xFF6B6B80)),
                        border: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        fillColor: Colors.transparent,
                      ),
                      onChanged: (val) => setState(() {}),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            decoration: BoxDecoration(
              color: _messageController.text.trim().isNotEmpty
                  ? const Color(0xFF00E5CC)
                  : const Color(0xFF1A1A2E),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: Icon(
                LucideIcons.sendHorizontal,
                color: _messageController.text.trim().isNotEmpty
                    ? const Color(0xFF0A0A0F)
                    : const Color(0xFF6B6B80),
              ),
              onPressed: _sendMessage,
            ),
          ),
        ],
      ),
    );
  }
  
  // Mapping helpers for enums across files
  PeerConnectionState _mapConnectionState(dynamic state) {
    // Assuming P2PConnectionState from connection_provider
    final s = state.toString();
    if (s.contains('connected')) return PeerConnectionState.connected;
    if (s.contains('connecting')) return PeerConnectionState.connecting;
    return PeerConnectionState.offline;
  }
  
  MessageStatus _mapMessageStatus(String status) {
    if (status == 'read') return MessageStatus.read;
    if (status == 'delivered') return MessageStatus.delivered;
    if (status == 'sent') return MessageStatus.sent;
    return MessageStatus.sending;
  }
}
