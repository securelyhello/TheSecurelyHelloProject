import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notificationsEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _notificationsEnabled = prefs.getBool('notifications') ?? true;
    });
  }

  Future<void> _toggleNotifications(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications', value);
    setState(() {
      _notificationsEnabled = value;
    });
  }

  void _showPublicKeyDialog(BuildContext context, AuthProvider authProvider) {
    final publicKey = authProvider.identity?.publicEncryptionKeyBase64 ?? 'No key available';
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Your Public Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This is your public encryption key. Others use it to send you secure messages.',
              style: TextStyle(color: Color(0xFFB8B8CC), fontSize: 14),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF12121A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                publicKey,
                style: GoogleFonts.sourceCodePro(
                  color: const Color(0xFF00E5CC),
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: publicKey));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Public key copied to clipboard')),
              );
              Navigator.pop(ctx);
            },
            child: const Text('Copy', style: TextStyle(color: Color(0xFF00E5CC))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteAccount(BuildContext context, AuthProvider authProvider) {
    final controller = TextEditingController();
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Delete Account', style: TextStyle(color: Color(0xFFEF4444))),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This action is irreversible. All your messages, contacts, and encryption keys will be permanently deleted.',
              style: TextStyle(color: Color(0xFFB8B8CC)),
            ),
            const SizedBox(height: 16),
            const Text(
              'Type "DELETE" to confirm:',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'DELETE',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFFB8B8CC))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
            ),
            onPressed: () async {
              if (controller.text == 'DELETE') {
                Navigator.pop(ctx);
                final success = await authProvider.deleteAccount();
                if (success && context.mounted) {
                  Navigator.pushReplacementNamed(context, '/login');
                } else if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Failed to delete account')),
                  );
                }
              }
            },
            child: const Text('Permanently Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    final user = authProvider.user;
    
    // In a real app we'd get these from the profile record
    final displayName = user?.email?.split('@')[0] ?? 'User';
    final username = user?.email?.split('@')[0] ?? 'user';

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          // Profile Header
          Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              children: [
                AvatarWidget(
                  displayName: displayName,
                  size: AvatarSize.large,
                ),
                const SizedBox(height: 16),
                Text(
                  displayName,
                  style: GoogleFonts.manrope(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '@$username',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    color: const Color(0xFF00E5CC),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  user?.email ?? '',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: const Color(0xFF6B6B80),
                  ),
                ),
              ],
            ),
          ),
          
          const Divider(height: 1, color: Color(0xFF1F1F30)),
          
          // Security Section
          _buildSectionHeader('Security'),
          ListTile(
            leading: const Icon(LucideIcons.key),
            title: const Text('Your public key'),
            subtitle: const Text('View your identity keys'),
            onTap: () => _showPublicKeyDialog(context, authProvider),
          ),
          ListTile(
            leading: const Icon(LucideIcons.qrCode),
            title: const Text('Safety number'),
            subtitle: const Text('Verify a contact\'s identity'),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Coming in Phase 2')),
              );
            },
          ),
          
          const Divider(height: 32, color: Color(0xFF1F1F30)),
          
          // Notifications Section
          _buildSectionHeader('Notifications'),
          SwitchListTile(
            activeThumbColor: const Color(0xFF00E5CC),
            secondary: const Icon(LucideIcons.bell),
            title: const Text('Message notifications'),
            value: _notificationsEnabled,
            onChanged: _toggleNotifications,
          ),
          
          const Divider(height: 32, color: Color(0xFF1F1F30)),
          
          // Account Section
          _buildSectionHeader('Account'),
          ListTile(
            leading: const Icon(LucideIcons.lock),
            title: const Text('Change password'),
            onTap: () async {
                if (user?.email != null) {
                final success = await authProvider.resetPassword(user!.email!);
                if (context.mounted && success) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Password reset email sent')),
                  );
                }
              }
            },
          ),
          ListTile(
            leading: const Icon(LucideIcons.trash2, color: Color(0xFFEF4444)),
            title: const Text('Delete account', style: TextStyle(color: Color(0xFFEF4444))),
            onTap: () => _confirmDeleteAccount(context, authProvider),
          ),
          
          const Divider(height: 32, color: Color(0xFF1F1F30)),
          
          // About Section
          _buildSectionHeader('About'),
          const ListTile(
            leading: Icon(LucideIcons.info),
            title: Text('App version'),
            trailing: Text('1.0.0', style: TextStyle(color: Color(0xFF6B6B80))),
          ),
          const ListTile(
            leading: Icon(LucideIcons.shield),
            title: Text('Privacy Policy'),
          ),
          
          const SizedBox(height: 24),
          
          // Log Out
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFEF4444),
                side: const BorderSide(color: Color(0xFFEF4444)),
              ),
              onPressed: () async {
                await authProvider.signOut();
                if (context.mounted) {
                  Navigator.pushReplacementNamed(context, '/login');
                }
              },
              icon: const Icon(LucideIcons.logOut),
              label: const Text('Log out'),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Text(
        title.toUpperCase(),
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: const Color(0xFF6B6B80),
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
