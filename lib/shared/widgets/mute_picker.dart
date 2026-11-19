import 'package:flutter/material.dart';

/// How long to mute a chat for; null [duration] means until unmuted.
class MuteChoice {
  const MuteChoice(this.label, this.duration);
  final String label;
  final Duration? duration;
}

const muteChoices = [
  MuteChoice('8 hours', Duration(hours: 8)),
  MuteChoice('1 week', Duration(days: 7)),
  MuteChoice('Always', null),
];

/// Asks how long to mute notifications for. Null when dismissed.
Future<MuteChoice?> pickMuteDuration(BuildContext context) => showModalBottomSheet<MuteChoice>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Mute notifications for…', style: Theme.of(ctx).textTheme.titleMedium),
          ),
          for (final c in muteChoices)
            ListTile(title: Text(c.label), onTap: () => Navigator.pop(ctx, c)),
          const SizedBox(height: 8),
        ]),
      ),
    );
