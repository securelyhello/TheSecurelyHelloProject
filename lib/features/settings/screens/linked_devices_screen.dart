import 'package:flutter/material.dart';

import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/shared/theme/app_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/features/settings/widgets/history_transfer.dart';
import 'package:securelyhello/core/crypto/device_manager.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';

/// Every device signed in to this account. Each has its own keys; contacts
/// encrypt every message to all of them. Removing a device signs it out
/// and stops new messages reaching it.
class LinkedDevicesScreen extends StatefulWidget {
  const LinkedDevicesScreen({super.key});

  @override
  State<LinkedDevicesScreen> createState() => _LinkedDevicesScreenState();
}

class _LinkedDevicesScreenState extends State<LinkedDevicesScreen> {
  late Future<List<Map<String, dynamic>>> _devices = _load();

  Future<List<Map<String, dynamic>>> _load() =>
      context.read<AuthProvider>().listDevices();

  void _reload() => setState(() => _devices = _load());

  /// A device of ours that no trusted device approved (with a signature):
  /// confirm only if the code matches what that device shows.
  Future<void> _confirm(Map<String, dynamic> d) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Is ${_nameOf(d)} yours?',
      message: 'This device didn’t approve it, so it gets no copies of your messages yet. '
          'Confirm only if it shows this code in Settings → Linked devices:\n\n${_fingerprint(d)}',
      confirmLabel: 'It’s mine',
    );
    if (!ok || !mounted) return;
    await context.read<ChatProvider>().service.trustOwnDevice(d['device_id'] as String);
    if (mounted) _reload();
  }

  Future<void> _remove(Map<String, dynamic> d) async {
    final name = _nameOf(d);
    final ok = await showConfirmDialog(
      context,
      title: 'Remove $name?',
      message:
          'It will be signed out and stop receiving new messages. Chats '
          'already on it stay there until it is reset. Your contacts will see '
          'that your safety number changed.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final auth = context.read<AuthProvider>();
    final done = await auth.removeDevice(d['device_id'] as String);
    if (!mounted) return;
    showAppSnackBar(
      context,
      done ? '$name removed' : friendlyError(auth.errorMessage),
      error: !done,
    );
    _reload();
  }

  Future<void> _rename(Map<String, dynamic> d) async {
    final controller = TextEditingController(text: d['name'] as String? ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this device'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 64,
          decoration: const InputDecoration(hintText: 'e.g. Work laptop'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;
    await context.read<AuthProvider>().renameThisDevice(name);
    _reload();
  }

  static String _nameOf(Map<String, dynamic> d) {
    final n = (d['name'] as String? ?? '').trim();
    return n.isEmpty ? 'Unnamed device' : n;
  }

  /// Last 8 characters of the signing key, grouped: something people can
  /// compare between two of their own screens.
  static String _fingerprint(Map<String, dynamic> d) {
    final k = d['signing_public_key'] as String?;
    return k == null ? '' : DeviceManager.fingerprint(k);
  }

  static String _when(String? iso) {
    final t = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 2) return 'active now';
    if (d.inHours < 1) return 'active ${d.inMinutes} min ago';
    if (d.inDays < 1) return 'active ${d.inHours} h ago';
    return 'active ${d.inDays} d ago';
  }

  IconData _icon(String name) {
    final n = name.toLowerCase();
    if (n.contains('android') || n.contains('iphone')) return LucideIcons.smartphone;
    return LucideIcons.laptop;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Linked devices')),
      body: RefreshIndicator(
        onRefresh: () async {
          _reload();
          await _devices;
        },
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _devices,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return ListView(children: [
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text("Couldn't load your devices. Pull to retry.",
                      textAlign: TextAlign.center, style: t.bodyMedium),
                ),
              ]);
            }
            final devices = snap.data!;
            final unconfirmed = {
              for (final d in context.read<ChatProvider>().service.untrustedOwnDevices) d['device_id'] as String,
            };
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                  child: Text(
                    'Each device has its own keys and its own encrypted '
                    'sessions. Messages you send and receive reach all of '
                    'them. Remove any device you don\'t recognise.',
                    style: t.bodySmall?.copyWith(height: 1.45),
                  ),
                ),
                for (final d in devices)
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: p.surface,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      border: Border.all(
                          color: d['current'] == true ? p.accent : p.divider),
                    ),
                    child: ListTile(
                      key: ValueKey('device-${d['device_id']}'),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      leading: Icon(_icon(_nameOf(d)), color: p.accent),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(_nameOf(d),
                                overflow: TextOverflow.ellipsis,
                                style: t.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600)),
                          ),
                          if (d['current'] == true) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: p.accent.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Text('This device',
                                  style: t.labelSmall?.copyWith(color: p.accent)),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text.rich(TextSpan(children: [
                          TextSpan(text: d['approved'] != false && d['current'] != true && unconfirmed.contains(d['device_id'])
                              ? 'not confirmed on this device: gets no copies of your messages'
                              : d['approved'] == false
                              ? 'waiting for approval'
                              : d['current'] == true
                                  ? 'active now'
                                  : _when(d['last_seen_at'] as String?)),
                          const TextSpan(text: '  ·  key '),
                          TextSpan(
                            text: _fingerprint(d),
                            style: AppFonts.mono(fontSize: 12),
                          ),
                        ])),
                      ),
                      trailing: d['approved'] != false &&
                              d['current'] != true &&
                              unconfirmed.contains(d['device_id'])
                          ? TextButton(
                              key: ValueKey('confirm-${d['device_id']}'),
                              onPressed: () => _confirm(d),
                              child: const Text('Confirm'),
                            )
                          : d['approved'] == false
                          ? Row(mainAxisSize: MainAxisSize.min, children: [
                              TextButton(
                                key: ValueKey('approve-${d['device_id']}'),
                                onPressed: () async {
                                  final ok = await context.read<AuthProvider>().approveDevice(d);
                                  if (!context.mounted) return;
                                  showAppSnackBar(context, ok ? 'Approved' : 'Could not approve it', error: !ok);
                                  _reload();
                                  if (ok) await offerHistoryTransfer(context, _nameOf(d));
                                },
                                child: const Text('Approve'),
                              ),
                              IconButton(
                                tooltip: 'Remove',
                                icon: Icon(LucideIcons.trash2, size: 18, color: p.danger),
                                onPressed: () => _remove(d),
                              ),
                            ])
                          : d['current'] == true
                          ? IconButton(
                              tooltip: 'Rename',
                              icon: const Icon(LucideIcons.pencil, size: 18),
                              onPressed: () => _rename(d),
                            )
                          : IconButton(
                              tooltip: 'Remove',
                              icon: Icon(LucideIcons.trash2,
                                  size: 18, color: p.danger),
                              onPressed: () => _remove(d),
                            ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
