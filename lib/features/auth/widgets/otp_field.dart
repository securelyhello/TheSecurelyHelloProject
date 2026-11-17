import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/shared/widgets/app_text_field.dart';

/// Authenticator (or recovery) code, shown once the server asks for it.
class OtpField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String>? onSubmitted;
  const OtpField({super.key, required this.controller, this.onSubmitted});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 20),
        child: AppTextField(
          key: const ValueKey('otp-field'),
          controller: controller,
          label: 'Authenticator code',
          hint: '6 digits, or a recovery code',
          prefixIcon: const Icon(LucideIcons.smartphone),
          keyboardType: TextInputType.visiblePassword,
          onSubmitted: onSubmitted,
        ),
      );
}
