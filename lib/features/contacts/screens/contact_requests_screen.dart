import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';

class ContactRequestsScreen extends StatelessWidget {
  const ContactRequestsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ContactsProvider>();
    final requests = provider.receivedRequests;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        title: Text(
          'Contact Requests',
          style: GoogleFonts.manrope(fontWeight: FontWeight.bold),
        ),
      ),
      body: requests.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    LucideIcons.inbox,
                    size: 64,
                    color: const Color(0xFFB8B8CC).withValues(alpha: 0.2),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No pending requests',
                    style: GoogleFonts.inter(
                      color: const Color(0xFFB8B8CC),
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: requests.length,
              itemBuilder: (context, index) {
                final req = requests[index];
                final sender = req.sender;
                if (sender == null) return const SizedBox.shrink();

                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  leading: AvatarWidget(
                    displayName: sender.displayName,
                    imageUrl: sender.avatarUrl,
                    size: AvatarSize.medium,
                  ),
                  title: Text(
                    sender.displayName,
                    style: GoogleFonts.inter(
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  subtitle: Text(
                    '@${sender.username}',
                    style: GoogleFonts.inter(
                      color: const Color(0xFFB8B8CC),
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(LucideIcons.check, color: Color(0xFF00E5CC)),
                        onPressed: () async {
                          final success = await provider.acceptContactRequest(req.id);
                          if (success && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Request accepted from @${sender.username}')),
                            );
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(LucideIcons.x, color: Color(0xFFEF4444)),
                        onPressed: () async {
                          await provider.rejectContactRequest(req.id);
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
