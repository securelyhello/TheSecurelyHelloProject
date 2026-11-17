import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/utils/chat_time_format.dart';
import 'package:securelyhello/shared/widgets/message_status_icon.dart';

export 'package:securelyhello/shared/widgets/message_status_icon.dart'
    show MessageStatus;

/// A chat bubble.
///
/// * Consecutive messages from the same side form a group: inner corners are
///   tightened and only the last bubble of a group carries a tail.
/// * Time and (for outgoing messages) the delivery tick sit inside the bubble
///   at the bottom-right, flowing on the last line of text when it fits.
/// * URLs are highlighted; tapping one copies it.
class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.timestamp,
    required this.isSent,
    this.status = MessageStatus.sent,
    this.isFirstInGroup = true,
    this.isLastInGroup = true,
    this.animateIn = false,
    this.highlighted = false,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.attachment,
    this.replyQuote,
    this.edited = false,
    this.deleted = false,
    this.reactions = const [],
    this.onReactionsTap,
  });

  /// A quoted message this one replies to, shown at the top of the bubble.
  final Widget? replyQuote;

  /// Shows "edited" next to the time.
  final bool edited;

  /// Deleted for everyone: [message] is ignored and a tombstone is shown.
  final bool deleted;

  /// Emoji reactions (one entry per person), shown under the bubble.
  final List<String> reactions;
  final VoidCallback? onReactionsTap;

  final String message;

  /// Shown above the text (an image or a file card). With an attachment the
  /// text may be empty.
  final Widget? attachment;
  final DateTime timestamp;

  /// `true` → outgoing (right); `false` → incoming (left).
  final bool isSent;

  /// Delivery status (only rendered for outgoing messages).
  final MessageStatus status;

  final bool isFirstInGroup;
  final bool isLastInGroup;

  /// Play a short entrance animation (for messages that just arrived).
  final bool animateIn;

  /// Briefly tinted, e.g. while its action menu is open.
  final bool highlighted;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Right-click on desktop / web.
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  static final _urlPattern = RegExp(
    r'''((?:https?:\/\/|www\.)[^\s<>"']+[^\s<>"'.,;:!?)\]])''',
    caseSensitive: false,
  );

  final List<TapGestureRecognizer> _recognizers = [];
  late bool _visible = !widget.animateIn;

  @override
  void initState() {
    super.initState();
    if (!_visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _visible = true);
      });
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  List<InlineSpan> _textSpans(TextStyle base, Color linkColor) {
    _disposeRecognizers();
    final text = widget.message;
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _urlPattern.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      final url = m.group(0)!;
      final recognizer = TapGestureRecognizer()
        ..onTap = () {
          Clipboard.setData(ClipboardData(text: url));
          ScaffoldMessenger.maybeOf(context)
            ?..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(content: Text('Link copied')));
        };
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: url,
          style: base.copyWith(
            color: linkColor,
            decoration: TextDecoration.underline,
            decorationColor: linkColor,
          ),
          recognizer: recognizer,
          mouseCursor: SystemMouseCursors.click,
        ),
      );
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return spans;
  }

  BorderRadius _radius() {
    const r = Radius.circular(AppRadius.bubble);
    const g = Radius.circular(AppRadius.bubbleGrouped);
    final top = widget.isFirstInGroup ? r : g;
    // The tail replaces the bottom corner on the last bubble of a group.
    final bottom = widget.isLastInGroup ? const Radius.circular(2) : g;
    return widget.isSent
        ? BorderRadius.only(
            topLeft: r,
            bottomLeft: r,
            topRight: top,
            bottomRight: bottom,
          )
        : BorderRadius.only(
            topRight: r,
            bottomRight: r,
            topLeft: top,
            bottomLeft: bottom,
          );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context);
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);
    final isSent = widget.isSent;

    final bg = isSent ? p.bubbleOut : p.bubbleIn;
    final fg = isSent ? p.bubbleOutText : p.bubbleInText;
    final meta = isSent ? p.bubbleOutMeta : p.bubbleInMeta;

    final textStyle = (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
      color: fg,
      fontSize: 15.5,
      height: 1.35,
      letterSpacing: 0.1,
    );
    final metaStyle = (theme.textTheme.labelSmall ?? const TextStyle())
        .copyWith(color: meta, fontSize: 11, height: 1.0, letterSpacing: 0.2);

    final timeText = ChatTimeFormat.time(widget.timestamp, use24h: use24h);
    final metaRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.edited && !widget.deleted)
          Text('edited  ', style: metaStyle.copyWith(fontStyle: FontStyle.italic)),
        Text(timeText, style: metaStyle),
        if (isSent && !widget.deleted) ...[
          const SizedBox(width: 3),
          MessageStatusIcon(
            status: widget.status,
            color: meta,
            readColor: p.tickRead,
            errorColor: p.danger,
            size: 15,
          ),
        ],
      ],
    );

    // Reserve room for the meta row on the last line of text.
    final timePainter = TextPainter(
      text: TextSpan(
          text: (widget.edited && !widget.deleted ? 'edited  ' : '') + timeText,
          style: metaStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final metaWidth = timePainter.width + (isSent ? 20 : 0) + 10;
    timePainter.dispose();

    final textBody = Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text.rich(
            TextSpan(
              style: textStyle,
              children: [
                if (widget.deleted)
                  TextSpan(
                    text: isSent ? 'You deleted this message' : 'This message was deleted',
                    style: textStyle.copyWith(fontStyle: FontStyle.italic, color: meta),
                  )
                else
                  ..._textSpans(textStyle, p.link),
                WidgetSpan(child: SizedBox(width: metaWidth, height: 12)),
              ],
            ),
          ),
        ),
        Positioned(right: 0, bottom: 0, child: metaRow),
      ],
    );
    final att = widget.deleted ? null : widget.attachment;
    final quote = widget.deleted ? null : widget.replyQuote;
    final Widget withAttachment = att == null
        ? textBody
        : Column(
            // Caption reads left to right; a lone time stamp sits right.
            crossAxisAlignment: widget.message.isEmpty
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: att,
              ),
              if (widget.message.isEmpty) metaRow else textBody,
            ],
          );
    final Widget body = quote == null
        ? withAttachment
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(padding: const EdgeInsets.only(bottom: 4), child: quote),
              withAttachment,
            ],
          );

    final bubble = AnimatedContainer(
      duration: AppMotion.fast,
      padding: widget.attachment == null
          ? const EdgeInsets.fromLTRB(11, 7, 9, 6)
          : const EdgeInsets.fromLTRB(4, 4, 8, 6),
      decoration: BoxDecoration(
        color: widget.highlighted
            ? Color.alphaBlend(p.accent.withAlpha(40), bg)
            : bg,
        borderRadius: _radius(),
        boxShadow: theme.brightness == Brightness.light
            ? const [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 1.5,
                  offset: Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: body,
    );

    final withTail = widget.isLastInGroup
        ? CustomPaint(
            painter: _TailPainter(
              color: widget.highlighted
                  ? Color.alphaBlend(p.accent.withAlpha(40), bg)
                  : bg,
              isSent: isSent,
            ),
            child: bubble,
          )
        : bubble;

    final failed = isSent && widget.status == MessageStatus.failed;

    Widget content = LayoutBuilder(
      builder: (context, constraints) {
        final maxW = (constraints.maxWidth * 0.8)
            .clamp(0.0, AppBreakpoints.bubbleMaxWidth)
            .toDouble();
        return Align(
          alignment: isSent ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW),
            child: Column(
              crossAxisAlignment: isSent
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onTap,
                  onLongPress: widget.onLongPress == null
                      ? null
                      : () {
                          HapticFeedback.selectionClick();
                          widget.onLongPress!();
                        },
                  onSecondaryTapDown: widget.onSecondaryTapDown,
                  child: withTail,
                ),
                if (widget.reactions.isNotEmpty && !widget.deleted)
                  Transform.translate(
                    offset: const Offset(0, -4),
                    child: GestureDetector(
                      onTap: widget.onReactionsTap,
                      child: Container(
                        key: const ValueKey('reactions'),
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: p.surface,
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(color: p.divider),
                        ),
                        child: Text(_reactionSummary(widget.reactions),
                            style: const TextStyle(fontSize: 13)),
                      ),
                    ),
                  ),
                if (failed)
                  Padding(
                    padding: const EdgeInsets.only(top: 3, right: 4),
                    child: Text(
                      'Not sent · Tap to retry',
                      style: metaStyle.copyWith(
                        color: p.danger,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );

    content = Padding(
      padding: EdgeInsets.only(left: isSent ? 48 : 10, right: isSent ? 10 : 48),
      child: content,
    );

    if (!widget.animateIn) return content;
    return AnimatedSlide(
      offset: _visible ? Offset.zero : const Offset(0, 0.25),
      duration: AppMotion.medium,
      curve: AppMotion.curve,
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: AppMotion.medium,
        curve: AppMotion.curve,
        child: content,
      ),
    );
  }
}

/// Small curved tail drawn outside the bubble's bottom corner.
/// "👍 2 ❤️" — each emoji once, with a count when more than one person used it.
String _reactionSummary(List<String> reactions) {
  final counts = <String, int>{};
  for (final r in reactions) {
    counts[r] = (counts[r] ?? 0) + 1;
  }
  return counts.entries.map((e) => e.value > 1 ? '${e.key} ${e.value}' : e.key).join(' ');
}

class _TailPainter extends CustomPainter {
  _TailPainter({required this.color, required this.isSent});

  final Color color;
  final bool isSent;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path();
    final b = size.height;
    if (isSent) {
      final x = size.width;
      path
        ..moveTo(x - 10, b)
        ..lineTo(x + 6, b)
        ..quadraticBezierTo(x + 1, b - 2, x, b - 10)
        ..lineTo(x - 10, b - 10)
        ..close();
    } else {
      path
        ..moveTo(10, b)
        ..lineTo(-6, b)
        ..quadraticBezierTo(-1, b - 2, 0, b - 10)
        ..lineTo(10, b - 10)
        ..close();
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TailPainter old) =>
      old.color != color || old.isSent != isSent;
}
