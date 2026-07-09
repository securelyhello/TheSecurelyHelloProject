import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/shared/theme/app_colors.dart';
import 'package:securelyhello/shared/theme/app_typography.dart';

/// Delivery status of a sent message.
enum MessageStatus {
  /// Message is being transmitted.
  sending,

  /// Server / peer acknowledged receipt of the ciphertext.
  sent,

  /// Recipient device received the message.
  delivered,

  /// Recipient opened / read the message.
  read,
}

/// A single chat bubble with asymmetric corner radii, delivery-status
/// indicators, entrance animation, and timestamp.
class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.timestamp,
    required this.isSent,
    this.status = MessageStatus.sent,
    this.showTail = true,
  });

  /// The message body.
  final String message;

  /// When the message was created / received.
  final DateTime timestamp;

  /// `true` → right-aligned teal bubble; `false` → left-aligned dark bubble.
  final bool isSent;

  /// Delivery status (only rendered for sent messages).
  final MessageStatus status;

  /// Whether the bubble shows the "tail" corner variant.
  final bool showTail;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with SingleTickerProviderStateMixin {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    // Trigger the entrance animation on the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _visible = true);
    });
  }

  // ─── Status icon ───────────────────────────────────────────────────
  Widget _buildStatusIcon() {
    switch (widget.status) {
      case MessageStatus.sending:
        return Icon(
          LucideIcons.clock,
          size: 13,
          color: AppColors.textHint,
        );
      case MessageStatus.sent:
        return Icon(
          LucideIcons.check,
          size: 13,
          color: AppColors.textHint,
        );
      case MessageStatus.delivered:
        return Icon(
          LucideIcons.checkCheck,
          size: 13,
          color: AppColors.textHint,
        );
      case MessageStatus.read:
        return Icon(
          LucideIcons.checkCheck,
          size: 13,
          color: AppColors.accent,
        );
    }
  }

  // ─── Timestamp ─────────────────────────────────────────────────────
  String _formattedTime() {
    final h = widget.timestamp.hour.toString().padLeft(2, '0');
    final m = widget.timestamp.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final maxBubbleWidth = screenWidth * 0.75;

    // Asymmetric corner radii.
    final borderRadius = widget.isSent
        ? BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: const Radius.circular(18),
            bottomRight: Radius.circular(widget.showTail ? 4 : 18),
          )
        : BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(widget.showTail ? 4 : 18),
            bottomRight: const Radius.circular(18),
          );

    final bubbleColor =
        widget.isSent ? AppColors.sentBubble : AppColors.receivedBubble;
    final bubbleBorder =
        widget.isSent ? AppColors.sentBubbleBorder : AppColors.receivedBubbleBorder;

    final slide = widget.isSent ? const Offset(0.15, 0) : const Offset(-0.15, 0);

    return AnimatedSlide(
      offset: _visible ? Offset.zero : slide,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: _visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        child: Align(
          alignment:
              widget.isSent ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(maxWidth: maxBubbleWidth),
            margin: EdgeInsets.only(
              left: widget.isSent ? 48 : 8,
              right: widget.isSent ? 8 : 48,
              bottom: 4,
            ),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: borderRadius,
              border: Border.all(
                color: bubbleBorder.withAlpha(widget.isSent ? 51 : 40),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.shadow.withAlpha(25),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Message text
                Text(
                  widget.message,
                  style: AppTypography.bodyMedium.copyWith(
                    color: widget.isSent
                        ? AppColors.textPrimary
                        : AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                // Timestamp + status row
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formattedTime(),
                      style: AppTypography.labelSmall.copyWith(
                        fontSize: 10,
                        color: AppColors.textHint,
                      ),
                    ),
                    if (widget.isSent) ...[
                      const SizedBox(width: 4),
                      _buildStatusIcon(),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
