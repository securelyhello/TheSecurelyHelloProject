import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/features/auth/screens/verify_email_screen.dart';
import 'package:securelyhello/shared/widgets/app_text_field.dart';

/// Password reset in two steps: e-mail address → code + new password.
///
/// Resetting the password does not touch encryption keys: on a device that
/// was signed in before, chats continue; on a new device it works like any
/// new sign-in.
class ForgotPasswordScreen extends StatefulWidget {
  /// Pre-fills the address typed on the login screen.
  final String? initialEmail;
  const ForgotPasswordScreen({super.key, this.initialEmail});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final _emailController =
      TextEditingController(text: widget.initialEmail ?? '');
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _emailForm = GlobalKey<FormState>();
  final _resetForm = GlobalKey<FormState>();
  bool _codeSent = false;
  bool _obscure = true;
  bool? _available;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final auth = context.read<AuthProvider>()..clearError();
      final available = await auth.emailAvailable();
      if (mounted) setState(() => _available = available);
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    if (_emailForm.currentState?.validate() == false) return;
    final ok = await context
        .read<AuthProvider>()
        .requestPasswordReset(_emailController.text);
    if (ok && mounted) setState(() => _codeSent = true);
  }

  Future<void> _reset() async {
    if (!_resetForm.currentState!.validate()) return;
    final auth = context.read<AuthProvider>();
    final ok = await auth.resetPassword(
      email: _emailController.text,
      code: _codeController.text,
      newPassword: _passwordController.text,
    );
    if (ok && mounted) {
      Navigator.of(context)
          .pushNamedAndRemoveUntil(auth.homeRoute, (_) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft, color: Colors.white),
          onPressed: () => _codeSent
              ? setState(() => _codeSent = false)
              : Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _codeSent ? 'Choose a new password' : 'Reset your password',
                    style: GoogleFonts.manrope(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _codeSent
                        ? 'If ${_emailController.text.trim()} has an account, a 6-digit code is on its way. It expires in 15 minutes.'
                        : "We'll e-mail you a code. Your chats and keys on this device are not affected.",
                    style: GoogleFonts.inter(
                        fontSize: 15, color: const Color(0xFFB8B8CC), height: 1.4),
                  ),
                  const SizedBox(height: 32),
                  if (_available == false)
                    const AuthBanner(
                      text:
                          "This server can't send e-mail, so passwords can't be reset. Ask its operator to configure SMTP.",
                      error: true,
                    )
                  else if (!_codeSent)
                    _emailStep(auth)
                  else
                    _resetStep(auth),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _emailStep(AuthProvider auth) => Form(
        key: _emailForm,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppTextField(
              key: const ValueKey('reset-email'),
              controller: _emailController,
              label: 'Email',
              hint: 'Enter your email',
              prefixIcon: const Icon(LucideIcons.mail),
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              validator: (v) => v == null || !v.contains('@')
                  ? 'Valid email required'
                  : null,
              onSubmitted: (_) => _sendCode(),
            ),
            if (auth.errorMessage != null) ...[
              const SizedBox(height: 16),
              AuthBanner(text: auth.errorMessage!, error: true),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              key: const ValueKey('reset-send'),
              onPressed: auth.isLoading || _available == null ? null : _sendCode,
              child: auth.isLoading
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Send code'),
            ),
          ],
        ),
      );

  Widget _resetStep(AuthProvider auth) => Form(
        key: _resetForm,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppTextField(
              key: const ValueKey('reset-code'),
              controller: _codeController,
              label: 'Code from the e-mail',
              hint: '123456',
              prefixIcon: const Icon(LucideIcons.keyRound),
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              validator: (v) => RegExp(r'^\d{6}$').hasMatch(v?.trim() ?? '')
                  ? null
                  : 'Enter the 6-digit code',
            ),
            const SizedBox(height: 20),
            AppTextField(
              key: const ValueKey('reset-password'),
              controller: _passwordController,
              label: 'New password',
              hint: 'At least 8 characters',
              prefixIcon: const Icon(LucideIcons.lock),
              obscureText: _obscure,
              autofillHints: const [AutofillHints.newPassword],
              suffixIcon: IconButton(
                icon: Icon(_obscure ? LucideIcons.eye : LucideIcons.eyeOff,
                    color: const Color(0xFF6B6B80)),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
              validator: (v) => (v?.length ?? 0) < 8
                  ? 'Use at least 8 characters'
                  : null,
            ),
            const SizedBox(height: 20),
            AppTextField(
              key: const ValueKey('reset-confirm'),
              controller: _confirmController,
              label: 'Confirm new password',
              prefixIcon: const Icon(LucideIcons.lock),
              obscureText: _obscure,
              validator: (v) => v != _passwordController.text
                  ? "Passwords don't match"
                  : null,
              onSubmitted: (_) => _reset(),
            ),
            if (auth.errorMessage != null) ...[
              const SizedBox(height: 16),
              AuthBanner(text: auth.errorMessage!, error: true),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              key: const ValueKey('reset-submit'),
              onPressed: auth.isLoading ? null : _reset,
              child: auth.isLoading
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Set password and log in'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: auth.isLoading ? null : _sendCode,
              child: const Text('Send a new code'),
            ),
          ],
        ),
      );
}
