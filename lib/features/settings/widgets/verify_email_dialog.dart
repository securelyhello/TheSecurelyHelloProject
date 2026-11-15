import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/shared/widgets/app_text_field.dart';

/// Seconds before another verification code can be requested.
const verifyResendCooldownSeconds = 60;

final _codePattern = RegExp(r'^\d{6}$');

/// "Verify your email" reminder. Renders nothing once the address is
/// verified. Verification is optional; nothing else is blocked on it.
class VerifyEmailBanner extends StatelessWidget {
  const VerifyEmailBanner({super.key, this.padding});

  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    if (!auth.isAuthenticated || auth.emailVerified) {
      return const SizedBox.shrink();
    }
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final email = auth.email;
    return Padding(
      padding: padding ?? EdgeInsets.zero,
      child: Material(
        color: p.warning.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: BorderSide(color: p.warning.withValues(alpha: 0.35)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Icon(LucideIcons.mailWarning, color: p.warning, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Verify your email',
                      style: t.titleSmall?.copyWith(
                        color: p.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      email == null || email.isEmpty
                          ? 'Confirm your address so you can always reset '
                                'your password.'
                          : 'Confirm $email so you can always reset your '
                                'password.',
                      style: t.bodySmall?.copyWith(color: p.textSecondary),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => showVerifyEmailDialog(context),
                child: const Text('Verify'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sends a code to the account address and confirms it. Resolves to `true`
/// when the address ends up verified (a success snackbar is shown).
Future<bool> showVerifyEmailDialog(BuildContext context) async {
  final verified = await showDialog<bool>(
    context: context,
    builder: (_) => const _VerifyEmailDialog(),
  );
  if (verified == true && context.mounted) {
    showAppSnackBar(context, 'Email verified', success: true);
  }
  return verified == true;
}

class _VerifyEmailDialog extends StatefulWidget {
  const _VerifyEmailDialog();

  @override
  State<_VerifyEmailDialog> createState() => _VerifyEmailDialogState();
}

class _VerifyEmailDialogState extends State<_VerifyEmailDialog> {
  final _codeController = TextEditingController();
  bool _sent = false;
  bool _busy = false;
  String? _codeError;
  String? _error;
  int _cooldown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _cooldown = verifyResendCooldownSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = context.read<AuthProvider>();
    final ok = await auth.requestEmailVerification();
    if (!mounted) return;
    if (ok && auth.emailVerified) {
      // The server says it was already verified.
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      if (ok) {
        _sent = true;
      } else {
        _error = auth.errorMessage ?? 'Could not send the code';
      }
    });
    if (ok) _startCooldown();
  }

  Future<void> _verify() async {
    final code = _codeController.text.trim();
    if (!_codePattern.hasMatch(code)) {
      setState(() => _codeError = 'Enter the 6-digit code');
      return;
    }
    setState(() {
      _codeError = null;
      _error = null;
      _busy = true;
    });
    final auth = context.read<AuthProvider>();
    final ok = await auth.verifyEmail(code);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = auth.errorMessage ?? 'Could not verify the email';
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final email = context.read<AuthProvider>().email ?? 'your email';

    return AlertDialog(
      icon: Icon(LucideIcons.mailCheck, color: p.accent, size: 30),
      title: const Text('Verify email'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _sent
                    ? 'Enter the code we sent to $email. It expires in 30 '
                          'minutes.'
                    : 'We\'ll send a 6-digit code to $email.',
              ),
              if (_sent) ...[
                const SizedBox(height: 16),
                AppTextField(
                  controller: _codeController,
                  label: '6-digit code',
                  hint: '123456',
                  prefixIcon: const Icon(LucideIcons.hash),
                  keyboardType: TextInputType.number,
                  autofocus: true,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  errorText: _codeError,
                  enabled: !_busy,
                  onSubmitted: (_) => _verify(),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: (_busy || _cooldown > 0) ? null : _send,
                    child: Text(
                      _cooldown > 0
                          ? 'Resend code (${_cooldown}s)'
                          : 'Resend code',
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: t.bodyMedium?.copyWith(color: p.danger)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          style: TextButton.styleFrom(foregroundColor: p.textSecondary),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : (_sent ? _verify : _send),
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_sent ? 'Verify' : 'Send code'),
        ),
      ],
    );
  }
}
