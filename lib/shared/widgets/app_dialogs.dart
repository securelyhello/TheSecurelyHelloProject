import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';

/// Asks the user to confirm an action. Resolves to `true` only on confirm.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final p = context.palette;
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Text(message),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          style: TextButton.styleFrom(foregroundColor: p.textSecondary),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: p.danger,
                  foregroundColor: Theme.of(ctx).colorScheme.onError,
                )
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Shows a floating snackbar, replacing any current one.
void showAppSnackBar(
  BuildContext context,
  String message, {
  bool error = false,
  bool success = false,
  SnackBarAction? action,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final icon = error
      ? LucideIcons.circleAlert
      : success
      ? LucideIcons.circleCheck
      : null;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        action: action,
        // Snackbars with an action otherwise stay until dismissed.
        persist: false,
        duration: Duration(seconds: error ? 5 : 3),
        content: Row(
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 18,
                // The snackbar is ink in both themes, so use the Night tokens.
                color: error ? AppPalette.dark.danger : AppPalette.dark.success,
              ),
              const SizedBox(width: 10),
            ],
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
}

/// Strips the "Failed to …: Exception: " noise from provider errors so a
/// snackbar shows something readable.
String friendlyError(String? raw, {String fallback = 'Something went wrong'}) {
  if (raw == null || raw.trim().isEmpty) return fallback;
  var s = raw.trim();
  final colon = s.indexOf(': ');
  if (colon > 0) {
    // Keep the provider's own sentence ("Failed to send request"); append
    // the cause only when it reads like a sentence rather than a dump.
    final head = s.substring(0, colon);
    final detail = s
        .substring(colon + 2)
        .replaceFirst(RegExp(r'^\w*(Exception|Error)\s*:\s*'), '')
        .trim();
    final readable =
        detail.isNotEmpty &&
        detail.length <= 90 &&
        !detail.contains(RegExp(r'[{}\[\]<>()]'));
    s = readable ? '$head. $detail' : head;
  }
  if (s.length > 160) s = '${s.substring(0, 160)}…';
  return s.isEmpty ? fallback : s;
}
