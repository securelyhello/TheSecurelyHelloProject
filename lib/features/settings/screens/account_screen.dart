import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';

/// Username, e-mail, other sessions and a copy of your data.
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final p = context.palette;
    Widget chevron() => Icon(LucideIcons.chevronRight, size: 18, color: p.textMuted);
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(children: [
        ListTile(
          key: const ValueKey('account-username'),
          leading: const Icon(LucideIcons.atSign),
          title: const Text('Username'),
          subtitle: Text('@${auth.username}'),
          trailing: chevron(),
          onTap: () => _changeUsername(context, auth),
        ),
        ListTile(
          key: const ValueKey('account-email'),
          leading: const Icon(LucideIcons.mail),
          title: const Text('E-mail address'),
          subtitle: Text(auth.email ?? ''),
          trailing: chevron(),
          onTap: () => _changeEmail(context, auth),
        ),
        ListTile(
          key: const ValueKey('account-signout-others'),
          leading: const Icon(LucideIcons.monitorX),
          title: const Text('Sign out other sessions'),
          subtitle: const Text('Every other phone or computer must sign in again'),
          onTap: () => _signOutOthers(context, auth),
        ),
        ListTile(
          key: const ValueKey('account-export'),
          leading: const Icon(LucideIcons.download),
          title: const Text('Download my data'),
          subtitle: const Text('What our server knows about your account, as a file. Your chats are not in it: '
              'they never reach the server in a form it can read.'),
          onTap: () => _export(context, auth),
        ),
      ]),
    );
  }

  /// Asks for the password (and, with two-step verification, a code).
  static Future<(String, String?)?> askPassword(BuildContext context, String title, {String? action}) async {
    final pw = TextEditingController();
    final otp = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: pw,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Your password'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: otp,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Two-step code (if you use it)'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action ?? 'Continue')),
        ],
      ),
    );
    if (ok != true || pw.text.isEmpty) return null;
    return (pw.text, otp.text.trim().isEmpty ? null : otp.text.trim());
  }

  static Future<String?> _ask(BuildContext context, String title, String label, {String? initial, TextInputType? type}) async {
    final c = TextEditingController(text: initial);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, keyboardType: type, decoration: InputDecoration(labelText: label)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Next')),
        ],
      ),
    );
    return ok == true && c.text.trim().isNotEmpty ? c.text.trim() : null;
  }

  Future<void> _changeUsername(BuildContext context, AuthProvider auth) async {
    final name = await _ask(context, 'New username', 'Username', initial: auth.username);
    if (name == null || name == auth.username || !context.mounted) return;
    final creds = await askPassword(context, 'Confirm it’s you', action: 'Change');
    if (creds == null || !context.mounted) return;
    final err = await auth.changeUsername(name, password: creds.$1, otp: creds.$2);
    if (!context.mounted) return;
    showAppSnackBar(context, err ?? 'Your username is now @${name.toLowerCase()}', error: err != null, success: err == null);
  }

  Future<void> _changeEmail(BuildContext context, AuthProvider auth) async {
    final email = await _ask(context, 'New e-mail address', 'E-mail', type: TextInputType.emailAddress);
    if (email == null || !context.mounted) return;
    final creds = await askPassword(context, 'Confirm it’s you', action: 'Send code');
    if (creds == null || !context.mounted) return;
    final err = await auth.startEmailChange(email, password: creds.$1, otp: creds.$2);
    if (!context.mounted) return;
    if (err != null) {
      showAppSnackBar(context, err, error: true);
      return;
    }
    final code = await _ask(context, 'Check $email', 'The 6-digit code we sent', type: TextInputType.number);
    if (code == null || !context.mounted) return;
    final err2 = await auth.confirmEmailChange(code);
    if (!context.mounted) return;
    showAppSnackBar(context, err2 ?? 'Your e-mail is now $email', error: err2 != null, success: err2 == null);
  }

  Future<void> _signOutOthers(BuildContext context, AuthProvider auth) async {
    final creds = await askPassword(context, 'Sign out other sessions?', action: 'Sign out');
    if (creds == null || !context.mounted) return;
    try {
      final n = await auth.signOutOthers(password: creds.$1, otp: creds.$2);
      if (context.mounted) {
        showAppSnackBar(context, n == 0 ? 'No other sessions were signed in' : 'Signed out $n other session${n == 1 ? '' : 's'}',
            success: true);
      }
    } catch (e) {
      if (context.mounted) showAppSnackBar(context, friendlyError(e.toString()), error: true);
    }
  }

  Future<void> _export(BuildContext context, AuthProvider auth) async {
    try {
      final data = await auth.exportData();
      final bytes = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(data)));
      final saved = await FilePicker.saveFile(
          fileName: 'securelyhello-account-data.json', bytes: bytes, mimeType: 'application/json');
      if (context.mounted && saved != null) showAppSnackBar(context, 'Saved', success: true);
    } catch (e) {
      if (context.mounted) showAppSnackBar(context, friendlyError(e.toString(), fallback: 'Could not download'), error: true);
    }
  }
}
