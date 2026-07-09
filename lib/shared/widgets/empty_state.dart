import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/shared/theme/app_colors.dart';
import 'package:securelyhello/shared/theme/app_typography.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';

/// A centered empty-state placeholder with icon, title, subtitle, and an
/// optional call-to-action button.
class EmptyStateWidget extends StatelessWidget {
  const EmptyStateWidget({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  /// Large decorative icon.
  final IconData icon;

  /// Primary heading.
  final String title;

  /// Supporting description.
  final String subtitle;

  /// Label for the optional CTA button.
  final String? actionLabel;

  /// Callback when the CTA button is pressed.
  final VoidCallback? onAction;

  // ─── Factory constructors ──────────────────────────────────────────

  /// "No contacts yet" state.
  factory EmptyStateWidget.noContacts({VoidCallback? onAction}) {
    return EmptyStateWidget(
      icon: LucideIcons.users,
      title: 'No contacts yet',
      subtitle:
          'Add a contact by sharing your connection code or scanning theirs.',
      actionLabel: 'Add Contact',
      onAction: onAction,
    );
  }

  /// "No messages" state for a fresh conversation.
  factory EmptyStateWidget.noMessages({VoidCallback? onAction}) {
    return EmptyStateWidget(
      icon: LucideIcons.messageCircle,
      title: 'No messages yet',
      subtitle: 'Send the first message to start a secure conversation.',
      actionLabel: onAction != null ? 'Say Hello' : null,
      onAction: onAction,
    );
  }

  /// "No search results" state.
  factory EmptyStateWidget.noSearchResults() {
    return const EmptyStateWidget(
      icon: LucideIcons.searchX,
      title: 'No results found',
      subtitle: 'Try a different search term or check for typos.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xl,
        vertical: AppSpacing.xxl,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Icon
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: AppColors.elevated,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.border, width: 1),
            ),
            child: Icon(
              icon,
              size: 40,
              color: AppColors.textHint,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Title
          Text(
            title,
            style: AppTypography.titleLarge.copyWith(
              color: AppColors.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),

          // Subtitle
          Text(
            subtitle,
            style: AppTypography.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),

          // CTA button
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              width: 220,
              child: ElevatedButton.icon(
                onPressed: onAction,
                icon: const Icon(LucideIcons.plus, size: 18),
                label: Text(actionLabel!),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
