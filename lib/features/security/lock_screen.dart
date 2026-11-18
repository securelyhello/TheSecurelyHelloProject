import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/l10n/app_localizations.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/core/security/app_lock.dart';

/// Wraps the whole app: covers it while locked, and while the app is in the
/// background when screen security is on.
class AppLockGate extends StatefulWidget {
  final Widget child;
  const AppLockGate({super.key, required this.child});

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      context.read<AppLockService>().onLifecycle(state);

  @override
  Widget build(BuildContext context) {
    final lock = context.watch<AppLockService>();
    return Stack(
      children: [
        // Same widgets either way (no remount); only the flags change. Hidden
        // means hidden from screen readers and keyboards too.
        ExcludeSemantics(
          excluding: lock.locked || lock.obscured,
          child: ExcludeFocus(
            excluding: lock.locked || lock.obscured,
            child: IgnorePointer(ignoring: lock.locked || lock.obscured, child: widget.child),
          ),
        ),
        // The builder sits above the Navigator, so the PIN field needs its
        // own Overlay.
        if (lock.locked)
          Positioned.fill(
            child: Overlay(initialEntries: [OverlayEntry(builder: (_) => const LockScreen())]),
          )
        else if (lock.obscured)
          const Positioned.fill(child: _PrivacyCover()),
      ],
    );
  }
}

class _PrivacyCover extends StatelessWidget {
  const _PrivacyCover();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.palette.background,
    child: Center(child: Icon(LucideIcons.shieldCheck, size: 56, color: context.palette.accent)),
  );
}

class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _pin = TextEditingController();
  bool _checking = false;
  String? _error;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometrics());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && context.read<AppLockService>().retryIn > Duration.zero) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _tryBiometrics() async {
    final lock = context.read<AppLockService>();
    if (lock.useBiometrics) await lock.unlockWithBiometrics();
  }

  Future<void> _submit() async {
    final lock = context.read<AppLockService>();
    if (_checking || _pin.text.isEmpty || lock.retryIn > Duration.zero) return;
    setState(() => _checking = true);
    final ok = await lock.unlockWithPin(_pin.text);
    if (!mounted) return;
    _pin.clear();
    final left = AppLockService.wipeAfter - lock.failures;
    setState(() {
      _checking = false;
      _error = ok
          ? null
          : lock.wipeOnFailures && left <= 3
          ? L10n.of(context).wrongPinLeft(left)
          : L10n.of(context).wrongPin;
    });
  }

  @override
  Widget build(BuildContext context) {
    final lock = context.watch<AppLockService>();
    final wait = lock.retryIn;
    return Material(
      color: context.palette.background,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.lock, size: 44, color: context.palette.accent),
                  const SizedBox(height: 20),
                  Text(
                    L10n.of(context).lockTitle,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    key: const ValueKey('lock-pin'),
                    controller: _pin,
                    autofocus: !lock.useBiometrics,
                    obscureText: true,
                    enableIMEPersonalizedLearning: false,
                    enableSuggestions: false,
                    autocorrect: false,
                    keyboardType: TextInputType.visiblePassword,
                    textAlign: TextAlign.center,
                    enabled: wait == Duration.zero && !_checking,
                    style: TextStyle(fontSize: 22, letterSpacing: 8, color: context.palette.textPrimary),
                    decoration: InputDecoration(
                      hintText: L10n.of(context).pin,
                      errorText: wait > Duration.zero
                          ? L10n.of(context).waitSeconds(wait.inSeconds + 1)
                          : _error,
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      key: const ValueKey('lock-unlock'),
                      onPressed: wait > Duration.zero || _checking ? null : _submit,
                      child: _checking
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(L10n.of(context).unlock),
                    ),
                  ),
                  if (lock.useBiometrics) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _tryBiometrics,
                      icon: const Icon(LucideIcons.fingerprint),
                      label: Text(L10n.of(context).useBiometrics),
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

/// Asks for a new PIN twice. Returns it, or null if cancelled.
Future<String?> askNewPin(BuildContext context) async {
  final first = TextEditingController();
  final second = TextEditingController();
  String? error;
  final pin = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        void save() {
          if (first.text.length < 4) {
            setState(() => error = 'At least 4 characters');
          } else if (first.text != second.text) {
            setState(() => error = "PINs don't match");
          } else {
            Navigator.pop(ctx, first.text);
          }
        }

        TextField field(TextEditingController c, String label, {bool last = false}) => TextField(
          controller: c,
          obscureText: true,
          autofocus: !last,
          enableIMEPersonalizedLearning: false,
          enableSuggestions: false,
          autocorrect: false,
          keyboardType: TextInputType.visiblePassword,
          decoration: InputDecoration(labelText: label, errorText: last ? error : null),
          onSubmitted: last ? (_) => save() : null,
        );

        return AlertDialog(
          title: const Text('Choose a PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "If you forget it you'll have to reinstall and approve this device again.",
              ),
              const SizedBox(height: 12),
              field(first, 'PIN'),
              field(second, 'Repeat PIN', last: true),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(L10n.of(context).cancel)),
            TextButton(key: const ValueKey('pin-save'), onPressed: save, child: Text(L10n.of(context).save)),
          ],
        );
      },
    ),
  );
  first.dispose();
  second.dispose();
  return pin;
}
