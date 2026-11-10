import 'package:flutter/material.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';

/// One entry of an [showActionMenu].
class ActionItem<T> {
  const ActionItem({
    required this.value,
    required this.icon,
    required this.label,
    this.destructive = false,
  });

  final T value;
  final IconData icon;
  final String label;
  final bool destructive;
}

/// Shows contextual actions.
///
/// With a [position] (right-click on desktop / web) a popup menu opens at
/// that point; otherwise (long-press on touch) a bottom sheet slides up.
/// Resolves to the chosen value, or `null` if dismissed.
Future<T?> showActionMenu<T>(
  BuildContext context, {
  required List<ActionItem<T>> items,
  Offset? position,
  Widget? header,
}) {
  final p = context.palette;
  if (position != null) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    return showMenu<T>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final item in items)
          PopupMenuItem<T>(
            value: item.value,
            height: 44,
            child: Row(
              children: [
                Icon(
                  item.icon,
                  size: 18,
                  color: item.destructive ? p.danger : p.textSecondary,
                ),
                const SizedBox(width: 12),
                Text(
                  item.label,
                  style: TextStyle(
                    color: item.destructive ? p.danger : p.textPrimary,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  return showModalBottomSheet<T>(
    context: context,
    useSafeArea: true,
    builder: (ctx) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (header != null) ...[
              header,
              const SizedBox(height: AppSpacing.sm),
              const Divider(),
            ],
            for (final item in items)
              ListTile(
                leading: Icon(
                  item.icon,
                  color: item.destructive ? p.danger : p.textSecondary,
                ),
                title: Text(
                  item.label,
                  style: TextStyle(
                    color: item.destructive ? p.danger : p.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () => Navigator.pop(ctx, item.value),
              ),
          ],
        ),
      ),
    ),
  );
}
