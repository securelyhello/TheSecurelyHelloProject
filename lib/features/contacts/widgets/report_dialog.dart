import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';

/// Asks why the user is reporting [contact], optionally attaches their last
/// messages (the only content moderators ever see, since everything else is
/// end-to-end encrypted), and optionally blocks them. Returns true if sent.
Future<bool> showReportDialog(BuildContext context,
    {required String userId, required String name}) async {
  final sent = await showDialog<bool>(
    context: context,
    builder: (_) => _ReportDialog(userId: userId, name: name),
  );
  return sent == true;
}

class _ReportDialog extends StatefulWidget {
  const _ReportDialog({required this.userId, required this.name});
  final String userId;
  final String name;

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  static const reasons = {
    'spam': 'Spam or scam',
    'harassment': 'Harassment or threats',
    'impersonation': 'Pretending to be someone else',
    'illegal': 'Illegal content',
    'other': 'Something else',
  };

  String _reason = 'spam';
  bool _includeMessages = true;
  bool _alsoBlock = true;
  bool _busy = false;
  final _details = TextEditingController();

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    final contacts = context.read<ContactsProvider>();
    var evidence = <Map<String, dynamic>>[];
    if (_includeMessages) {
      final recent = await context.read<ChatProvider>().recentMessages(widget.userId, limit: 20);
      evidence = [
        for (final m in recent.reversed)
          if (!m.isSystem && m.content.isNotEmpty)
            {
              'from': m.isFromMe ? 'reporter' : 'reported',
              'text': m.content,
              'at': m.timestamp.toUtc().toIso8601String(),
            }
      ];
    }
    final ok = await contacts.reportUser(widget.userId,
        reason: _reason, details: _details.text.trim(), evidence: evidence);
    if (ok && _alsoBlock) await contacts.blockUser(widget.userId);
    if (!mounted) return;
    if (!ok) {
      setState(() => _busy = false);
      showAppSnackBar(context, friendlyError(contacts.errorMessage, fallback: 'Report not sent'),
          error: true);
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text('Report ${widget.name}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RadioGroup<String>(
                groupValue: _reason,
                onChanged: (v) => setState(() => _reason = v ?? _reason),
                child: Column(children: [
                  for (final e in reasons.entries)
                    RadioListTile<String>(
                      key: ValueKey('reason-${e.key}'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: e.key,
                      title: Text(e.value),
                    ),
                ]),
              ),
              TextField(
                controller: _details,
                maxLength: 2000,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(hintText: 'What happened? (optional)'),
              ),
              CheckboxListTile(
                key: const ValueKey('report-include'),
                contentPadding: EdgeInsets.zero,
                value: _includeMessages,
                onChanged: (v) => setState(() => _includeMessages = v ?? false),
                title: const Text('Include recent messages'),
                subtitle: Text(
                  'Your last 20 messages with ${widget.name} are sent to the moderators. '
                  'Nothing else from this chat can be read by anyone but you two.',
                  style: t.bodySmall,
                ),
              ),
              CheckboxListTile(
                key: const ValueKey('report-block'),
                contentPadding: EdgeInsets.zero,
                value: _alsoBlock,
                onChanged: (v) => setState(() => _alsoBlock = v ?? false),
                title: Text('Also block ${widget.name}'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('report-send'),
          onPressed: _busy ? null : _send,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Report'),
        ),
      ],
    );
  }
}
