import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/shared/widgets/app_text_field.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/empty_state.dart';

class AddContactScreen extends StatefulWidget {
  const AddContactScreen({super.key});

  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contactsProvider = context.watch<ContactsProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        title: const Text('Add Contact'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: AppTextField(
              controller: _searchController,
              hint: 'Search by username...',
              prefixIcon: const Icon(LucideIcons.search, color: Color(0xFF6B6B80)),
              onChanged: (val) => context.read<ContactsProvider>().searchUsers(val),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close, color: Color(0xFF6B6B80)),
                      onPressed: () {
                        _searchController.clear();
                        context.read<ContactsProvider>().clearSearch();
                      },
                    )
                  : null,
            ),
          ),
          if (contactsProvider.isSearching)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: LinearProgressIndicator(
                backgroundColor: Color(0xFF1A1A2E),
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00E5CC)),
              ),
            ),
          Expanded(
            child: _buildBody(contactsProvider),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ContactsProvider provider) {
    if (_searchController.text.trim().isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              LucideIcons.search,
              size: 64,
              color: const Color(0xFFB8B8CC).withValues(alpha: 0.2),
            ),
            const SizedBox(height: 16),
            Text(
              'Find people by username',
              style: GoogleFonts.inter(
                color: const Color(0xFFB8B8CC),
                fontSize: 16,
              ),
            ),
          ],
        ),
      );
    }

    if (!provider.isSearching && provider.searchResults.isEmpty) {
      return Center(child: EmptyStateWidget.noSearchResults());
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: provider.searchResults.length,
      itemBuilder: (context, index) {
        final result = provider.searchResults[index];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          leading: AvatarWidget(
            displayName: result.displayName,
            imageUrl: result.avatarUrl,
            size: AvatarSize.medium,
          ),
          title: Text(
            result.displayName,
            style: GoogleFonts.inter(
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          subtitle: Text(
            '@${result.username}',
            style: GoogleFonts.inter(
              color: const Color(0xFFB8B8CC),
            ),
          ),
          trailing: result.isAlreadyContact
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A2E),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Added',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF6B6B80),
                    ),
                  ),
                )
              : IconButton(
                  icon: const Icon(LucideIcons.userPlus, color: Color(0xFF00E5CC)),
                  onPressed: () async {
                    final success = await provider.addContact(result.userId);
                    if (success && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('@${result.username} added to contacts'),
                          backgroundColor: const Color(0xFF34D399),
                        ),
                      );
                      // Update search to reflect added status
                      provider.searchUsers(_searchController.text);
                    }
                  },
                ),
        );
      },
    );
  }
}
