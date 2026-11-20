import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/core/update/app_updater.dart';
import 'package:securelyhello/core/update/update_manifest.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';

/// Covers the app with a "please update" screen while this build is below
/// the minimum (from latest.json or the server). Everything else passes
/// through.
class UpdateGate extends StatelessWidget {
  const UpdateGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final u = context.watch<AppUpdater?>();
    if (u == null || u.urgency != UpdateUrgency.required) return child;
    return Stack(
      children: [
        ExcludeSemantics(child: IgnorePointer(child: child)),
        const Positioned.fill(child: _BlockingUpdate()),
      ],
    );
  }
}

class _BlockingUpdate extends StatelessWidget {
  const _BlockingUpdate();

  @override
  Widget build(BuildContext context) {
    final u = context.watch<AppUpdater>();
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final m = u.manifest;
    return Material(
      key: const ValueKey('update-blocking'),
      color: p.background,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(color: p.accentContainer, shape: BoxShape.circle),
                    child: Icon(LucideIcons.download, size: 38, color: p.onAccentContainer),
                  ),
                  const SizedBox(height: 22),
                  Text('Please update Securely Hello',
                      textAlign: TextAlign.center, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 10),
                  Text(
                    'This version is no longer supported. Update to keep your chats working; '
                    'your messages and keys stay on this device.',
                    textAlign: TextAlign.center,
                    style: t.bodyMedium?.copyWith(color: p.textSecondary),
                  ),
                  if (m != null && m.notes.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text("What's new in ${m.versionName}", style: t.titleSmall),
                    const SizedBox(height: 6),
                    Text(m.notes, textAlign: TextAlign.center, style: t.bodySmall?.copyWith(color: p.textSecondary)),
                  ],
                  const SizedBox(height: 24),
                  UpdateActions(updater: u, blocking: true),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Update available" at the top of the chat list. "Later" hides it until
/// a newer version comes out.
class UpdateCardSliver extends StatefulWidget {
  const UpdateCardSliver({super.key});

  @override
  State<UpdateCardSliver> createState() => _UpdateCardSliverState();
}

class _UpdateCardSliverState extends State<UpdateCardSliver> {
  static const _dismissedKey = 'update_dismissed_version';
  int? _dismissed;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _dismissed = prefs.getInt(_dismissedKey);
        _loaded = true;
      });
    });
  }

  Future<void> _later(int version) async {
    setState(() => _dismissed = version);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_dismissedKey, version);
  }

  @override
  Widget build(BuildContext context) {
    final u = context.watch<AppUpdater?>();
    final m = u?.manifest;
    if (u != null && u.urgency == UpdateUrgency.unsupported) return _unsupported(context, u);
    if (!_loaded || u == null || m == null || u.urgency != UpdateUrgency.available || _dismissed == m.versionCode) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Container(
          key: const ValueKey('update-card'),
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
          decoration: BoxDecoration(
            color: p.accentContainer.withAlpha(110),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: p.accent.withAlpha(70)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.sparkles, size: 18, color: p.accent),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Update available', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
                  Text('Version ${m.versionName}', style: t.labelSmall?.copyWith(color: p.textSecondary)),
                ],
              ),
              if (m.notes.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(m.notes, maxLines: 4, overflow: TextOverflow.ellipsis, style: t.bodySmall),
              ],
              const SizedBox(height: 8),
              UpdateActions(updater: u, onLater: () => _later(m.versionCode)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Below the minimum with no build published that meets it (security
/// review M4): a warning above the chats, not a block. Offers whatever
/// update there is.
Widget _unsupported(BuildContext context, AppUpdater u) {
  final p = context.palette;
  final t = Theme.of(context).textTheme;
  final m = u.manifest;
  final installed = u.installedVersionCode;
  final canUpdate = m != null && installed != null && m.versionCode > installed;
  return SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        key: const ValueKey('update-unsupported'),
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
        decoration: BoxDecoration(
          color: p.accentContainer.withAlpha(110),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: p.accent.withAlpha(70)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.triangleAlert, size: 18, color: p.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('This version is no longer supported',
                      style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Some things may stop working. Get the latest Securely Hello from securelyhello.thenn.in.',
              style: t.bodySmall,
            ),
            if (canUpdate) ...[
              const SizedBox(height: 8),
              UpdateActions(updater: u),
            ],
          ],
        ),
      ),
    ),
  );
}

/// Update button with download progress and what went wrong.
class UpdateActions extends StatelessWidget {
  const UpdateActions({super.key, required this.updater, this.onLater, this.blocking = false});

  final AppUpdater updater;
  final VoidCallback? onLater;
  final bool blocking;

  static String message(UpdateError e) => switch (e) {
        UpdateError.network => "The download didn't finish. Check your connection and try again.",
        UpdateError.hashMismatch => "The download was damaged or changed on the way, so it wasn't installed.",
        UpdateError.certificateMismatch =>
          "That file isn't signed by Securely Hello, so it wasn't installed. Download the app from "
              'securelyhello.thenn.in.',
        UpdateError.wrongPackage => "That file isn't a newer Securely Hello, so it wasn't installed.",
        UpdateError.needsPermission =>
          'Allow Securely Hello to install updates in the settings that just opened, then tap Update again.',
        UpdateError.installFailed => "Android didn't install the update. Try again.",
      };

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final err = updater.error;
    return Column(
      crossAxisAlignment: blocking ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
      children: [
        if (updater.busy) ...[
          LinearProgressIndicator(value: updater.progress > 0 ? updater.progress : null),
          const SizedBox(height: 6),
          Text(
            updater.progress >= 1 ? 'Checking…' : 'Downloading… ${(updater.progress * 100).round()}%',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: p.textSecondary),
          ),
        ] else
          Wrap(
            alignment: blocking ? WrapAlignment.center : WrapAlignment.start,
            spacing: 8,
            children: [
              FilledButton.icon(
                key: const ValueKey('update-now'),
                onPressed: updater.downloadAndInstall,
                icon: const Icon(LucideIcons.download, size: 18),
                label: const Text('Update'),
              ),
              if (onLater != null) TextButton(onPressed: onLater, child: const Text('Later')),
            ],
          ),
        if (err != null) ...[
          const SizedBox(height: 8),
          Text(message(err),
              textAlign: blocking ? TextAlign.center : TextAlign.start,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.danger)),
        ],
      ],
    );
  }
}
