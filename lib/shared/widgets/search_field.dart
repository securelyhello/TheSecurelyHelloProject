import 'package:flutter/material.dart';

import 'package:securelyhello/core/security/app_lock.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';

/// Inset search box with a leading search icon and a clear button.
class SearchField extends StatefulWidget {
  const SearchField({
    super.key,
    required this.controller,
    this.hint = 'Search',
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.focusNode,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
  }

  @override
  void didUpdateWidget(covariant SearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    super.dispose();
  }

  void _onText() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // Inset: a paper-dark well, no rule until it has focus.
    final well = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.input),
      borderSide: BorderSide.none,
    );
    return TextField(
      controller: widget.controller,
      enableIMEPersonalizedLearning: !incognitoKeyboard(context),
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      textInputAction: TextInputAction.search,
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 15),
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hint,
        filled: true,
        fillColor: p.inputFill,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        prefixIcon: Icon(LucideIcons.search, size: 18, color: p.textMuted),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 44,
          minHeight: 40,
        ),
        suffixIcon: widget.controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: Icon(LucideIcons.x, size: 18, color: p.textMuted),
                onPressed: () {
                  widget.controller.clear();
                  widget.onChanged?.call('');
                },
              ),
        border: well,
        enabledBorder: well,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.input),
          borderSide: BorderSide(color: p.accent, width: 1.5),
        ),
      ),
    );
  }
}

/// Section label for lists and settings: sentence case, Chillax.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.padding});

  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: p.textSecondary,
                ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
