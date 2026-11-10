import 'package:flutter/material.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';

/// A themed text field with an animated focus border and error text.
///
/// Inherits the global [InputDecorationTheme] and reads colours from the
/// active [AppPalette], so it works in both light and dark themes.
class AppTextField extends StatefulWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.prefixIcon,
    this.suffixIcon,
    this.obscureText = false,
    this.validator,
    this.onChanged,
    this.keyboardType,
    this.textInputAction,
    this.enabled = true,
    this.errorText,
    this.maxLines = 1,
    this.autofocus = false,
    this.focusNode,
    this.onSubmitted,
    this.textCapitalization = TextCapitalization.none,
    this.autofillHints,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final bool obscureText;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool enabled;
  final String? errorText;
  final int maxLines;
  final bool autofocus;
  final FocusNode? focusNode;
  final ValueChanged<String>? onSubmitted;
  final TextCapitalization textCapitalization;
  final Iterable<String>? autofillHints;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField>
    with SingleTickerProviderStateMixin {
  late final AnimationController _focusAnim = AnimationController(
    vsync: this,
    duration: AppMotion.medium,
  );
  late final FocusNode _focusNode = widget.focusNode ?? FocusNode();
  late final bool _ownsNode = widget.focusNode == null;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus) {
      _focusAnim.forward();
    } else {
      _focusAnim.reverse();
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    if (_ownsNode) _focusNode.dispose();
    _focusAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;

    OutlineInputBorder border(Color c, double w) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      borderSide: BorderSide(color: c, width: w),
    );

    return AnimatedBuilder(
      animation: _focusAnim,
      builder: (context, _) {
        final focusColor = hasError
            ? p.danger
            : Color.lerp(
                p.border,
                p.accent,
                Curves.easeOut.transform(_focusAnim.value),
              )!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: widget.controller,
              focusNode: _focusNode,
              obscureText: widget.obscureText,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              keyboardType: widget.keyboardType,
              textInputAction: widget.textInputAction,
              textCapitalization: widget.textCapitalization,
              autofillHints: widget.autofillHints,
              enabled: widget.enabled,
              maxLines: widget.maxLines,
              autofocus: widget.autofocus,
              style: t.bodyLarge?.copyWith(
                fontSize: 15,
                color: widget.enabled ? p.textPrimary : p.textMuted,
              ),
              cursorColor: p.accent,
              decoration: InputDecoration(
                labelText: widget.label,
                hintText: widget.hint,
                prefixIcon: widget.prefixIcon,
                suffixIcon: widget.suffixIcon,
                enabledBorder: border(hasError ? p.danger : p.border, 1),
                focusedBorder: border(focusColor, 1.5),
                errorBorder: border(p.danger, 1),
                focusedErrorBorder: border(p.danger, 1.5),
              ),
            ),
            if (hasError)
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 6),
                child: Text(
                  widget.errorText!,
                  style: t.bodySmall?.copyWith(color: p.danger),
                ),
              ),
          ],
        );
      },
    );
  }
}
