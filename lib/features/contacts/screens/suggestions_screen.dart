import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as book;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/contacts/screens/invite_screen.dart';
import 'package:securelyhello/features/home/chat_navigation.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';

typedef _Match = ({String bookName, UserSearchResult user, bool isContact});

/// People from the phone's address book who are on Securely Hello and let
/// themselves be found by e-mail. Only hashes of the addresses leave the
/// phone, and only when the user taps the button.
class SuggestionsScreen extends StatefulWidget {
  const SuggestionsScreen({super.key});

  @override
  State<SuggestionsScreen> createState() => _SuggestionsScreenState();
}

class _SuggestionsScreenState extends State<SuggestionsScreen> {
  List<_Match>? _matches;
  bool _busy = false;
  String? _error;
  final _sent = <String>{};

  Future<void> _scan() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await book.FlutterContacts.permissions.request(book.PermissionType.read);
      if (status != book.PermissionStatus.granted && status != book.PermissionStatus.limited) {
        setState(() => _error = 'Securely Hello needs access to your contacts to check them. '
            'You can allow it in system settings.');
        return;
      }
      final people = await book.FlutterContacts.getAll(properties: {book.ContactProperty.email});
      final emails = <String, String>{
        for (final c in people)
          for (final e in c.emails)
            if (e.address.contains('@')) e.address.trim(): c.displayName ?? e.address,
      };
      if (!mounted) return;
      final found = await context.read<ContactsProvider>().matchAddressBook(emails);
      setState(() => _matches = found);
    } catch (e) {
      setState(() => _error = friendlyError(e.toString()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add(_Match m) async {
    final ok = await context.read<ContactsProvider>().sendContactRequest(m.user.userId);
    if (!mounted) return;
    if (ok) setState(() => _sent.add(m.user.userId));
    showAppSnackBar(context, ok ? 'Request sent' : 'Could not send the request', error: !ok);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final matches = _matches;
    return Scaffold(
      appBar: AppBar(title: const Text('From your contacts')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          if (matches == null) ...[
            Icon(LucideIcons.contact, size: 44, color: p.accent),
            const SizedBox(height: 16),
            Text('See who you know here', textAlign: TextAlign.center, style: t.titleLarge),
            const SizedBox(height: 10),
            Text(
              'Securely Hello checks the e-mail addresses in your contacts against people who '
              'chose to be findable by e-mail. Addresses are hashed on this phone first, '
              'nothing is stored, and nobody is told you looked.',
              textAlign: TextAlign.center,
              style: t.bodyMedium?.copyWith(color: p.textSecondary, height: 1.45),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const ValueKey('suggestions-scan'),
              onPressed: _busy ? null : _scan,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(LucideIcons.search, size: 18),
              label: const Text('Check my contacts'),
            ),
          ] else if (matches.isEmpty) ...[
            const SizedBox(height: 24),
            Text('Nobody yet', textAlign: TextAlign.center, style: t.titleLarge),
            const SizedBox(height: 8),
            Text(
              "None of your contacts can be found by e-mail yet. Invite them, it's free.",
              textAlign: TextAlign.center,
              style: t.bodyMedium?.copyWith(color: p.textSecondary),
            ),
          ] else
            for (final m in matches)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: AvatarWidget(displayName: m.user.displayName, seed: m.user.userId),
                title: Text(m.bookName.isNotEmpty ? m.bookName : m.user.displayName),
                subtitle: Text('@${m.user.username}'),
                trailing: m.isContact
                    ? TextButton(onPressed: () => openChat(context, m.user.userId), child: const Text('Message'))
                    : _sent.contains(m.user.userId)
                        ? const Text('Requested')
                        : FilledButton(onPressed: () => _add(m), child: const Text('Add')),
              ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: p.danger)),
          ],
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => const InviteScreen())),
            icon: const Icon(LucideIcons.userPlus, size: 18),
            label: const Text('Invite someone'),
          ),
        ],
      ),
    );
  }
}
