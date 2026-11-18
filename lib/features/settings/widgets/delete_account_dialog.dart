import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';

/// Why a deletion attempt failed: the server's error [code] (null for
/// network and other errors) and a [message] to show.
class DeleteAccountFailure {
  final String? code;
  final String message;
  const DeleteAccountFailure(this.code, this.message);
}

/// Deletes the account with the given password and code; null on success.
typedef DeleteAccountAttempt = Future<DeleteAccountFailure?> Function(
    String currentPassword, String? otp);

/// Confirms account deletion: type DELETE, the password again and, with
/// two-step verification on, an authenticator (or recovery) code. Runs
/// [onDelete] itself so a wrong password or code is shown inline; pops
/// `true` once the account is gone, `false` on cancel.
class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({
    super.key,
    required this.twoFactorEnabled,
    required this.onDelete,
  });

  /// Whether to ask for a code up front. If it can't be loaded the field
  /// still appears once the server answers `otp_required`.
  final Future<bool> twoFactorEnabled;
  final DeleteAccountAttempt onDelete;

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  static final _totp = RegExp(r'^\d{6}$');
  static final _recovery = RegExp(r'^[a-z2-7]{5}-[a-z2-7]{5}$', caseSensitive: false);

  final _confirm = TextEditingController();
  final _password = TextEditingController();
  final _otp = TextEditingController();

  bool _needsCode = false;
  bool _busy = false;
  String? _passwordError;
  String? _otpError;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.twoFactorEnabled.then((on) {
      if (on && mounted) setState(() => _needsCode = true);
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    _confirm.dispose();
    _password.dispose();
    _otp.dispose();
    super.dispose();
  }

  String get _code => _otp.text.replaceAll(' ', '').trim();

  bool get _ready =>
      !_busy &&
      _confirm.text.trim() == 'DELETE' &&
      _password.text.isNotEmpty &&
      (!_needsCode || _totp.hasMatch(_code) || _recovery.hasMatch(_code));

  Future<void> _submit() async {
    if (!_ready) return;
    setState(() {
      _busy = true;
      _passwordError = null;
      _otpError = null;
      _error = null;
    });
    final failure = await widget.onDelete(_password.text, _needsCode ? _code : null);
    if (!mounted) return;
    if (failure == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _busy = false;
      switch (failure.code) {
        case 'invalid_credentials':
          _passwordError = 'Wrong password';
        case 'otp_required':
          _needsCode = true;
          _otpError = 'Enter the code from your authenticator app';
        case 'invalid_otp':
          _needsCode = true;
          _otpError = 'That code is wrong or was already used';
        default:
          _error = failure.message;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AlertDialog(
      icon: Icon(LucideIcons.triangleAlert, color: p.danger, size: 30),
      title: const Text('Delete account?'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This is permanent. Your profile, contacts, encryption keys and '
                'all messages on this device will be deleted.',
              ),
              const SizedBox(height: 16),
              Text(
                'Type DELETE to confirm',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: p.textPrimary),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('delete-confirm'),
                controller: _confirm,
                autofocus: true,
                enabled: !_busy,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: 'DELETE'),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('delete-password'),
                controller: _password,
                obscureText: true,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                autofillHints: const [AutofillHints.password],
                onChanged: (_) => setState(() => _passwordError = null),
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(labelText: 'Password', errorText: _passwordError),
              ),
              if (_needsCode) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('delete-otp'),
                  controller: _otp,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  keyboardType: TextInputType.visiblePassword,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  onChanged: (_) => setState(() => _otpError = null),
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: 'Authenticator code',
                    hintText: '6 digits, or a recovery code',
                    errorText: _otpError,
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: p.danger)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('delete-submit'),
          style: FilledButton.styleFrom(
            backgroundColor: p.danger,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: _ready ? _submit : null,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Delete account'),
        ),
      ],
    );
  }
}
