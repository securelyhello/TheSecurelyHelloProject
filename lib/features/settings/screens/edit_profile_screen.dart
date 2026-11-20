import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/chat/profile_service.dart';
import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';

/// Photo, name and "about" line. The photo and about line go to contacts
/// end to end; the name is also on the server (people search for it).
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final AuthProvider _auth = context.read<AuthProvider>();
  late final ProfileService _profiles = context.read<ProfileService>();
  late final _name = TextEditingController(text: _auth.displayName);
  late final _about = TextEditingController(text: _profiles.aboutOf(_auth.myUserId ?? ''));
  Uint8List? _newPhoto;
  bool _removePhoto = false;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    PlatformFile? file;
    try {
      file = await FilePicker.pickFile(dialogTitle: 'Choose a photo', type: FileType.image);
    } catch (e) {
      if (mounted) showAppSnackBar(context, 'Could not open files: $e', error: true);
      return;
    }
    if (file == null) return;
    final bytes = await file.readAsBytes();
    try {
      final square = await compute(ProfileService.squareJpeg, bytes);
      if (!mounted) return;
      setState(() {
        _newPhoto = square;
        _removePhoto = false;
      });
    } on FormatException {
      if (mounted) showAppSnackBar(context, "That file isn't a photo we can read", error: true);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final chat = context.read<ChatProvider>();
    final contacts = context.read<ContactsProvider>().contacts.map((c) => c.userId).toList();
    final name = _name.text.trim();
    var ok = true;
    if (name.isNotEmpty && name != _auth.displayName) ok = await _auth.updateDisplayName(name);
    if (ok) {
      try {
        await chat.setMyProfile(contacts,
            photo: _newPhoto, removePhoto: _removePhoto, about: _about.text);
      } catch (e) {
        ok = false;
        if (mounted) showAppSnackBar(context, friendlyError(e.toString()), error: true);
      }
    } else if (mounted) {
      showAppSnackBar(context, friendlyError(_auth.errorMessage), error: true);
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final me = _auth.myUserId ?? '';
    final current = context.select<ProfileService, Uint8List?>((s) => s.photoOf(me));
    final shown = _removePhoto ? null : (_newPhoto ?? current);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit profile'),
        actions: [
          TextButton(
            key: const ValueKey('profile-save'),
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        children: [
          Center(
            child: Stack(clipBehavior: Clip.none, children: [
              AvatarWidget(
                key: const ValueKey('profile-photo'),
                displayName: _name.text,
                seed: me,
                photo: shown,
                size: AvatarSize.xlarge,
              ),
              Positioned(
                right: -4,
                bottom: -4,
                child: Material(
                  color: p.brand,
                  shape: const CircleBorder(),
                  child: IconButton(
                    key: const ValueKey('profile-photo-pick'),
                    tooltip: 'Change photo',
                    icon: Icon(LucideIcons.camera, color: p.onBrand, size: 20),
                    onPressed: _pickPhoto,
                  ),
                ),
              ),
            ]),
          ),
          if (shown != null)
            Center(
              child: TextButton(
                onPressed: () => setState(() {
                  _newPhoto = null;
                  _removePhoto = true;
                }),
                child: const Text('Remove photo'),
              ),
            ),
          const SizedBox(height: 24),
          TextField(
            key: const ValueKey('profile-name'),
            controller: _name,
            maxLength: 64,
            decoration: const InputDecoration(labelText: 'Name'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('profile-about'),
            controller: _about,
            maxLength: ProfileService.maxAbout,
            decoration: const InputDecoration(labelText: 'About', hintText: 'A few words, e.g. "At work"'),
          ),
          const SizedBox(height: 8),
          Text(
            'Your photo and about line are sent to your contacts end to end. '
            "The server never sees them. Your name is on the server so people can find you.",
            style: t.bodySmall?.copyWith(color: p.textMuted, height: 1.45),
          ),
        ],
      ),
    );
  }
}
