import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';

/// Message composer: a multi-line field that grows up to six lines and a
/// send button that animates in once there is text.
///
/// On desktop and web, Enter sends and Shift+Enter inserts a new line. On
/// phones, Enter inserts a new line and the button sends.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    this.onChanged,
    this.onAttach,
    this.uploading = false,
    this.header,
    this.enabled = true,
    this.hint = 'Message',
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final ValueChanged<String>? onChanged;

  /// Pick and send a file. The button is hidden when null.
  final VoidCallback? onAttach;

  /// An attachment is being encrypted and uploaded.
  final bool uploading;

  /// Shown above the field (e.g. "Replying to …" or "Editing").
  final Widget? header;
  final bool enabled;
  final String hint;

  /// Whether Enter sends (hardware-keyboard platforms).
  static bool get enterSends {
    if (kIsWeb) return true;
    return switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      _ => false,
    };
  }

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.trim().isNotEmpty;
    widget.controller.addListener(_onText);
    widget.focusNode.onKeyEvent = _onKey;
  }

  @override
  void didUpdateWidget(covariant Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
      _onText();
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.onKeyEvent = null;
      widget.focusNode.onKeyEvent = _onKey;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    widget.focusNode.onKeyEvent = null;
    super.dispose();
  }

  void _onText() {
    final has = widget.controller.text.trim().isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!Composer.enterSends || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isShiftPressed) return KeyEventResult.ignored;
    // Don't send while an IME is composing (e.g. CJK input).
    final composing = widget.controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (_hasText) widget.onSend();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(24),
      borderSide: BorderSide.none,
    );

    return Material(
      color: p.surface,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: p.divider)),
          ),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.header != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: widget.header,
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (widget.onAttach != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: SizedBox(
                        width: 46,
                        height: 46,
                        child: widget.uploading
                            ? Padding(
                                padding: const EdgeInsets.all(13),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: p.accent,
                                ),
                              )
                            : IconButton(
                                key: const ValueKey('composer-attach'),
                                tooltip: 'Attach a file',
                                icon: Icon(
                                  LucideIcons.paperclip,
                                  color: p.textMuted,
                                ),
                                onPressed: widget.enabled
                                    ? widget.onAttach
                                    : null,
                              ),
                      ),
                    ),
                  Expanded(
                    child: TextField(
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      enabled: widget.enabled,
                      minLines: 1,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      textCapitalization: TextCapitalization.sentences,
                      onChanged: widget.onChanged,
                      style: t.bodyLarge?.copyWith(
                        fontSize: 15.5,
                        height: 1.35,
                      ),
                      cursorColor: p.accent,
                      decoration: InputDecoration(
                        hintText: widget.hint,
                        filled: true,
                        fillColor: p.inputFill,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                        border: border,
                        enabledBorder: border,
                        focusedBorder: border,
                        disabledBorder: border,
                      ),
                    ),
                  ),
                  AnimatedSize(
                    duration: AppMotion.medium,
                    curve: AppMotion.curve,
                    alignment: Alignment.centerLeft,
                    child: _hasText
                        ? Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: _SendButton(
                              onPressed: widget.enabled ? widget.onSend : null,
                            ),
                          )
                        : const SizedBox(height: 46),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatefulWidget {
  const _SendButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: AppMotion.medium,
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ScaleTransition(
      scale: CurvedAnimation(parent: _c, curve: Curves.easeOutBack),
      child: Tooltip(
        message: Composer.enterSends ? 'Send (Enter)' : 'Send',
        child: Material(
          color: p.accent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: widget.onPressed,
            child: SizedBox(
              width: 46,
              height: 46,
              child: Icon(
                LucideIcons.sendHorizontal,
                size: 20,
                color: p.onAccent,
                semanticLabel: 'Send',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
