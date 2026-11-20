import 'package:flutter/material.dart';
import 'package:securelyhello/core/chat/chat_service.dart';

import 'package:securelyhello/features/settings/screens/account_screen.dart';

import 'package:securelyhello/core/calls/call_service.dart';
import 'package:securelyhello/core/calls/call_system.dart';
import 'package:flutter/services.dart';
import 'package:securelyhello/shared/theme/app_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/l10n/app_localizations.dart';
import 'package:securelyhello/core/notifications/notification_service.dart';
import 'package:securelyhello/core/notifications/push_service.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/core/security/app_lock.dart';
import 'package:securelyhello/features/contacts/widgets/contact_info_sheet.dart';
import 'package:securelyhello/features/home/chat_navigation.dart';
import 'package:securelyhello/features/security/lock_screen.dart';
import 'package:securelyhello/features/settings/screens/backup_screen.dart';
import 'package:securelyhello/features/settings/screens/blocked_users_screen.dart';
import 'package:securelyhello/features/settings/screens/edit_profile_screen.dart';
import 'package:securelyhello/features/settings/screens/legal_screen.dart';
import 'package:securelyhello/features/settings/screens/two_factor_screen.dart';
import 'package:securelyhello/features/update/update_widgets.dart';
import 'package:securelyhello/features/settings/widgets/delete_account_dialog.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/theme/locale_controller.dart';
import 'package:securelyhello/shared/theme/theme_controller.dart';
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
                  style: AppFonts.mono(
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
    // Two-step status decides whether the code is asked up front; the
    // server's otp_required brings the field up anyway if this fails.
    final twoFactor = auth
        .twoFactorStatus()
        .then((s) => s['enabled'] == true)
        .catchError((Object _) => false);
    final deleted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => DeleteAccountDialog(
        twoFactorEnabled: twoFactor,
        onDelete: (password, otp) async {
          if (mounted) setState(() => _signingOut = true);
          final ok = await auth.deleteAccount(currentPassword: password, otp: otp);
          if (ok) return null;
          if (mounted) setState(() => _signingOut = false);
          return DeleteAccountFailure(
            auth.deleteAccountErrorCode,
            friendlyError(auth.errorMessage, fallback: 'Failed to delete account'),
          );
        },
      ),
    );
    if (deleted != true || !mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
  }

  void _showAbout() {
    final p = context.palette;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(color: p.brand, shape: BoxShape.circle),
          child: Icon(LucideIcons.shieldCheck, color: p.onBrand, size: 28),
        ),
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
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: p.border),
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
                  // Profile
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(AppRadius.card),
                        boxShadow: p.paperShadow,
                      ),
                      child: Material(
                      color: p.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.card),
                        side: BorderSide(color: p.border),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                            builder: (_) => const EditProfileScreen())),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Row(
                            children: [
                              AvatarWidget(
                                displayName: displayName,
                                seed: auth.myUserId,
                                size: AvatarSize.xlarge,
                              ),
                              const SizedBox(width: 18),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: t.headlineSmall,
                                    ),
                                    if (username.isNotEmpty)
                                      Text(
                                        '@$username',
                                        style: t.bodyMedium?.copyWith(
                                          color: p.link,
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
                                message: 'Edit profile',
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

                  // Notifications
                  SectionHeader(
                    L10n.of(context).settingsAppearance,
                    padding: EdgeInsets.fromLTRB(28, 20, 28, 8),
                  ),
                  Builder(builder: (context) {
                    final theme = context.watch<ThemeController>();
                    return group([
                      ListTile(
                        key: const ValueKey('settings-theme'),
                        leading: const Icon(LucideIcons.sunMoon),
                        title: _rowLabel(L10n.of(context).settingsTheme),
                        trailing: _cappedTrailing(DropdownButton<ThemeMode>(
                          value: theme.mode,
                          underline: const SizedBox(),
                          isExpanded: true,
                          items: [
                            for (final m in ThemeMode.values)
                              DropdownMenuItem(
                                value: m,
                                child: Text(
                                  switch (m) {
                                    ThemeMode.system => L10n.of(context).themeSystem,
                                    ThemeMode.light => L10n.of(context).themeLight,
                                    ThemeMode.dark => L10n.of(context).themeDark,
                                  },
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (m) => m == null ? null : theme.set(m),
                        )),
                      ),
                      Builder(builder: (context) {
                        final language = context.watch<LocaleController>();
                        return ListTile(
                          key: const ValueKey('settings-language'),
                          leading: const Icon(LucideIcons.languages),
                          title: _rowLabel(L10n.of(context).settingsLanguage),
                          trailing: _cappedTrailing(DropdownButton<String>(
                            value: language.locale?.languageCode ?? '',
                            underline: const SizedBox(),
                            isExpanded: true,
                            items: [
                              DropdownMenuItem(
                                  value: '',
                                  child: Text(L10n.of(context).languageSystem,
                                      overflow: TextOverflow.ellipsis)),
                              for (final e in LocaleController.names.entries)
                                DropdownMenuItem(
                                    value: e.key,
                                    child: Text(e.value, overflow: TextOverflow.ellipsis)),
                            ],
                            onChanged: (code) =>
                                language.set(code == null || code.isEmpty ? null : Locale(code)),
                          )),
                        );
                      }),
                    ]);
                  }),

                  SectionHeader(
                    L10n.of(context).settingsNotifications,
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
                      ListTile(
                        key: const ValueKey('settings-sound'),
                        leading: const Icon(LucideIcons.music),
                        title: _rowLabel('Sound'),
                        trailing: _cappedTrailing(DropdownButton<String>(
                          value: n.sound,
                          underline: const SizedBox(),
                          isExpanded: true,
                          items: const [
                            DropdownMenuItem(
                                value: 'default',
                                child: Text('Phone default', overflow: TextOverflow.ellipsis)),
                            DropdownMenuItem(value: 'chime', child: Text('Chime')),
                            DropdownMenuItem(value: 'pop', child: Text('Pop')),
                            DropdownMenuItem(value: 'bell', child: Text('Bell')),
                            DropdownMenuItem(value: 'none', child: Text('Silent')),
                          ],
                          onChanged: n.enabled
                              ? (v) async {
                                  if (v == null) return;
                                  await n.setSound(v);
                                  setState(() {});
                                }
                              : null,
                        )),
                      ),
                    ]);
                  }),

                  // Calls
                  SectionHeader('Calls', padding: EdgeInsets.fromLTRB(28, 20, 28, 8)),
                  Builder(builder: (context) {
                    final system = context.read<CallSystemHolder?>()?.system;
                    return group([
                      SwitchListTile(
                        key: const ValueKey('settings-low-bandwidth'),
                        secondary: const Icon(LucideIcons.gauge),
                        title: const Text('Low-bandwidth calls'),
                        subtitle: const Text('Smaller video at 15 frames a second, for slow connections'),
                        value: DeviceCallMedia.lowBandwidth,
                        onChanged: (v) async {
                          await DeviceCallMedia.setLowBandwidth(v);
                          setState(() {});
                        },
                      ),
                      if (system != null && system.enabled)
                        FutureBuilder<bool>(
                          future: system.canUseFullScreen(),
                          builder: (context, snap) => snap.data == false
                              ? ListTile(
                                  leading: const Icon(LucideIcons.phoneIncoming),
                                  title: const Text('Show calls on the lock screen'),
                                  subtitle: const Text(
                                      'Android has turned this off for Securely Hello. Allow it so calls ring like a phone call.'),
                                  trailing: const Icon(LucideIcons.chevronRight),
                                  onTap: system.openFullScreenSettings,
                                )
                              : const SizedBox.shrink(),
                        ),
                    ]);
                  }),

                  // Privacy & security
                  SectionHeader(
                    L10n.of(context).settingsPrivacy,
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
                    SwitchListTile(
                      key: const ValueKey('settings-presence'),
                      secondary: const Icon(LucideIcons.eye),
                      title: const Text('Last seen & online'),
                      subtitle: const Text('Off: nobody sees when you’re online, and you don’t see theirs'),
                      value: auth.showPresence,
                      onChanged: (v) async {
                        final ok = await auth.setShowPresence(v);
                        if (!ok && context.mounted) {
                          showAppSnackBar(context, friendlyError(auth.errorMessage), error: true);
                        }
                      },
                    ),
                    FutureBuilder<bool>(
                      future: chat.service.profileVisible(),
                      builder: (context, snap) => ListTile(
                        key: const ValueKey('settings-profile-visible'),
                        leading: const Icon(LucideIcons.circleUser),
                        title: _rowLabel('Profile photo & about'),
                        trailing: _cappedTrailing(DropdownButton<bool>(
                          value: snap.data ?? true,
                          underline: const SizedBox(),
                          isExpanded: true,
                          items: const [
                            DropdownMenuItem(
                                value: true,
                                child: Text('My contacts', overflow: TextOverflow.ellipsis)),
                            DropdownMenuItem(
                                value: false,
                                child: Text('Nobody', overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: (v) async {
                            if (v == null) return;
                            await chat.service.setProfileVisible(v);
                            setState(() {});
                          },
                        )),
                      ),
                    ),
                    FutureBuilder<int>(
                      future: chat.service.defaultDisappearing(),
                      builder: (context, snap) => ListTile(
                        key: const ValueKey('settings-default-timer'),
                        leading: const Icon(LucideIcons.timer),
                        title: _rowLabel('Disappearing messages for new chats'),
                        trailing: _cappedTrailing(DropdownButton<int>(
                          value: snap.data ?? 0,
                          underline: const SizedBox(),
                          isExpanded: true,
                          items: [
                            for (final s in const [0, 86400, 604800])
                              DropdownMenuItem(
                                  value: s,
                                  child: Text(ChatService.disappearLabel(s),
                                      overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: (v) async {
                            if (v == null) return;
                            await chat.service.setDefaultDisappearing(v);
                            setState(() {});
                          },
                        )),
                      ),
                    ),
                    SwitchListTile(
                      key: const ValueKey('settings-discoverable'),
                      secondary: const Icon(LucideIcons.search),
                      title: const Text('Find me by username'),
                      subtitle: const Text(
                          'Off: people must type your exact username to find you'),
                      value: auth.discoverable,
                      onChanged: (v) async {
                        if (!await auth.setDiscoverable(v) && context.mounted) {
                          showAppSnackBar(context, friendlyError(auth.errorMessage), error: true);
                        }
                      },
                    ),
                    const _EmailDiscoveryTile(),
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
                      key: const ValueKey('settings-backup'),
                      leading: const Icon(LucideIcons.archive),
                      title: const Text('Chat backup'),
                      subtitle: const Text('Save or restore an encrypted backup'),
                      trailing: Icon(LucideIcons.chevronRight, size: 18, color: p.textMuted),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => const BackupScreen())),
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

                  SectionHeader(
                    L10n.of(context).settingsAppLock,
                    padding: EdgeInsets.fromLTRB(28, 20, 28, 8),
                  ),
                  Builder(builder: (context) {
                    final lock = context.watch<AppLockService>();
                    return group([
                      SwitchListTile(
                        key: const ValueKey('settings-app-lock'),
                        secondary: const Icon(LucideIcons.lock),
                        title: const Text('Lock with a PIN'),
                        subtitle: const Text('Ask for a PIN when you open the app'),
                        value: lock.enabled,
                        onChanged: (v) async {
                          if (!v) return lock.disable();
                          final pin = await askNewPin(context);
                          if (pin != null) await lock.setPin(pin);
                        },
                      ),
                      if (lock.enabled) ...[
                        ListTile(
                          leading: const Icon(LucideIcons.timer),
                          title: _rowLabel('Lock'),
                          trailing: _cappedTrailing(DropdownButton<int>(
                            value: lock.timeoutSeconds,
                            underline: const SizedBox(),
                            isExpanded: true,
                            items: [
                              for (final s in AppLockService.timeoutChoices)
                                DropdownMenuItem(
                                    value: s,
                                    child: Text(AppLockService.timeoutLabel(s),
                                        overflow: TextOverflow.ellipsis)),
                            ],
                            onChanged: (v) => v == null ? null : lock.setTimeout(v),
                          )),
                        ),
                        if (lock.biometricsSupported)
                          SwitchListTile(
                            secondary: const Icon(LucideIcons.fingerprint),
                            title: const Text('Unlock with biometrics'),
                            value: lock.useBiometrics,
                            onChanged: lock.setUseBiometrics,
                          ),
                        SwitchListTile(
                          secondary: const Icon(LucideIcons.bomb),
                          title: const Text('Erase after 10 wrong PINs'),
                          subtitle: const Text('Signs out and deletes chats on this device'),
                          value: lock.wipeOnFailures,
                          onChanged: lock.setWipeOnFailures,
                        ),
                        ListTile(
                          leading: const Icon(LucideIcons.lockKeyhole),
                          title: const Text('Lock now'),
                          onTap: lock.lockNow,
                        ),
                      ],
                      SwitchListTile(
                        key: const ValueKey('settings-screen-security'),
                        secondary: const Icon(LucideIcons.monitorX),
                        title: const Text('Screen security'),
                        subtitle: const Text(
                            'Block screenshots and hide the app in the app switcher'),
                        value: lock.screenSecurity,
                        onChanged: lock.setScreenSecurity,
                      ),
                      SwitchListTile(
                        secondary: const Icon(LucideIcons.keyboard),
                        title: const Text('Incognito keyboard'),
                        subtitle: const Text('Ask the keyboard not to learn what you type'),
                        value: lock.incognitoKeyboard,
                        onChanged: lock.setIncognitoKeyboard,
                      ),
                    ]);
                  }),

                  // Account
                  SectionHeader(
                    L10n.of(context).settingsAccount,
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
                      key: const ValueKey('settings-account'),
                      leading: const Icon(LucideIcons.userCog),
                      title: const Text('Account'),
                      subtitle: const Text('Username, e-mail, sessions, your data'),
                      trailing: Icon(LucideIcons.chevronRight, size: 18, color: p.textMuted),
                      onTap: () => Navigator.of(context)
                          .push(MaterialPageRoute<void>(builder: (_) => const AccountScreen())),
                    ),
                    ListTile(
                      key: const ValueKey('settings-2fa'),
                      leading: const Icon(LucideIcons.smartphone),
                      title: const Text('Two-step verification'),
                      subtitle: const Text('Ask for an authenticator code at sign-in'),
                      trailing: Icon(LucideIcons.chevronRight, size: 18, color: p.textMuted),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => const TwoFactorScreen())),
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

                  // App updates (and the version)
                  const SectionHeader('App updates', padding: EdgeInsets.fromLTRB(28, 20, 28, 8)),
                  const AppUpdatesSection(),

                  // About
                  SectionHeader(
                    L10n.of(context).settingsAbout,
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
                color: p.background.withValues(alpha: 0.6),
                child: const Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
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
            style: Theme.of(context).textTheme.titleMedium,
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

/// "Let people who have my e-mail find me" (off by default).
class _EmailDiscoveryTile extends StatefulWidget {
  const _EmailDiscoveryTile();

  @override
  State<_EmailDiscoveryTile> createState() => _EmailDiscoveryTileState();
}

class _EmailDiscoveryTileState extends State<_EmailDiscoveryTile> {
  bool? _on;

  @override
  void initState() {
    super.initState();
    context.read<ContactsProvider>().emailDiscoverable().then((v) {
      if (mounted) setState(() => _on = v);
    }, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
        key: const ValueKey('settings-email-discovery'),
        secondary: const Icon(LucideIcons.contact),
        title: const Text('Findable by e-mail'),
        subtitle: const Text('People who have your address in their contacts can see you here'),
        value: _on ?? false,
        onChanged: _on == null
            ? null
            : (v) async {
                setState(() => _on = v);
                try {
                  await context.read<ContactsProvider>().setEmailDiscoverable(v);
                } catch (e) {
                  if (!context.mounted) return;
                  setState(() => _on = !v);
                  showAppSnackBar(context, friendlyError(e.toString()), error: true);
                }
              },
      );
}

/// Row label for dropdown rows: stays on one line and never breaks mid-word,
/// so the dropdown side gives up width first at large text scales.
Widget _rowLabel(String text) => Text(text, softWrap: false, overflow: TextOverflow.ellipsis);

/// Caps the dropdown side of a settings row so the label keeps its width.
Widget _cappedTrailing(Widget dropdown) => ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 160),
      child: dropdown,
    );
