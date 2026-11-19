import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/core/config/app_version.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/brand_logo.dart';

/// What's new in this version, shown once after an update (not after a
/// fresh install, which has the welcome pages).
abstract final class WhatsNew {
  static const _key = 'whats_new_seen';

  static const highlights = [
    (LucideIcons.sparkles, 'Stories', 'Share a moment with the people you pick. It disappears after 24 hours.'),
    (LucideIcons.phone, 'Calls that keep going', 'Calls ring like a phone call and carry on with the screen off.'),
    (LucideIcons.messageSquareReply, 'Reply from notifications', 'Answer or mark as read without opening the app.'),
    (LucideIcons.pin, 'Pin, archive, star, forward', 'Keep your chats tidy and find any message.'),
    (LucideIcons.palette, 'A fresh look', 'A new design, a new icon and Gujarati.'),
  ];

  /// Whether to show it: the app was used before, and not since this version.
  static Future<bool> due({required bool hadAccountBefore}) async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getString(_key);
    if (seen == AppVersion.name) return false;
    await prefs.setString(_key, AppVersion.name);
    return hadAccountBefore && seen != AppVersion.name;
  }

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) {
          final p = ctx.palette;
          final t = Theme.of(ctx).textTheme;
          return SafeArea(
            child: SingleChildScrollView(
              key: const ValueKey('whats-new'),
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const BrandLogo(size: 64),
                const SizedBox(height: 12),
                Text("What's new in ${AppVersion.name}", style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 16),
                for (final (icon, title, body) in highlights)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: p.accentContainer,
                      child: Icon(icon, color: p.onAccentContainer, size: 20),
                    ),
                    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(body),
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Got it')),
                ),
              ]),
            ),
          );
        },
      );
}
