import 'dart:async';

import 'package:flutter/material.dart';
import 'package:securelyhello/shared/theme/app_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/features/auth/widgets/otp_field.dart';
import 'package:securelyhello/features/auth/screens/verify_email_screen.dart' show AuthBanner;
import 'package:securelyhello/shared/widgets/app_text_field.dart';

/// Shown on a newly signed-in device until one of the account's other
/// devices approves it (or the account is recovered by e-mail).
class DevicePendingScreen extends StatefulWidget {
  const DevicePendingScreen({super.key});

  @override
  State<DevicePendingScreen> createState() => _DevicePendingScreenState();
}

class _DevicePendingScreenState extends State<DevicePendingScreen> {
  bool _recovering = false;
  bool _codeSent = false;
  final _code = TextEditingController();
  final _otp = TextEditingController();
  late final AuthProvider _auth;

  @override
  void initState() {
    super.initState();
    _auth = context.read<AuthProvider>();
    _auth.addListener(_onAuth);
    unawaited(_auth.watchApproval());
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuth);
    _code.dispose();
    _otp.dispose();
    super.dispose();
  }

  void _onAuth() {
    if (!mounted) return;
    if (_auth.deviceApproved) {
      _auth.removeListener(_onAuth);
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);
    } else if (_auth.status == AuthStatus.unauthenticated) {
      _auth.removeListener(_onAuth);
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
    }
  }

  Future<void> _sendCode() async {
    if (await _auth.requestDeviceRecovery() && mounted) setState(() => _codeSent = true);
  }

  Future<void> _confirm() async {
    final code = _code.text.trim();
    if (code.length != 6) return;
    await _auth.confirmDeviceRecovery(code, otp: _otp.text);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final muted = context.palette.textSecondary;
    return Scaffold(
      backgroundColor: context.palette.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: () async {
              await _auth.signOut();
            },
            child: const Text('Log out'),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              children: [
                Icon(LucideIcons.monitorSmartphone, size: 44, color: context.palette.accent),
                const SizedBox(height: 20),
                Text(
                  _recovering ? 'Recover your account' : 'Approve this device',
                  textAlign: TextAlign.center,
                  style: AppFonts.heading(
                      fontSize: 26, fontWeight: FontWeight.bold, color: context.palette.textPrimary),
                ),
                const SizedBox(height: 12),
                Text(
                  _recovering
                      ? 'Use this only if you no longer have any of your other devices. '
                          'Recovering signs them all out, and your contacts will see that your '
                          'safety number changed.'
                      : 'Open Securely Hello on a device you already use. It will ask you to '
                          'approve this one. Check that it shows the same code as below.',
                  textAlign: TextAlign.center,
                  style: AppFonts.body(fontSize: 15, color: muted, height: 1.45),
                ),
                const SizedBox(height: 28),
                if (!_recovering) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(
                      color: context.palette.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: context.palette.border),
                    ),
                    child: Column(children: [
                      Text('This device', style: AppFonts.body(color: muted, fontSize: 13)),
                      const SizedBox(height: 8),
                      SelectableText(
                        auth.deviceFingerprint,
                        key: const ValueKey('pending-fingerprint'),
                        style: AppFonts.mono(
                            fontSize: 22, color: context.palette.textPrimary, letterSpacing: 1.5),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 24),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 10),
                    Text('Waiting for approval…', style: TextStyle(color: muted)),
                  ]),
                  const SizedBox(height: 32),
                  TextButton(
                    key: const ValueKey('pending-recover'),
                    onPressed: () => setState(() => _recovering = true),
                    child: const Text('I lost my other devices'),
                  ),
                ] else ...[
                  if (!_codeSent)
                    ElevatedButton(
                      onPressed: auth.isLoading ? null : _sendCode,
                      child: const Text('E-mail me a recovery code'),
                    )
                  else ...[
                    AppTextField(
                      controller: _code,
                      label: 'Code from the e-mail',
                      hint: '123456',
                      prefixIcon: const Icon(LucideIcons.keyRound),
                      keyboardType: TextInputType.number,
                      onSubmitted: (_) => _confirm(),
                    ),
                    if (auth.otpRequired) OtpField(controller: _otp, onSubmitted: (_) => _confirm()),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: auth.isLoading ? null : _confirm,
                      child: const Text('Recover and sign out other devices'),
                    ),
                  ],
                  if (auth.errorMessage != null) ...[
                    const SizedBox(height: 16),
                    AuthBanner(text: auth.errorMessage!, error: true),
                  ],
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => setState(() => _recovering = false),
                    child: const Text('Back'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
