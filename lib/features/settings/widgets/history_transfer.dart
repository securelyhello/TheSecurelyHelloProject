import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';

/// After approving one of our devices: offer to copy our chats to it.
Future<void> offerHistoryTransfer(BuildContext context, String deviceName) async {
  final chat = context.read<ChatProvider>();
  final ok = await showConfirmDialog(
    context,
    title: 'Copy your chats to $deviceName?',
    message: 'Your messages are sent to it encrypted end to end, like any message. '
        "Disappearing messages aren't copied.",
    confirmLabel: 'Copy chats',
  );
  if (!ok || !context.mounted) return;
  try {
    final n = await chat.sendHistoryToMyDevices();
    if (context.mounted) showAppSnackBar(context, 'Sent $n messages to $deviceName');
  } catch (e) {
    if (context.mounted) showAppSnackBar(context, friendlyError(e.toString()), error: true);
  }
}
