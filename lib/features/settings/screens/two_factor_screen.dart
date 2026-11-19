import 'package:flutter/material.dart';
import 'package:securelyhello/shared/theme/app_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/core/security/sensitive_clipboard.dart';

/// Turns two-step verification on or off and manages recovery codes.
class TwoFactorScreen extends StatefulWidget {
  const TwoFactorScreen({super.key});

  @override
  State<TwoFactorScreen> createState() => _TwoFactorScreenState();
}

class _TwoFactorScreenState extends State<TwoFactorScreen> {
  late Future<Map<String, dynamic>> _status = _load();
  Map<String, dynamic>? _setup;
  List<String>? _recovery;
  final _code = TextEditingController();
  bool _busy = false;

  AuthProvider get _auth => context.read<AuthProvider>();
  Future<Map<String, dynamic>> _load() => context.read<AuthProvider>().twoFactorStatus();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<T?> _run<T>(Future<T> Function() f) async {
    setState(() => _busy = true);
    try {
      return await f();
    } catch (e) {
      if (mounted) showAppSnackBar(context, e.toString(), error: true);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start() async {
    final pw = await _askText('Confirm your password', 'Password', obscure: true);
    if (pw == null) return;
    final setup = await _run(() => _auth.twoFactorSetup(pw));
    if (setup != null) setState(() => _setup = setup);
  }

  Future<void> _confirm() async {
    final codes = await _run(() => _auth.twoFactorEnable(_code.text));
    if (codes == null) return;
    _code.clear();
    setState(() {
      _setup = null;
      _recovery = codes;
      _status = _load();
    });
  }

  Future<void> _turnOff() async {
    final pw = await _askText('Turn off two-step verification', 'Password', obscure: true);
    if (pw == null || !mounted) return;
    final code = await _askText('Turn off two-step verification', 'Authenticator or recovery code');
    if (code == null) return;
    final ok = await _run(() async {
      await _auth.twoFactorDisable(pw, code);
      return true;
    });
    if (ok == true) setState(() => _status = _load());
  }

  Future<void> _newCodes() async {
    final pw = await _askText('New recovery codes', 'Password', obscure: true);
    if (pw == null) return;
    final codes = await _run(() => _auth.twoFactorNewRecoveryCodes(pw));
    if (codes != null) {
      setState(() {
        _recovery = codes;
        _status = _load();
      });
    }
  }

  Future<String?> _askText(String title, String label, {bool obscure = false}) async {
    final c = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          obscureText: obscure,
          enableIMEPersonalizedLearning: false,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Continue')),
        ],
      ),
    );
    c.dispose();
    return (v == null || v.isEmpty) ? null : v;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(title: const Text('Two-step verification')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _status,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text("Couldn't load this setting. ${snap.error}"));
          }
          final on = snap.data!['enabled'] == true;
          final left = snap.data!['recovery_codes_left'] as int? ?? 0;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Text(
                'With two-step verification, signing in, resetting your password or '
                'recovering your account also needs a code from an authenticator app '
                '(such as Aegis, 2FAS or Google Authenticator). Someone who gets into '
                'your e-mail still can\'t get into Securely Hello.',
                style: t.bodyMedium?.copyWith(height: 1.45),
              ),
              const SizedBox(height: 20),
              if (_recovery != null)
                _RecoveryCodes(codes: _recovery!, onDone: () => setState(() => _recovery = null))
              else if (_setup != null)
                ..._setupStep(t, p)
              else if (on) ...[
                ListTile(
                  key: const ValueKey('2fa-on'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(LucideIcons.shieldCheck, color: p.accent),
                  title: const Text('On'),
                  subtitle: Text('$left recovery code${left == 1 ? '' : 's'} left'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _newCodes,
                  icon: const Icon(LucideIcons.listRestart),
                  label: const Text('New recovery codes'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _busy ? null : _turnOff,
                  style: TextButton.styleFrom(foregroundColor: p.danger),
                  child: const Text('Turn off'),
                ),
              ] else
                ElevatedButton.icon(
                  key: const ValueKey('2fa-start'),
                  onPressed: _busy ? null : _start,
                  icon: const Icon(LucideIcons.shieldPlus),
                  label: const Text('Turn on'),
                ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _setupStep(TextTheme t, AppPalette p) {
    final uri = _setup!['uri'] as String;
    final secret = _setup!['secret'] as String;
    final grouped = [
      for (var i = 0; i < secret.length; i += 4) secret.substring(i, (i + 4).clamp(0, secret.length))
    ].join(' ');
    return [
      Text('1. Scan this with your authenticator app', style: t.titleSmall),
      const SizedBox(height: 12),
      Center(
        child: Container(
          color: Colors.white,
          padding: const EdgeInsets.all(12),
          child: QrImageView(data: uri, size: 200, backgroundColor: Colors.white),
        ),
      ),
      const SizedBox(height: 12),
      Text('Or type this key:', style: t.bodySmall),
      Row(children: [
        Expanded(
          child: SelectableText(grouped,
              key: const ValueKey('2fa-secret'),
              style: AppFonts.mono(fontSize: 15, color: p.textPrimary)),
        ),
        IconButton(
          tooltip: 'Copy',
          icon: const Icon(LucideIcons.copy, size: 18),
          onPressed: () => SensitiveClipboard.copy(secret),
        ),
      ]),
      const SizedBox(height: 20),
      Text('2. Enter the 6-digit code it shows', style: t.titleSmall),
      const SizedBox(height: 8),
      TextField(
        key: const ValueKey('2fa-code'),
        controller: _code,
        keyboardType: TextInputType.number,
        maxLength: 6,
        enableIMEPersonalizedLearning: false,
        decoration: const InputDecoration(hintText: '123456'),
        onSubmitted: (_) => _confirm(),
      ),
      const SizedBox(height: 8),
      ElevatedButton(
        key: const ValueKey('2fa-confirm'),
        onPressed: _busy ? null : _confirm,
        child: const Text('Turn on'),
      ),
      TextButton(onPressed: () => setState(() => _setup = null), child: const Text('Cancel')),
    ];
  }
}

class _RecoveryCodes extends StatelessWidget {
  final List<String> codes;
  final VoidCallback onDone;
  const _RecoveryCodes({required this.codes, required this.onDone});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final p = context.palette;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Save your recovery codes', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text(
        "If you lose your phone, each code works once instead of the authenticator. "
        "They won't be shown again. Keep them somewhere safe, like a password manager.",
        style: t.bodyMedium?.copyWith(height: 1.45),
      ),
      const SizedBox(height: 16),
      Container(
        key: const ValueKey('2fa-recovery-codes'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: p.divider),
        ),
        child: Wrap(spacing: 24, runSpacing: 10, children: [
          for (final c in codes)
            Text(c, style: AppFonts.mono(fontSize: 16, color: p.textPrimary)),
        ]),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: () {
          SensitiveClipboard.copy(codes.join('\n'));
          showAppSnackBar(context, 'Recovery codes copied');
        },
        icon: const Icon(LucideIcons.copy),
        label: const Text('Copy all'),
      ),
      const SizedBox(height: 8),
      ElevatedButton(onPressed: onDone, child: const Text("I've saved them")),
    ]);
  }
}
