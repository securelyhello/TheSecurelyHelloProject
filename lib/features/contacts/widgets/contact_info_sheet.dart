import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/contacts/widgets/report_dialog.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/utils/chat_time_format.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';

/// What the user did in the contact info sheet, so the caller can react
/// (open the chat, close a conversation whose contact was removed, …).
enum ContactSheetAction { message, cleared, removed, blocked }

/// Shows a contact's profile, the safety number shared with them and the
/// chat / contact management actions.
///
/// Both people see the same 60 digits. Comparing them in person or over a
/// call proves nobody (including the directory server) swapped the keys.
Future<ContactSheetAction?> showContactInfoSheet(
  BuildContext context,
  Contact contact, {
  bool showMessageAction = false,
}) {
  return showModalBottomSheet<ContactSheetAction>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => _ContactInfoSheet(
      contact: contact,
      showMessageAction: showMessageAction,
    ),
  );
}

class _ContactInfoSheet extends StatefulWidget {
  const _ContactInfoSheet({
    required this.contact,
    required this.showMessageAction,
  });

  final Contact contact;
  final bool showMessageAction;

  @override
  State<_ContactInfoSheet> createState() => _ContactInfoSheetState();
}

class _ContactInfoSheetState extends State<_ContactInfoSheet> {
  late final Future<String?> _safetyNumber = context
      .read<ChatProvider>()
      .safetyNumberFor(widget.contact.userId);
  bool _busy = false;

  Contact get c => widget.contact;

  Future<void> _clearChat() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Clear chat history?',
      message:
          'All messages with ${c.displayLabel} will be deleted from this '
          'device. This cannot be undone.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<ChatProvider>().clearConversation(c.userId);
      if (!mounted) return;
      showAppSnackBar(context, 'Chat history cleared');
      Navigator.pop(context, ContactSheetAction.cleared);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      showAppSnackBar(context, 'Could not clear the chat', error: true);
    }
  }

  Future<void> _removeContact() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Remove ${c.displayLabel}?',
      message:
          'They will be removed from your contacts. Your chat history on '
          'this device stays until you delete it.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final contacts = context.read<ContactsProvider>();
    final success = await contacts.removeContact(c.userId);
    if (!mounted) return;
    if (success) {
      showAppSnackBar(context, '${c.displayLabel} removed from contacts');
      Navigator.pop(context, ContactSheetAction.removed);
    } else {
      setState(() => _busy = false);
      showAppSnackBar(
        context,
        friendlyError(
          contacts.errorMessage,
          fallback: 'Could not remove contact',
        ),
        error: true,
      );
    }
  }

  Future<void> _block() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Block ${c.displayLabel}?',
      message:
          "They will be removed from your contacts and won't be able to find you, "
          "message you or call you. They aren't told. You can unblock them in "
          'Settings.',
      confirmLabel: 'Block',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final contacts = context.read<ContactsProvider>();
    if (await contacts.blockUser(c.userId)) {
      if (!mounted) return;
      showAppSnackBar(context, '${c.displayLabel} blocked');
      Navigator.pop(context, ContactSheetAction.blocked);
    } else if (mounted) {
      setState(() => _busy = false);
      showAppSnackBar(context, friendlyError(contacts.errorMessage), error: true);
    }
  }

  Future<void> _report() async {
    final sent = await showReportDialog(context, userId: c.userId, name: c.displayLabel);
    if (!sent || !mounted) return;
    showAppSnackBar(context, 'Thanks. The report was sent to the moderators.');
    final blocked = !context.read<ContactsProvider>().contacts.any((x) => x.userId == c.userId);
    if (blocked) Navigator.pop(context, ContactSheetAction.blocked);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final hasChat = context.select<ChatProvider, bool>(
      (chat) => chat.conversations.any((cv) => cv.contactUserId == c.userId),
    );

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AvatarWidget(
              displayName: c.displayLabel,
              seed: c.userId,
              isOnline: c.isOnline,
              size: AvatarSize.xlarge,
              ringColor: p.elevated,
            ),
            const SizedBox(height: 14),
            Text(
              c.displayLabel,
              textAlign: TextAlign.center,
              style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (c.username.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                '@${c.username}',
                style: t.bodyLarge?.copyWith(color: p.accent),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              c.isOnline
                  ? 'online'
                  : ChatTimeFormat.lastSeen(c.lastSeen, use24h: use24h),
              style: t.bodyMedium?.copyWith(
                color: c.isOnline ? p.online : p.textSecondary,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.showMessageAction)
                  _QuickAction(
                    icon: LucideIcons.messageCircle,
                    label: 'Message',
                    onTap: () =>
                        Navigator.pop(context, ContactSheetAction.message),
                  ),
                if (c.username.isNotEmpty)
                  _QuickAction(
                    icon: LucideIcons.atSign,
                    label: 'Copy username',
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: '@${c.username}'));
                      showAppSnackBar(context, 'Username copied');
                    },
                  ),
              ],
            ),
            const SizedBox(height: 22),
            _SafetyNumberCard(future: _safetyNumber, name: c.displayLabel),
            const SizedBox(height: 16),
            Material(
              color: p.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                side: BorderSide(color: p.divider),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  if (hasChat)
                    ListTile(
                      enabled: !_busy,
                      leading: Icon(LucideIcons.eraser, color: p.danger),
                      title: Text(
                        'Clear chat history',
                        style: TextStyle(color: p.danger),
                      ),
                      onTap: _clearChat,
                    ),
                  if (hasChat) const Divider(indent: 56),
                  ListTile(
                    enabled: !_busy,
                    leading: Icon(LucideIcons.userMinus, color: p.danger),
                    title: Text(
                      'Remove contact',
                      style: TextStyle(color: p.danger),
                    ),
                    onTap: _removeContact,
                  ),
                  const Divider(indent: 56),
                  ListTile(
                    key: const ValueKey('contact-block'),
                    enabled: !_busy,
                    leading: Icon(LucideIcons.ban, color: p.danger),
                    title: Text('Block ${c.displayLabel}', style: TextStyle(color: p.danger)),
                    onTap: _block,
                  ),
                  const Divider(indent: 56),
                  ListTile(
                    key: const ValueKey('contact-report'),
                    enabled: !_busy,
                    leading: Icon(LucideIcons.flag, color: p.danger),
                    title: Text('Report ${c.displayLabel}', style: TextStyle(color: p.danger)),
                    onTap: _report,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Material(
        color: p.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: onTap,
          child: Container(
            width: 112,
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: p.divider),
            ),
            child: Column(
              children: [
                Icon(icon, color: p.accent, size: 22),
                const SizedBox(height: 6),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: p.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SafetyNumberCard extends StatelessWidget {
  const _SafetyNumberCard({required this.future, required this.name});

  final Future<String?> future;
  final String name;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: p.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.shieldCheck, size: 18, color: p.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Safety number',
                  style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FutureBuilder<String?>(
            future: future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  ),
                );
              }
              final number = snapshot.data;
              if (snapshot.hasError || number == null) {
                return Text(
                  "$name's keys aren't available yet. Try again once you "
                  'have exchanged a message.',
                  style: t.bodyMedium?.copyWith(color: p.textSecondary),
                );
              }
              final groups = number
                  .split(RegExp(r'\s+'))
                  .where((g) => g.isNotEmpty);
              return Column(
                children: [
                  Semantics(
                    label: 'Safety number $number',
                    child: ExcludeSemantics(
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 18,
                        runSpacing: 10,
                        children: [
                          for (final g in groups)
                            Text(
                              g,
                              style: GoogleFonts.sourceCodePro(
                                fontSize: 17,
                                letterSpacing: 1.4,
                                fontWeight: FontWeight.w500,
                                color: p.textPrimary,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.center,
                    child: TextButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: number));
                        showAppSnackBar(context, 'Safety number copied');
                      },
                      icon: const Icon(LucideIcons.copy, size: 16),
                      label: const Text('Copy'),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 4),
          _DeviceCoverage(name: name),
          Text(
            'Compare these digits with $name in person or on a call. If they '
            'match, only the two of you can read your messages. The number '
            'changes if either of you reinstalls or signs in on a new device.',
            style: t.bodySmall?.copyWith(height: 1.45),
          ),
        ],
      ),
    );
  }
}

/// "Covers 2 devices of Mira's and 1 of yours." (needs the contact id via
/// the enclosing sheet).
class _DeviceCoverage extends StatelessWidget {
  const _DeviceCoverage({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final sheet = context.findAncestorStateOfType<_ContactInfoSheetState>();
    final chat = context.read<ChatProvider>();
    final me = chat.myUserId;
    if (sheet == null || me == null) return const SizedBox.shrink();
    return FutureBuilder<List<int>>(
      future: Future.wait([
        chat.deviceCount(sheet.c.userId),
        chat.deviceCount(me),
      ]),
      builder: (context, snap) {
        final counts = snap.data;
        if (counts == null) return const SizedBox(height: 4);
        String n(int x) => x == 1 ? '1 device' : '$x devices';
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            "Covers ${n(counts[0])} of $name's and ${n(counts[1])} of yours.",
            key: const ValueKey('safety-coverage'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.palette.accent,
                  fontWeight: FontWeight.w600,
                ),
          ),
        );
      },
    );
  }
}
