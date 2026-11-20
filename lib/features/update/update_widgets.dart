import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/core/config/app_version.dart';
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
                    decoration: BoxDecoration(color: p.brand, shape: BoxShape.circle),
                    child: Icon(LucideIcons.download, size: 38, color: p.onBrand),
                  ),
                  const SizedBox(height: 22),
                  Text('Please update Securely Hello',
                      textAlign: TextAlign.center, style: t.headlineSmall),
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
            color: p.brand,
            borderRadius: BorderRadius.circular(AppRadius.card),
            boxShadow: p.paperShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.sparkles, size: 18, color: p.onBrand),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Update available', style: t.titleSmall?.copyWith(color: p.onBrand))),
                  Text('Version ${m.versionName}', style: t.labelMedium?.copyWith(color: p.onBrand)),
                ],
              ),
              if (m.notes.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(m.notes,
                    maxLines: 4, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: p.onBrand)),
              ],
              const SizedBox(height: 8),
              UpdateActions(updater: u, onLater: () => _later(m.versionCode), onPear: true),
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
          color: p.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: p.warning),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.triangleAlert, size: 18, color: p.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('This version is no longer supported', style: t.titleSmall),
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

/// Settings > "App updates": this build's version, whether it is up to
/// date, and a button that checks right now. Shows the available update
/// itself (notes, size, progress, errors) whatever the chat-list card's
/// "Later" was set to.
///
/// Where nothing updates the app itself (Google Play builds, desktop) it
/// shows the version and where new ones come from.
class AppUpdatesSection extends StatefulWidget {
  /// [distribution] is `play` for Google Play builds; defaults to this
  /// build's own. [now] is the clock for "checked 5 minutes ago".
  const AppUpdatesSection({super.key, this.distribution = AppUpdater.distribution, this.now = DateTime.now});

  final String distribution;
  final DateTime Function() now;

  /// "90.0 MB" for [bytes]; KB below a tenth of a megabyte.
  @visibleForTesting
  static String formatSize(int bytes) {
    const mb = 1024 * 1024;
    if (bytes < mb ~/ 10) return '${(bytes / 1024).ceil()} KB';
    return '${(bytes / mb).toStringAsFixed(1)} MB';
  }

  /// "just now", "5 minutes ago", "3 hours ago", "yesterday", "4 days ago".
  @visibleForTesting
  static String ago(DateTime then, DateTime now) {
    final d = now.difference(then);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return d.inMinutes == 1 ? '1 minute ago' : '${d.inMinutes} minutes ago';
    if (d.inHours < 24) return d.inHours == 1 ? '1 hour ago' : '${d.inHours} hours ago';
    if (d.inDays == 1) return 'yesterday';
    return '${d.inDays} days ago';
  }

  @override
  State<AppUpdatesSection> createState() => _AppUpdatesSectionState();
}

class _AppUpdatesSectionState extends State<AppUpdatesSection> {
  Timer? _minute;

  @override
  void initState() {
    super.initState();
    // "checked 5 minutes ago" is only true if it keeps counting.
    _minute = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _minute?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final distribution = widget.distribution;
    final u = context.watch<AppUpdater?>();
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final on = u != null && u.enabled;
    final name = on ? u.installedVersionName : AppVersion.name;
    final code = (on ? u.installedVersionCode : null) ?? AppVersion.code;

    Widget tile({Key? key, required IconData icon, required String title, String? subtitle}) => ListTile(
          key: key,
          leading: Icon(icon),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
        );

    final version = tile(
      key: const ValueKey('settings-version'),
      icon: LucideIcons.info,
      title: 'Securely Hello $name',
      subtitle: 'Build $code',
    );

    final children = <Widget>[version];
    if (!on) {
      children.add(tile(
        icon: LucideIcons.download,
        title: distribution == 'play' ? 'Updates come from Google Play' : 'Get new versions at securelyhello.thenn.in',
      ));
    } else {
      children.add(_status(context, u, p, t));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: p.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const Divider(indent: 56),
              children[i],
            ],
          ],
        ),
      ),
    );
  }

  Widget _status(BuildContext context, AppUpdater u, AppPalette p, TextTheme t) {
    final m = u.manifest;
    final installed = u.installedVersionCode;
    final newer = m != null && installed != null && m.versionCode > installed;
    final urgency = u.urgency;
    final size = u.downloadSize;

    String status;
    IconData icon = LucideIcons.refreshCw;
    if (u.checking) {
      status = 'Checking\u2026';
    } else if (urgency == UpdateUrgency.required || urgency == UpdateUrgency.unsupported) {
      status = 'This version is no longer supported';
      icon = LucideIcons.triangleAlert;
    } else if (urgency == UpdateUrgency.available && m != null) {
      status = 'Version ${m.versionName} is ready${size == null ? '' : ' \u00b7 ${AppUpdatesSection.formatSize(size)}'}';
      icon = LucideIcons.sparkles;
    } else if (u.lastCheckFailed) {
      status = "Couldn't check \u2014 check your connection";
      icon = LucideIcons.wifiOff;
    } else if (u.lastChecked != null) {
      status = "You're up to date \u00b7 checked ${AppUpdatesSection.ago(u.lastChecked!, widget.now())}";
      icon = LucideIcons.check;
    } else {
      status = 'Not checked yet';
    }

    final showUpdate = !u.checking &&
        newer &&
        (urgency == UpdateUrgency.available || urgency == UpdateUrgency.required || urgency == UpdateUrgency.unsupported);

    String? detail;
    if (!u.checking) {
      if (urgency == UpdateUrgency.required) {
        detail = 'Update to keep your chats working; your messages and keys stay on this device.';
      } else if (urgency == UpdateUrgency.unsupported) {
        detail = 'Some things may stop working. Get the latest Securely Hello from securelyhello.thenn.in.';
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: p.textSecondary),
              const SizedBox(width: 16),
              Expanded(child: Text(status, key: const ValueKey('update-status'), style: t.bodyLarge)),
            ],
          ),
          if (detail != null) ...[
            const SizedBox(height: 6),
            Text(detail, style: t.bodySmall?.copyWith(color: p.textSecondary)),
          ],
          if (showUpdate && m.notes.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(m.notes, style: t.bodySmall),
          ],
          // Only for an update that exists (or one being fetched): a
          // leftover error with nothing to update isn't worth showing.
          if (showUpdate || u.busy || (newer && u.error != null)) ...[
            const SizedBox(height: 10),
            UpdateActions(updater: u),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton(
              key: const ValueKey('update-check'),
              onPressed: u.checking || u.busy ? null : () => u.check(force: true),
              child: const Text('Check for updates'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Update button with download progress and what went wrong.
class UpdateActions extends StatelessWidget {
  const UpdateActions({super.key, required this.updater, this.onLater, this.blocking = false, this.onPear = false});

  final AppUpdater updater;
  final VoidCallback? onLater;
  final bool blocking;

  /// Shown on the pear update card: ink button and ink text.
  final bool onPear;

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
          LinearProgressIndicator(
            value: updater.progress > 0 ? updater.progress : null,
            color: onPear ? p.onBrand : null,
            backgroundColor: onPear ? p.onBrand.withValues(alpha: 0.2) : null,
          ),
          const SizedBox(height: 6),
          Text(
            updater.progress >= 1 ? 'Checking…' : 'Downloading… ${(updater.progress * 100).round()}%',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: onPear ? p.onBrand : p.textSecondary),
          ),
        ] else
          Wrap(
            alignment: blocking ? WrapAlignment.center : WrapAlignment.start,
            spacing: 8,
            children: [
              FilledButton.icon(
                key: const ValueKey('update-now'),
                style: onPear ? FilledButton.styleFrom(backgroundColor: p.onBrand, foregroundColor: p.brand) : null,
                onPressed: updater.downloadAndInstall,
                icon: const Icon(LucideIcons.download, size: 18),
                label: const Text('Update'),
              ),
              if (onLater != null)
                TextButton(
                  style: onPear ? TextButton.styleFrom(foregroundColor: p.onBrand) : null,
                  onPressed: onLater,
                  child: const Text('Later'),
                ),
            ],
          ),
        if (err != null) ...[
          const SizedBox(height: 8),
          Text(message(err),
              textAlign: blocking ? TextAlign.center : TextAlign.start,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: onPear ? p.onBrand : p.danger)),
        ],
      ],
    );
  }
}
