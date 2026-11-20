import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'package:securelyhello/core/invites/invites.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/contacts/widgets/invite_prompt.dart';
import 'package:securelyhello/features/contacts/widgets/verify_widgets.dart' show canScanQr, scanVerifyQr;
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';

/// Your invite link and QR code, and a place to open someone else's.
class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key});

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  late Future<Map<String, dynamic>> _invite = context.read<ContactsProvider>().createInvite();
  final _paste = TextEditingController();

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  String _message(String url) {
    final me = context.read<AuthProvider>().username;
    return "Let's chat on Securely Hello, an end-to-end encrypted messenger. "
        'Open this to add me${me.isEmpty ? '' : ' (@$me)'}: $url';
  }

  Future<void> _open(String text) async {
    final token = inviteTokenFrom(text);
    if (token == null) {
      showAppSnackBar(context, "That isn't a Securely Hello invite link", error: true);
      return;
    }
    await openInvite(context, token);
  }

  Future<void> _revoke() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Turn off your invite links?',
      message: 'Links you already sent will stop working. People can still find you by username.',
      confirmLabel: 'Turn off',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await context.read<ContactsProvider>().revokeInvites();
    if (!mounted) return;
    showAppSnackBar(context, 'Old links turned off');
    setState(() => _invite = context.read<ContactsProvider>().createInvite());
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Invite friends')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _invite,
        builder: (context, snap) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              Text(
                'Anyone who opens your link or scans your code can add you straight away. '
                'Share it only with people you want to talk to.',
                style: t.bodyMedium?.copyWith(color: p.textSecondary, height: 1.45),
              ),
              const SizedBox(height: 20),
              if (snap.connectionState != ConnectionState.done)
                const Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (snap.hasError)
                Text(friendlyError(snap.error.toString()), style: TextStyle(color: p.danger))
              else ...[
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                    ),
                    child: QrImageView(
                      key: const ValueKey('invite-qr'),
                      data: snap.data!['url'] as String,
                      size: 220,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SelectableText(
                  snap.data!['url'] as String,
                  key: const ValueKey('invite-url'),
                  textAlign: TextAlign.center,
                  style: t.bodySmall?.copyWith(color: p.textSecondary),
                ),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => SharePlus.instance.share(ShareParams(
                        text: _message(snap.data!['url'] as String),
                        subject: 'Chat with me on Securely Hello',
                      )),
                      icon: const Icon(LucideIcons.share2, size: 18),
                      label: const Text('Share'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: snap.data!['url'] as String));
                        showAppSnackBar(context, 'Link copied');
                      },
                      icon: const Icon(LucideIcons.copy, size: 18),
                      label: const Text('Copy'),
                    ),
                  ),
                ]),
                const SizedBox(height: 6),
                Text(
                  'Works ${snap.data!['max_uses']} times within ${snap.data!['expires_in_days']} days.',
                  textAlign: TextAlign.center,
                  style: t.bodySmall?.copyWith(color: p.textMuted),
                ),
                TextButton(onPressed: _revoke, child: const Text('Turn off links I sent')),
              ],
              const Divider(height: 40),
              Text('Got an invite?', style: t.titleSmall),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('invite-paste'),
                controller: _paste,
                decoration: InputDecoration(
                  hintText: 'Paste the link',
                  prefixIcon: const Icon(LucideIcons.link),
                  suffixIcon: IconButton(
                    tooltip: 'Open',
                    icon: const Icon(LucideIcons.arrowRight),
                    onPressed: () => _open(_paste.text),
                  ),
                ),
                onSubmitted: _open,
              ),
              if (canScanQr) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () async {
                    final code = await scanVerifyQr(context);
                    if (code != null && context.mounted) await _open(code);
                  },
                  icon: const Icon(LucideIcons.scanLine, size: 18),
                  label: const Text('Scan their code'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
