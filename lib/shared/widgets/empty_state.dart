import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/l10n/app_localizations.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';

/// A centred empty / error placeholder with icon, title, subtitle and an
/// optional call to action.
class EmptyStateWidget extends StatelessWidget {
  EmptyStateWidget({
    super.key,
    required this.icon,
    required String title,
    required String subtitle,
    String? actionLabel,
    this.actionIcon,
    this.onAction,
    this.isError = false,
  })  : _title = ((_) => title),
        _subtitle = ((_) => subtitle),
        _action = actionLabel == null ? null : ((_) => actionLabel);

  const EmptyStateWidget._l10n({
    required this.icon,
    required String Function(L10n) title,
    required String Function(L10n) subtitle,
    String Function(L10n)? action,
    this.actionIcon,
    this.onAction,
    this.isError = false,
  })  : _title = title,
        _subtitle = subtitle,
        _action = action;

  final IconData icon;
  final String Function(L10n) _title;
  final String Function(L10n) _subtitle;
  final String Function(L10n)? _action;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  /// Tints the icon with the danger colour.
  final bool isError;

  factory EmptyStateWidget.noContacts({VoidCallback? onAction}) {
    return EmptyStateWidget._l10n(
      icon: LucideIcons.users,
      title: (l) => l.emptyContactsTitle,
      subtitle: (l) => l.emptyContactsBody,
      action: (l) => l.findPeople,
      actionIcon: LucideIcons.userPlus,
      onAction: onAction,
    );
  }

  factory EmptyStateWidget.noMessages({VoidCallback? onAction}) {
    return EmptyStateWidget._l10n(
      icon: LucideIcons.messagesSquare,
      title: (l) => l.emptyChatsTitle,
      subtitle: (l) => l.emptyChatsBody,
      action: onAction != null ? (l) => l.startChat : null,
      actionIcon: LucideIcons.squarePen,
      onAction: onAction,
    );
  }

  factory EmptyStateWidget.noSearchResults({String? query}) {
    return EmptyStateWidget._l10n(
      icon: LucideIcons.searchX,
      title: (l) => l.noResults,
      subtitle: (l) => query == null || query.isEmpty ? l.tryDifferentSearch : l.nothingMatches(query),
    );
  }

  factory EmptyStateWidget.error({
    String? title,
    required String message,
    VoidCallback? onRetry,
  }) {
    return EmptyStateWidget._l10n(
      icon: LucideIcons.cloudAlert,
      title: (l) => title ?? l.somethingWentWrong,
      subtitle: (_) => message,
      action: onRetry != null ? (l) => l.tryAgain : null,
      actionIcon: LucideIcons.refreshCw,
      onAction: onRetry,
      isError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final l = L10n.of(context);
    final title = _title(l);
    final subtitle = _subtitle(l);
    final actionLabel = _action?.call(l);
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
                  label: Text(actionLabel),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
