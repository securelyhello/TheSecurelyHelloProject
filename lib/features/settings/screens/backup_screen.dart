import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/backup/chat_backup.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/core/security/sensitive_clipboard.dart';

/// Save chats to an encrypted file, or restore them from one.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  bool _busy = false;

  Future<void> _export() async {
    final key = ChatBackup.newKey();
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _KeyDialog(backupKey: key),
    );
    if (saved != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final bytes = await context.read<ChatProvider>().exportBackup(key);
      final stamp = DateTime.now().toIso8601String().substring(0, 10);
      final path = await FilePicker.saveFile(
        dialogTitle: 'Save chat backup',
        fileName: 'securelyhello-$stamp.shbackup',
        bytes: bytes,
      );
      if (mounted && path != null) showAppSnackBar(context, 'Backup saved');
    } catch (e) {
      if (mounted) showAppSnackBar(context, friendlyError(e.toString()), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    PlatformFile? file;
    try {
      file = await FilePicker.pickFile(dialogTitle: 'Choose a backup file');
    } catch (e) {
      if (mounted) showAppSnackBar(context, 'Could not open files: $e', error: true);
      return;
    }
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final controller = TextEditingController();
    final key = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backup key'),
        content: TextField(
          key: const ValueKey('backup-key-input'),
          controller: controller,
          autofocus: true,
          enableIMEPersonalizedLearning: false,
          autocorrect: false,
          decoration: const InputDecoration(hintText: 'xxxxx-xxxxx-xxxxx-xxxxx-xxxxx'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Restore')),
        ],
      ),
    );
    controller.dispose();
    if (key == null || key.trim().isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final n = await context.read<ChatProvider>().restoreBackup(bytes, key);
      if (mounted) showAppSnackBar(context, n == 0 ? 'Everything in it was already here' : 'Restored $n messages');
    } on BackupException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, error: true);
    } catch (e) {
      if (mounted) showAppSnackBar(context, friendlyError(e.toString()), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Chat backup')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(
            'A backup is a file with your chats, encrypted with a key only you get. Keep the file '
            "and the key apart. Without the key nobody can open the file, and we can't recover it. "
            "Disappearing messages and your encryption keys aren't included.",
            style: t.bodyMedium?.copyWith(color: p.textSecondary, height: 1.45),
          ),
          const SizedBox(height: 24),
          if (_busy) const LinearProgressIndicator(),
          ListTile(
            key: const ValueKey('backup-export'),
            leading: Icon(LucideIcons.download, color: p.accent),
            title: const Text('Back up now'),
            subtitle: const Text('Save an encrypted file'),
            onTap: _busy ? null : _export,
          ),
          ListTile(
            key: const ValueKey('backup-restore'),
            leading: Icon(LucideIcons.upload, color: p.accent),
            title: const Text('Restore a backup'),
            subtitle: const Text('Chats already here are kept'),
            onTap: _busy ? null : _restore,
          ),
        ],
      ),
    );
  }
}

class _KeyDialog extends StatefulWidget {
  final String backupKey;
  const _KeyDialog({required this.backupKey});

  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<_KeyDialog> {
  bool _written = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AlertDialog(
      title: const Text('Your backup key'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Write it down or save it in a password manager. You need it to restore this '
            "backup, and it won't be shown again."),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: p.inputFill,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          // One line: a key broken mid-group is easy to copy down wrong.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SelectableText(
              widget.backupKey,
              key: const ValueKey('backup-key'),
              maxLines: 1,
              style: GoogleFonts.sourceCodePro(fontSize: 17, letterSpacing: 1, color: p.textPrimary),
            ),
          ),
        ),
        TextButton.icon(
          onPressed: () {
            SensitiveClipboard.copy(widget.backupKey);
            showAppSnackBar(context, 'Key copied');
          },
          icon: const Icon(LucideIcons.copy, size: 16),
          label: const Text('Copy'),
        ),
        CheckboxListTile(
          key: const ValueKey('backup-key-written'),
          contentPadding: EdgeInsets.zero,
          value: _written,
          onChanged: (v) => setState(() => _written = v ?? false),
          title: const Text('I saved this key'),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('backup-continue'),
          onPressed: _written ? () => Navigator.pop(context, true) : null,
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
