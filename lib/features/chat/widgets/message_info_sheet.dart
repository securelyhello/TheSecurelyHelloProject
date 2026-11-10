import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/core/chat/chat_service.dart' show Message;
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/utils/chat_time_format.dart';
import 'package:securelyhello/shared/widgets/message_status_icon.dart';

/// Details for a single message: when it was sent / received and its
/// delivery state.
Future<void> showMessageInfoSheet(BuildContext context, Message m) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => _MessageInfo(message: m),
  );
}

class _MessageInfo extends StatelessWidget {
  const _MessageInfo({required this.message});

  final Message message;

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
            if (m.isFromMe)
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
              'Signed and encrypted on this device. Only the two of you can '
                  'read it.',
            ),
          ],
        ),
      ),
    );
  }
}
