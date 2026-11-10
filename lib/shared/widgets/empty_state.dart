import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';

/// A centred empty / error placeholder with icon, title, subtitle and an
/// optional call to action.
class EmptyStateWidget extends StatelessWidget {
  const EmptyStateWidget({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
    this.isError = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  /// Tints the icon with the danger colour.
  final bool isError;

  factory EmptyStateWidget.noContacts({VoidCallback? onAction}) {
    return EmptyStateWidget(
      icon: LucideIcons.users,
      title: 'No contacts yet',
      subtitle:
          'Find people by their username and send them a contact '
          'request. Once they accept, you can chat securely.',
      actionLabel: 'Find people',
      actionIcon: LucideIcons.userPlus,
      onAction: onAction,
    );
  }

  factory EmptyStateWidget.noMessages({VoidCallback? onAction}) {
    return EmptyStateWidget(
      icon: LucideIcons.messagesSquare,
      title: 'No chats yet',
      subtitle:
          'Start a conversation with one of your contacts. Messages are '
          'end-to-end encrypted.',
      actionLabel: onAction != null ? 'Start a chat' : null,
      actionIcon: LucideIcons.squarePen,
      onAction: onAction,
    );
  }

  factory EmptyStateWidget.noSearchResults({String? query}) {
    return EmptyStateWidget(
      icon: LucideIcons.searchX,
      title: 'No results',
      subtitle: query == null || query.isEmpty
          ? 'Try a different search term.'
          : 'Nothing matches “$query”. Check the spelling or try another '
                'term.',
    );
  }

  factory EmptyStateWidget.error({
    String title = 'Something went wrong',
    required String message,
    VoidCallback? onRetry,
  }) {
    return EmptyStateWidget(
      icon: LucideIcons.cloudAlert,
      title: title,
      subtitle: message,
      actionLabel: onRetry != null ? 'Try again' : null,
      actionIcon: LucideIcons.refreshCw,
      onAction: onRetry,
      isError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.xl,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: isError
                      ? p.danger.withAlpha(28)
                      : p.accentContainer.withAlpha(140),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: 36,
                  color: isError ? p.danger : p.onAccentContainer,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                title,
                style: t.titleLarge?.copyWith(fontSize: 20),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                subtitle,
                style: t.bodyMedium?.copyWith(
                  color: p.textSecondary,
                  height: 1.45,
                ),
                textAlign: TextAlign.center,
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: AppSpacing.lg),
                FilledButton.icon(
                  onPressed: onAction,
                  icon: Icon(actionIcon ?? LucideIcons.plus, size: 18),
                  label: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
