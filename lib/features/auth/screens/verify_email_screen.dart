import 'dart:async';

import 'package:flutter/material.dart';
import 'package:securelyhello/shared/theme/app_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/shared/widgets/app_text_field.dart';

/// Asks for the 6-digit code e-mailed at sign-up.
///
/// When the server requires verification this is a gate (the only way out
/// is verifying or logging out); otherwise it can be skipped and done later
/// from Settings.
class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key});

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  static const _resendCooldown = 30;

  final _codeController = TextEditingController();
  int _cooldown = 0;
  Timer? _timer;
  String? _notice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AuthProvider>().clearError();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _cooldown = _resendCooldown);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  Future<void> _verify() async {
    final code = _codeController.text.trim();
    if (code.length != 6) return;
    final auth = context.read<AuthProvider>();
    final ok = await auth.verifyEmail(code);
    if (ok && mounted) {
      _leave();
    } else if (mounted) {
      _codeController.clear();
    }
  }

  /// Back to wherever we came from (Settings), or on to home after sign-up.
  void _leave() {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
    } else {
      nav.pushReplacementNamed('/home');
    }
  }

  Future<void> _resend() async {
    final auth = context.read<AuthProvider>();
    final ok = await auth.resendVerificationEmail();
    if (!mounted) return;
    if (ok) {
      _startCooldown();
      setState(() => _notice = 'We sent a new code to ${auth.email ?? 'your inbox'}.');
    }
  }

  Future<void> _logOut() async {
    await context.read<AuthProvider>().signOut();
    if (mounted) Navigator.of(context).pushReplacementNamed('/login');
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final required = auth.emailVerificationRequired;

    return Scaffold(
      backgroundColor: context.palette.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        actions: [
          if (required)
            TextButton(onPressed: _logOut, child: const Text('Log out'))
          else
            TextButton(
              key: const ValueKey('verify-later'),
              onPressed: _leave,
              child: const Text('Later'),
            ),
        ],
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
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: context.palette.accent.withValues(alpha: 0.1),
                      ),
                      child: Icon(LucideIcons.mailCheck,
                          size: 44, color: context.palette.accent),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Check your inbox',
                    textAlign: TextAlign.center,
                    style: AppFonts.heading(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: context.palette.textPrimary,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Enter the 6-digit code we sent to\n${auth.email ?? 'your e-mail address'}.',
                    textAlign: TextAlign.center,
                    style: AppFonts.body(
                        fontSize: 15, color: context.palette.textSecondary, height: 1.4),
                  ),
                  if (required) ...[
                    const SizedBox(height: 8),
                    Text(
                      'You need a verified address before you can add contacts.',
                      textAlign: TextAlign.center,
                      style: AppFonts.body(
                          fontSize: 13, color: context.palette.textMuted),
                    ),
                  ],
                  const SizedBox(height: 32),
                  AppTextField(
                    key: const ValueKey('verify-code'),
                    controller: _codeController,
                    label: 'Verification code',
                    hint: '123456',
                    prefixIcon: const Icon(LucideIcons.keyRound),
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    onChanged: (v) {
                      final digits = v.replaceAll(RegExp(r'\D'), '');
                      if (digits != v) {
                        _codeController.value = TextEditingValue(
                          text: digits,
                          selection:
                              TextSelection.collapsed(offset: digits.length),
                        );
                      }
                      if (digits.length == 6) _verify();
                      setState(() {});
                    },
                    onSubmitted: (_) => _verify(),
                  ),
                  if (auth.errorMessage != null) ...[
                    const SizedBox(height: 16),
                    AuthBanner(text: auth.errorMessage!, error: true),
                  ] else if (_notice != null) ...[
                    const SizedBox(height: 16),
                    AuthBanner(text: _notice!, error: false),
                  ],
                  const SizedBox(height: 24),
                  ElevatedButton(
                    key: const ValueKey('verify-submit'),
                    onPressed: auth.isLoading ||
                            _codeController.text.trim().length != 6
                        ? null
                        : _verify,
                    child: auth.isLoading
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Verify'),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _cooldown > 0 ? null : _resend,
                    child: Text(_cooldown > 0
                        ? 'Resend code in ${_cooldown}s'
                        : 'Send a new code'),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Error / notice strip used by the auth screens.
class AuthBanner extends StatelessWidget {
  final String text;
  final bool error;
  const AuthBanner({super.key, required this.text, required this.error});

  @override
  Widget build(BuildContext context) {
    final color = error ? context.palette.danger : context.palette.accent;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(error ? Icons.error_outline : LucideIcons.check,
              color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: AppFonts.body(color: color, fontSize: 14)),
          ),
        ],
      ),
    );
  }
}
