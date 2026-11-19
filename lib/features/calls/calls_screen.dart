import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/calls/call_service.dart';
import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/calls/call_screen.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/utils/chat_time_format.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/empty_state.dart';

/// The Calls tab: recent voice and video calls on this device, with a tap
/// to call back.
class CallsScreen extends StatefulWidget {
  const CallsScreen({super.key});

  @override
  State<CallsScreen> createState() => _CallsScreenState();
}

class _CallsScreenState extends State<CallsScreen> {
  List<CallRecord>? _log;
  StreamSubscription<void>? _sub;

  ChatService get _service => context.read<ChatProvider>().service;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sub != null) return;
    _sub = _service.onCallLogChanged.listen((_) => _load());
    _load();
  }

  Future<void> _load() async {
    List<CallRecord> log;
    try {
      log = await _service.callLog();
    } catch (_) {
      log = [];
    }
    if (mounted) setState(() => _log = log);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _call(String peer, bool video) async {
    final calls = context.read<CallService?>();
    if (calls == null) return;
    try {
      await calls.start(peer, video: video);
      if (mounted) unawaited(showCallScreen(context));
    } catch (e) {
      if (mounted) showAppSnackBar(context, friendlyError(e.toString(), fallback: "Couldn't call"), error: true);
    }
  }

  Future<void> _clear() async {
    final ok = await showConfirmDialog(context,
        title: 'Clear call history?',
        message: 'Your list of recent calls on this device is deleted. Chats keep their call notes.',
        confirmLabel: 'Clear',
        destructive: true);
    if (ok) await _service.clearCallLog();
  }

  @override
  Widget build(BuildContext context) {
    final log = _log;
    final contacts = context.watch<ContactsProvider>();
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calls'),
        actions: [
          if (log != null && log.isNotEmpty)
            IconButton(tooltip: 'Clear call history', icon: const Icon(LucideIcons.trash2), onPressed: _clear),
        ],
      ),
      body: log == null
          ? const Center(child: CircularProgressIndicator())
          : log.isEmpty
              ? EmptyStateWidget(
                  icon: LucideIcons.phone,
                  title: 'No calls yet',
                  subtitle: 'Voice and video calls are end-to-end encrypted. Start one from any chat.',
                )
              : ListView.builder(
                  key: const ValueKey('calls-list'),
                  itemCount: log.length,
                  itemBuilder: (context, i) {
                    final c = log[i];
                    final name = contacts.getContact(c.peer)?.displayLabel ?? 'Contact';
                    final (icon, color, label) = c.missed
                        ? (LucideIcons.phoneMissed, p.danger, 'Missed')
                        : c.outgoing
                            ? (LucideIcons.phoneOutgoing, p.success, 'Outgoing')
                            : (LucideIcons.phoneIncoming, p.accent, 'Incoming');
                    final detail = c.duration > Duration.zero
                        ? CallService.clock(c.duration)
                        : switch (c.result) {
                            'declined' => 'Declined',
                            'busy' => 'Busy',
                            'failed' => 'Couldn’t connect',
                            _ => c.outgoing ? 'No answer' : 'Missed',
                          };
                    return ListTile(
                      leading: AvatarWidget(displayName: name, seed: c.peer),
                      title: Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w600, color: c.missed ? p.danger : null)),
                      subtitle: Row(children: [
                        Icon(icon, size: 14, color: color, semanticLabel: label),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${ChatTimeFormat.listTimestamp(c.at, use24h: use24h)} · $detail',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.bodySmall,
                          ),
                        ),
                      ]),
                      trailing: IconButton(
                        tooltip: c.video ? 'Video call $name' : 'Call $name',
                        icon: Icon(c.video ? LucideIcons.video : LucideIcons.phone, color: p.accent),
                        onPressed: () => _call(c.peer, c.video),
                      ),
                    );
                  },
                ),
    );
  }
}
