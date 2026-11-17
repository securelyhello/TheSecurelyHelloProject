import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/notifications/notification_service.dart';
import 'package:securelyhello/core/notifications/push_service.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/contacts/widgets/contact_info_sheet.dart';
import 'package:securelyhello/features/home/chat_navigation.dart';
import 'package:securelyhello/features/settings/screens/blocked_users_screen.dart';
import 'package:securelyhello/features/settings/screens/legal_screen.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/search_field.dart';

/// Home tab: profile, privacy, account.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _appVersion = '1.0.0';

  bool _signingOut = false;

  void _showPublicKeys(AuthProvider auth) {
    final p = context.palette;
    final identity = auth.identity;
    final keys = identity == null
        ? null
        : 'Device: ${auth.deviceId ?? 'not registered'}\n\n'
              'Signing (Ed25519):\n${identity.publicSigningKeyBase64}\n\n'
              'Identity (X25519):\n${identity.publicEncryptionKeyBase64}';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("This device's public keys"),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Contacts use these, with short-lived prekeys, to start '
                'forward-secret sessions with this device. Your other devices '
                'have keys of their own. Private keys never leave the device.',
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: p.inputFill,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: SelectableText(
                  keys ?? 'Keys are not available yet.',
                  style: GoogleFonts.sourceCodePro(
                    color: p.textPrimary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (keys != null)
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: keys));
                Navigator.pop(ctx);
                showAppSnackBar(context, 'Public keys copied');
              },
              icon: const Icon(LucideIcons.copy, size: 16),
              label: const Text('Copy'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _editDisplayName(AuthProvider auth) async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => _EditNameDialog(initial: auth.displayName),
    );
    if (name == null || !mounted) return;
    if (name.trim() == auth.displayName.trim()) return;
    final ok = await auth.updateDisplayName(name);
    if (!mounted) return;
    if (ok) {
      showAppSnackBar(context, 'Name updated', success: true);
    } else {
      showAppSnackBar(
        context,
        friendlyError(
          auth.errorMessage,
          fallback: 'Could not update your name',
        ),
        error: true,
      );
    }
  }

  Future<void> _pickContactForSafetyNumber() async {
    final contacts = context.read<ContactsProvider>().contacts;
    if (contacts.isEmpty) {
      showAppSnackBar(context, 'Add a contact first');
      return;
    }
    final contact = await showModalBottomSheet<Contact>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.75,
        child: _ContactPicker(contacts: contacts),
      ),
    );
    if (contact == null || !mounted) return;
    final result = await showContactInfoSheet(
      context,
      contact,
      showMessageAction: true,
    );
    if (!mounted) return;
    if (result == ContactSheetAction.message) {
      openChat(context, contact.userId);
    } else if ((result == ContactSheetAction.removed || result == ContactSheetAction.blocked)) {
      closeChatIfOpen(context, contact.userId);
    }
  }

  Future<void> _changePassword(AuthProvider auth) async {
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change password'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: current,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Current password',
                  ),
                  validator: (v) =>
                      (v ?? '').isEmpty ? 'Enter your current password' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: next,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'New password'),
                  validator: (v) =>
                      (v ?? '').length < 8 ? 'At least 8 characters' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: confirm,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Repeat new password',
                  ),
                  validator: (v) =>
                      v != next.text ? 'Passwords do not match' : null,
                ),
                const SizedBox(height: 12),
                Text(
                  'Your other devices will be signed out.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) Navigator.pop(ctx, true);
            },
            child: const Text('Change'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final changed = await auth.changePassword(
      currentPassword: current.text,
      newPassword: next.text,
    );
    if (!mounted) return;
    if (changed) {
      showAppSnackBar(context, 'Password changed', success: true);
    } else {
      showAppSnackBar(
        context,
        friendlyError(
          auth.errorMessage,
          fallback: 'Could not change the password',
        ),
        error: true,
      );
    }
  }

  Future<void> _logOut(AuthProvider auth) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Log out?',
      message:
          'Your chats stay encrypted on this device and will be here '
          'when you sign back in.',
      confirmLabel: 'Log out',
    );
    if (!ok || !mounted) return;
    setState(() => _signingOut = true);
    await auth.signOut();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
  }

  Future<void> _deleteAccount(AuthProvider auth) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => const _DeleteAccountDialog(),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _signingOut = true);
    final success = await auth.deleteAccount();
    if (!mounted) return;
    if (success) {
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
    } else {
      setState(() => _signingOut = false);
      showAppSnackBar(
        context,
        friendlyError(auth.errorMessage, fallback: 'Failed to delete account'),
        error: true,
      );
    }
  }

  void _showAbout() {
    final p = context.palette;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(LucideIcons.shieldCheck, color: p.accent, size: 32),
        title: const Text('How your messages are protected'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: const SingleChildScrollView(
            child: Text(
              '• Every message is encrypted on your device before it leaves '
              'it, separately for each of the recipient’s devices. Only those '
              'devices can decrypt it.\n\n'
              '• Keys change with every message (Double Ratchet), so a key '
              'stolen today can’t decrypt yesterday’s messages.\n\n'
              '• When both of you are online, messages travel directly '
              'between devices (peer to peer). Otherwise the encrypted '
              'message waits in a short-lived relay queue and is deleted '
              'once delivered.\n\n'
              '• Your private keys and chat history never leave this '
              'device.\n\n'
              '• Compare safety numbers with a contact to make sure nobody '
              'swapped their keys.',
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final auth = context.watch<AuthProvider>();
    final chat = context.watch<ChatProvider>();
    final displayName = auth.displayName.isNotEmpty
        ? auth.displayName
        : 'Your name';
    final username = auth.username;
    final email = auth.email;

    // Material (not a decorated Container) so ListTile ink shows on it.
    Widget group(List<Widget> tiles) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: BorderSide(color: p.divider),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < tiles.length; i++) ...[
              if (i > 0) const Divider(indent: 56),
              tiles[i],
            ],
          ],
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppBreakpoints.contentMaxWidth,
              ),
              child: ListView(
                padding: const EdgeInsets.only(top: 16, bottom: 32),
                children: [
                  // ── Profile ─────────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Material(
                      color: p.surface,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        onTap: () => _editDisplayName(auth),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(AppRadius.lg),
                            border: Border.all(color: p.divider),
                          ),
                          child: Row(
                            children: [
                              AvatarWidget(
                                displayName: displayName,
                                seed: auth.myUserId,
                                size: AvatarSize.large,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: t.titleLarge?.copyWith(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (username.isNotEmpty)
                                      Text(
                                        '@$username',
                                        style: t.bodyMedium?.copyWith(
                                          color: p.accent,
                                        ),
                                      ),
                                    if (email != null && email.isNotEmpty)
                                      Text(
                                        email,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: t.bodySmall?.copyWith(
                                          color: p.textMuted,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              Tooltip(
                                message: 'Edit name',
                                child: Icon(
                                  LucideIcons.pencil,
                                  size: 18,
                                  color: p.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (username.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: '@$username'),
                            );
                            showAppSnackBar(context, 'Username copied');
                          },
                          icon: const Icon(LucideIcons.copy, size: 16),
                          label: const Text('Copy my username'),
                        ),
                      ),
                    ),

                  // ── Notifications ───────────────────────────────────
                  const SectionHeader(
                    'Notifications',
                    padding: EdgeInsets.fromLTRB(28, 20, 28, 8),
                  ),
                  Builder(builder: (context) {
                    final n = context.read<NotificationService>();
                    return group([
                      SwitchListTile(
                        key: const ValueKey('settings-notifications'),
                        secondary: const Icon(LucideIcons.bell),
                        title: const Text('Message notifications'),
                        subtitle: Text(PushService.configured
                            ? 'Also when the app is closed (push wake-ups carry no content)'
                            : 'While the app is running in the background'),
                        value: n.enabled,
                        onChanged: (v) async {
                          await n.setEnabled(v);
                          setState(() {});
                        },
                      ),
                      SwitchListTile(
                        secondary: const Icon(LucideIcons.eyeOff),
                        title: const Text('Show message text'),
                        subtitle: const Text(
                            'Off: notifications only say “New message”'),
                        value: n.showPreview,
                        onChanged: n.enabled
                            ? (v) async {
                                await n.setShowPreview(v);
                                setState(() {});
                              }
                            : null,
                      ),
                    ]);
                  }),

                  // ── Privacy & security ──────────────────────────────
                  const SectionHeader(
                    'Privacy & security',
                    padding: EdgeInsets.fromLTRB(28, 20, 28, 8),
                  ),
                  group([
                    SwitchListTile(
                      secondary: const Icon(LucideIcons.checkCheck),
                      title: const Text('Read receipts'),
                      subtitle: const Text(
                        'Let contacts see when you’ve read their messages',
                      ),
                      value: chat.sendReadReceipts,
                      onChanged: chat.setSendReadReceipts,
                    ),
                    ListTile(
                      leading: const Icon(LucideIcons.shieldCheck),
                      title: const Text('Verify a safety number'),
                      subtitle: const Text('Confirm a contact’s identity'),
                      trailing: Icon(
                        LucideIcons.chevronRight,
                        size: 18,
                        color: p.textMuted,
                      ),
                      onTap: _pickContactForSafetyNumber,
                    ),
                    ListTile(
                      key: const ValueKey('settings-blocked'),
                      leading: const Icon(LucideIcons.ban),
                      title: const Text('Blocked'),
                      subtitle: const Text("People who can't reach you"),
                      trailing: Icon(LucideIcons.chevronRight, size: 18, color: p.textMuted),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => const BlockedUsersScreen())),
                    ),
                    ListTile(
                      key: const ValueKey('settings-devices'),
                      leading: const Icon(LucideIcons.monitorSmartphone),
                      title: const Text('Linked devices'),
                      subtitle: const Text('Phones and computers on your account'),
                      trailing: Icon(
                        LucideIcons.chevronRight,
                        size: 18,
                        color: p.textMuted,
                      ),
                      onTap: () => Navigator.of(context).pushNamed('/devices'),
                    ),
                    ListTile(
                      leading: const Icon(LucideIcons.keyRound),
                      title: const Text("This device's keys"),
                      subtitle: const Text('The keys contacts encrypt to'),
                      trailing: Icon(
                        LucideIcons.chevronRight,
                        size: 18,
                        color: p.textMuted,
                      ),
                      onTap: () => _showPublicKeys(auth),
                    ),
                  ]),

                  // ── Account ─────────────────────────────────────────
                  const SectionHeader(
                    'Account',
                    padding: EdgeInsets.fromLTRB(28, 20, 28, 8),
                  ),
                  group([
                    ListTile(
                      key: const ValueKey('settings-email'),
                      leading: Icon(
                        auth.emailVerified
                            ? LucideIcons.mailCheck
                            : LucideIcons.mailWarning,
                        color: auth.emailVerified ? null : p.warning,
                      ),
                      title: const Text('E-mail address'),
                      subtitle: Text(auth.emailVerified
                          ? 'Verified'
                          : 'Not verified. Tap to verify'),
                      trailing: auth.emailVerified
                          ? null
                          : Icon(LucideIcons.chevronRight,
                              size: 18, color: p.textMuted),
                      onTap: auth.emailVerified
                          ? null
                          : () async {
                              await auth.resendVerificationEmail();
                              if (context.mounted) {
                                Navigator.of(context).pushNamed('/verify-email');
                              }
                            },
                    ),
                    ListTile(
                      leading: const Icon(LucideIcons.lockKeyhole),
                      title: const Text('Change password'),
                      onTap: () => _changePassword(auth),
                    ),
                    ListTile(
                      leading: const Icon(LucideIcons.logOut),
                      title: const Text('Log out'),
                      onTap: _signingOut ? null : () => _logOut(auth),
                    ),
                    ListTile(
                      leading: Icon(LucideIcons.trash2, color: p.danger),
                      title: Text(
                        'Delete account',
                        style: TextStyle(color: p.danger),
                      ),
                      subtitle: const Text(
                        'Permanently delete your account, keys and chats',
                      ),
                      onTap: _signingOut ? null : () => _deleteAccount(auth),
                    ),
                  ]),

                  // ── About ───────────────────────────────────────────
                  const SectionHeader(
                    'About',
                    padding: EdgeInsets.fromLTRB(28, 20, 28, 8),
                  ),
                  group([
                    ListTile(
                      leading: const Icon(LucideIcons.lock),
                      title: const Text('How your messages are protected'),
                      trailing: Icon(
                        LucideIcons.chevronRight,
                        size: 18,
                        color: p.textMuted,
                      ),
                      onTap: _showAbout,
                    ),
                    ListTile(
                      leading: const Icon(LucideIcons.fileText),
                      title: const Text('Privacy policy'),
                      trailing: Icon(LucideIcons.chevronRight, size: 18, color: p.textMuted),
                      onTap: () => LegalScreen.open(context, LegalScreen.privacy),
                    ),
                    ListTile(
                      leading: const Icon(LucideIcons.scale),
                      title: const Text('Terms of service'),
                      trailing: Icon(LucideIcons.chevronRight, size: 18, color: p.textMuted),
                      onTap: () => LegalScreen.open(context, LegalScreen.terms),
                    ),
                    ListTile(
                      leading: const Icon(LucideIcons.info),
                      title: const Text('Version'),
                      trailing: Text(
                        _appVersion,
                        style: t.bodyMedium?.copyWith(color: p.textSecondary),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 24),
                  Center(
                    child: Text(
                      'Securely Hello',
                      style: t.labelMedium?.copyWith(color: p.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_signingOut)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withAlpha(90),
                child: const Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

class _EditNameDialog extends StatefulWidget {
  const _EditNameDialog({required this.initial});

  final String initial;

  @override
  State<_EditNameDialog> createState() => _EditNameDialogState();
}

class _EditNameDialogState extends State<_EditNameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final v = _controller.text.trim();
    if (v.isEmpty) return;
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final valid = _controller.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('Your name'),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _save(),
          decoration: const InputDecoration(
            hintText: 'Display name',
            helperText: 'Shown to your contacts',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: valid ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final armed = _controller.text.trim() == 'DELETE';
    return AlertDialog(
      icon: Icon(LucideIcons.triangleAlert, color: p.danger, size: 30),
      title: const Text('Delete account?'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This is permanent. Your profile, contacts, encryption keys and '
              'all messages on this device will be deleted.',
            ),
            const SizedBox(height: 16),
            Text(
              'Type DELETE to confirm',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: p.textPrimary),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(hintText: 'DELETE'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: p.danger,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: armed ? () => Navigator.pop(context, true) : null,
          child: const Text('Delete account'),
        ),
      ],
    );
  }
}

class _ContactPicker extends StatefulWidget {
  const _ContactPicker({required this.contacts});

  final List<Contact> contacts;

  @override
  State<_ContactPicker> createState() => _ContactPickerState();
}

class _ContactPickerState extends State<_ContactPicker> {
  final _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final q = _q.trim().toLowerCase();
    final list = widget.contacts
        .where(
          (c) =>
              q.isEmpty ||
              c.displayLabel.toLowerCase().contains(q) ||
              c.username.toLowerCase().contains(q),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            'Verify safety number with…',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SearchField(
            controller: _search,
            hint: 'Search contacts',
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: list.length,
            itemBuilder: (context, i) {
              final c = list[i];
              return ListTile(
                leading: AvatarWidget(
                  displayName: c.displayLabel,
                  seed: c.userId,
                  isOnline: c.isOnline,
                  ringColor: p.elevated,
                ),
                title: Text(c.displayLabel),
                subtitle: Text('@${c.username}'),
                onTap: () => Navigator.pop(context, c),
              );
            },
          ),
        ),
      ],
    );
  }
}
