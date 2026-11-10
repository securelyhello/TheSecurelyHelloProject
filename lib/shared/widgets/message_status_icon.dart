import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Delivery status of an outgoing message.
enum MessageStatus {
  /// Stored locally, not yet acknowledged by transport.
  sending,

  /// Handed to the peer (P2P) or to the relay queue.
  sent,

  /// The recipient's device received it.
  delivered,

  /// The recipient opened the conversation.
  read,

  /// Could not be sent; tap to retry.
  failed;

  /// Maps the storage status string (`sending`, `sent`, `delivered`, `read`,
  /// `failed`) used by `Message.status`.
  static MessageStatus fromString(String? s) {
    switch (s) {
      case 'read':
        return MessageStatus.read;
      case 'delivered':
        return MessageStatus.delivered;
      case 'sent':
        return MessageStatus.sent;
      case 'failed':
        return MessageStatus.failed;
      default:
        return MessageStatus.sending;
    }
  }

  String get label {
    switch (this) {
      case MessageStatus.sending:
        return 'Sending';
      case MessageStatus.sent:
        return 'Sent';
      case MessageStatus.delivered:
        return 'Delivered';
      case MessageStatus.read:
        return 'Read';
      case MessageStatus.failed:
        return 'Not sent';
    }
  }
}

/// Clock / single tick / double tick / coloured double tick / error icon.
class MessageStatusIcon extends StatelessWidget {
  const MessageStatusIcon({
    super.key,
    required this.status,
    required this.color,
    required this.readColor,
    required this.errorColor,
    this.size = 15,
  });

  final MessageStatus status;
  final Color color;
  final Color readColor;
  final Color errorColor;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color c) = switch (status) {
      MessageStatus.sending => (LucideIcons.clock3, color),
      MessageStatus.sent => (LucideIcons.check, color),
      MessageStatus.delivered => (LucideIcons.checkCheck, color),
      MessageStatus.read => (LucideIcons.checkCheck, readColor),
      MessageStatus.failed => (LucideIcons.circleAlert, errorColor),
    };
    return Semantics(
      container: true,
      label: status.label,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: Icon(
          icon,
          key: ValueKey(status),
          size: status == MessageStatus.sending ? size - 3 : size,
          color: c,
        ),
      ),
    );
  }
}
