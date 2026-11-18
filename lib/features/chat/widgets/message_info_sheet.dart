import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/core/chat/chat_service.dart' show Message;
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/utils/chat_time_format.dart';
import 'package:securelyhello/shared/widgets/message_status_icon.dart';

/// Details for a single message: when it was sent / received and its
/// delivery state. For our group messages, [receipts] has each member's
/// status, and [nameOf] names them.
Future<void> showMessageInfoSheet(
  BuildContext context,
  Message m, {
  Map<String, String>? receipts,
  String Function(String userId)? nameOf,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => _MessageInfo(message: m, receipts: receipts, nameOf: nameOf),
  );
}

class _MessageInfo extends StatelessWidget {
  const _MessageInfo({required this.message, this.receipts, this.nameOf});

  final Message message;
  final Map<String, String>? receipts;
  final String Function(String userId)? nameOf;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final m = message;
    final status = MessageStatus.fromString(m.status);

    Widget row(Widget leading, String title, String value) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: leading,
      title: Text(title),
      subtitle: Text(value),
    );

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Message info',
              style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: m.isFromMe ? p.bubbleOut : p.bubbleIn,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Text(
                m.content,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: t.bodyLarge?.copyWith(
                  color: m.isFromMe ? p.bubbleOutText : p.bubbleInText,
                ),
              ),
            ),
            const SizedBox(height: 8),
            row(
              Icon(
                m.isFromMe ? LucideIcons.send : LucideIcons.inbox,
                color: p.textSecondary,
              ),
              m.isFromMe ? 'Sent' : 'Received',
              ChatTimeFormat.full(m.timestamp, use24h: use24h),
            ),
            if (m.isFromMe && receipts != null)
              ..._groupReceipts(context, receipts!, nameOf ?? (u) => u)
            else if (m.isFromMe)
              row(
                MessageStatusIcon(
                  status: status,
                  color: p.textSecondary,
                  readColor: p.tickRead,
                  errorColor: p.danger,
                  size: 22,
                ),
                'Status',
                switch (status) {
                  MessageStatus.sending => 'Sending…',
                  MessageStatus.sent =>
                    'Sent — waiting for their device to receive it',
                  MessageStatus.delivered => 'Delivered to their device',
                  MessageStatus.read => 'Read',
                  MessageStatus.failed => 'Not sent — tap the message to retry',
                },
              ),
            row(
              Icon(LucideIcons.lock, color: p.accent),
              'End-to-end encrypted',
              receipts != null
                  ? 'Encrypted on this device for each member. Only people in the group can read it.'
                  : 'Signed and encrypted on this device. Only the two of you can read it.',
            ),
          ],
        ),
      ),
    );
  }

  /// Members grouped by how far the message got: read, delivered, waiting.
  List<Widget> _groupReceipts(BuildContext context, Map<String, String> receipts, String Function(String) nameOf) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final groups = <(String, MessageStatus, List<String>)>[
      ('Read by', MessageStatus.read, []),
      ('Delivered to', MessageStatus.delivered, []),
      ('Waiting for', MessageStatus.sent, []),
    ];
    for (final e in receipts.entries) {
      final i = switch (e.value) { 'read' => 0, 'delivered' => 1, _ => 2 };
      groups[i].$3.add(nameOf(e.key));
    }
    return [
      for (final (label, status, names) in groups)
        if (names.isNotEmpty)
          ListTile(
            key: ValueKey('receipts-${status.name}'),
            contentPadding: EdgeInsets.zero,
            leading: MessageStatusIcon(
                status: status, color: p.textSecondary, readColor: p.tickRead, errorColor: p.danger, size: 22),
            title: Text(label),
            subtitle: Text((names..sort()).join(', '), style: t.bodyMedium?.copyWith(color: p.textSecondary)),
          ),
      if (receipts.isEmpty)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(LucideIcons.users, color: p.textSecondary),
          title: const Text('Nobody else is in the group'),
        ),
    ];
  }
}
