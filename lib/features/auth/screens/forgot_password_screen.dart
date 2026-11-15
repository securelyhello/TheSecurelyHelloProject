import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_text_field.dart';

/// Seconds before another code can be requested.
const resendCooldownSeconds = 60;

final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
final _codePattern = RegExp(r'^\d{6}$');

/// Two-step password reset with an e-mailed 6-digit code.
///
/// Pops with the e-mail address on success so the login screen can prefill
/// it. Keys and chats on this device are untouched by a reset.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.initialEmail});

  final String? initialEmail;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final _emailController = TextEditingController(
    text: widget.initialEmail?.trim() ?? '',
  );
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _repeatController = TextEditingController();

  String? _emailError;
  String? _codeError;
  String? _passwordError;
  String? _repeatError;
  String? _error;

  bool _codeSent = false;
  bool _busy = false;
  bool _obscure = true;
  int _cooldown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _emailController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _repeatController.dispose();
    super.dispose();
  }

  String get _email => _emailController.text.trim();

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _cooldown = resendCooldownSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  Future<void> _sendCode() async {
    final email = _email;
    final emailError = email.isEmpty
        ? 'Enter your email'
        : (_emailPattern.hasMatch(email) ? null : 'Enter a valid email');
    setState(() {
      _emailError = emailError;
      _error = null;
    });
    if (emailError != null) return;

    setState(() => _busy = true);
    final auth = context.read<AuthProvider>();
    final ok = await auth.requestPasswordReset(email);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _codeSent = true;
      } else {
        _error = auth.errorMessage ?? 'Could not send the code';
      }
    });
    if (ok) _startCooldown();
  }

  Future<void> _reset() async {
    final code = _codeController.text.trim();
    final password = _passwordController.text;
    setState(() {
      _codeError = _codePattern.hasMatch(code)
          ? null
          : 'Enter the 6-digit code';
      _passwordError = password.length < 8 ? 'At least 8 characters' : null;
      _repeatError = _repeatController.text != password
          ? 'Passwords do not match'
          : null;
      _error = null;
    });
    if (_codeError != null || _passwordError != null || _repeatError != null) {
      return;
    }

    setState(() => _busy = true);
    final auth = context.read<AuthProvider>();
    final ok = await auth.resetPassword(
      email: _email,
      code: code,
      newPassword: password,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(_email);
      return;
    }
    setState(() {
      _busy = false;
      _error = auth.errorMessage ?? 'Could not reset the password';
    });
  }

  void _changeEmail() {
    _timer?.cancel();
    setState(() {
      _codeSent = false;
      _cooldown = 0;
      _error = null;
      _codeController.clear();
      _passwordController.clear();
      _repeatController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: p.accent.withValues(alpha: 0.1),
                      ),
                      child: Icon(
                        LucideIcons.keyRound,
                        size: 40,
                        color: p.accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  if (!_codeSent) ...[
                    Text(
                      'Enter the email you signed up with. We\'ll send you a '
                      '6-digit code to set a new password.',
                      textAlign: TextAlign.center,
                      style: t.bodyMedium?.copyWith(color: p.textSecondary),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AppTextField(
                      controller: _emailController,
                      label: 'Email',
                      hint: 'you@example.com',
                      prefixIcon: const Icon(LucideIcons.mail),
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.email],
                      errorText: _emailError,
                      enabled: !_busy,
                      onSubmitted: (_) => _sendCode(),
                    ),
                  ] else ...[
                    Text(
                      'If an account exists for this email, we sent a code to '
                      '$_email. It expires in 15 minutes.',
                      textAlign: TextAlign.center,
                      style: t.bodyMedium?.copyWith(color: p.textSecondary),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AppTextField(
                      controller: _codeController,
                      label: '6-digit code',
                      hint: '123456',
                      prefixIcon: const Icon(LucideIcons.hash),
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      errorText: _codeError,
                      enabled: !_busy,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppTextField(
                      controller: _passwordController,
                      label: 'New password',
                      prefixIcon: const Icon(LucideIcons.lock),
                      obscureText: _obscure,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.newPassword],
                      errorText: _passwordError,
                      enabled: !_busy,
                      suffixIcon: IconButton(
                        tooltip: _obscure ? 'Show password' : 'Hide password',
                        icon: Icon(
                          _obscure ? LucideIcons.eye : LucideIcons.eyeOff,
                          color: p.textMuted,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppTextField(
                      controller: _repeatController,
                      label: 'Repeat new password',
                      prefixIcon: const Icon(LucideIcons.lock),
                      obscureText: _obscure,
                      textInputAction: TextInputAction.done,
                      errorText: _repeatError,
                      enabled: !_busy,
                      onSubmitted: (_) => _reset(),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: p.inputFill,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            LucideIcons.shieldCheck,
                            size: 18,
                            color: p.accent,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Your chats and encryption keys stay on this '
                              'device. All your sessions will be signed out.',
                              style: t.bodySmall?.copyWith(
                                color: p.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    _ErrorBox(message: _error!),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  FilledButton(
                    onPressed: _busy ? null : (_codeSent ? _reset : _sendCode),
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_codeSent ? 'Reset password' : 'Send code'),
                  ),
                  if (_codeSent) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: _busy ? null : _changeEmail,
                          child: const Text('Use a different email'),
                        ),
                        TextButton(
                          onPressed: (_busy || _cooldown > 0)
                              ? null
                              : _sendCode,
                          child: Text(
                            _cooldown > 0
                                ? 'Resend code (${_cooldown}s)'
                                : 'Resend code',
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.danger.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: p.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.circleAlert, color: p.danger, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: p.danger),
            ),
          ),
        ],
      ),
    );
  }
}
