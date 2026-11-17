import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/core/chat/attachment_service.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';

/// An attachment inside a message bubble: an inline image (tap to view
/// full screen) or a file card (tap to save). Decrypts on demand.
class AttachmentView extends StatefulWidget {
  const AttachmentView({
    super.key,
    required this.meta,
    required this.service,
    required this.isSent,
  });

  final Map<String, dynamic> meta;
  final AttachmentService service;
  final bool isSent;

  @override
  State<AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<AttachmentView> {
  Future<Uint8List>? _bytes;
  bool _saving = false;

  Map<String, dynamic> get m => widget.meta;
  String get _name => m['name'] as String? ?? 'file';
  int get _size => m['size'] as int? ?? 0;
  String get _mime => m['mime'] as String? ?? 'application/octet-stream';
  bool get _isImage => AttachmentService.isImage(m);

  @override
  void initState() {
    super.initState();
    if (_isImage && _size <= AttachmentService.autoDownloadBytes) {
      _bytes = widget.service.load(m);
    }
  }

  void _retry() => setState(() => _bytes = widget.service.load(m));

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bytes = await (_bytes ??= widget.service.load(m));
      await FilePicker.saveFile(fileName: _name, bytes: bytes, mimeType: _mime);
    } catch (e) {
      if (mounted) showAppSnackBar(context, 'Could not save: $e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _openFullScreen(Uint8List bytes) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _ImageViewer(bytes: bytes, name: _name, onSave: _save),
    ));
  }

  @override
  Widget build(BuildContext context) =>
      _isImage ? _image(context) : _fileCard(context);

  Widget _image(BuildContext context) {
    final p = context.palette;
    final future = _bytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280, maxHeight: 320, minWidth: 160),
        child: future == null
            ? _placeholder(p, LucideIcons.image, 'Tap to load (${AttachmentService.formatSize(_size)})', _retry)
            : FutureBuilder<Uint8List>(
                future: future,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return _placeholder(p, LucideIcons.imageOff, 'Not available · tap to retry', _retry);
                  }
                  final bytes = snap.data;
                  if (bytes == null) {
                    return Container(
                      height: 180,
                      color: p.inputFill,
                      alignment: Alignment.center,
                      child: const SizedBox(
                          width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                    );
                  }
                  return GestureDetector(
                    onTap: () => _openFullScreen(bytes),
                    child: Image.memory(
                      bytes,
                      key: ValueKey('img-${m['id']}'),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      semanticLabel: _name,
                      errorBuilder: (_, _, _) =>
                          _placeholder(p, LucideIcons.imageOff, "Can't show this image", null),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _placeholder(AppPalette p, IconData icon, String label, VoidCallback? onTap) =>
      InkWell(
        onTap: onTap,
        child: Container(
          height: 140,
          color: p.inputFill,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: p.textMuted),
              const SizedBox(height: 8),
              Text(label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      );

  Widget _fileCard(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final ext = _name.contains('.') ? _name.split('.').last.toUpperCase() : 'FILE';
    return Material(
      color: Colors.black.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        key: ValueKey('file-${m['id']}'),
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: _save,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: p.accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                alignment: Alignment.center,
                child: Text(ext.length > 4 ? ext.substring(0, 4) : ext,
                    style: t.labelSmall?.copyWith(
                        color: p.accent, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text('${AttachmentService.formatSize(_size)} · encrypted',
                        style: t.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _saving
                  ? const SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(LucideIcons.download, size: 20, color: p.accent),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.bytes, required this.name, required this.onSave});

  final Uint8List bytes;
  final String name;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Save',
            icon: const Icon(LucideIcons.download),
            onPressed: onSave,
          ),
        ],
      ),
      body: InteractiveViewer(
        maxScale: 6,
        child: Center(child: Image.memory(bytes, semanticLabel: name)),
      ),
    );
  }
}
