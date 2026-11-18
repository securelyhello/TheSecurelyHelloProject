import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart' as hash;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The token in an invite link, or null. Accepts
/// `securelyhello://invite/<token>`, `https://<any host>/i/<token>`, a bare
/// token, or a message with one of those links in it.
String? inviteTokenFrom(String text) {
  final t = text.trim();
  final re = RegExp(r'^[A-Za-z0-9_-]{22}$');
  if (re.hasMatch(t)) return t;
  final inText = RegExp(r'(?:securelyhello://invite/|https?://[^\s/]+/i/)[A-Za-z0-9_-]{22}(?![A-Za-z0-9_-])')
      .firstMatch(t);
  if (inText != null && inText.start > 0) return inviteTokenFrom(inText.group(0)!);
  final uri = Uri.tryParse(t);
  if (uri == null) return null;
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  String? token;
  if (uri.scheme == 'securelyhello' && uri.host == 'invite' && segs.length == 1) {
    token = segs.first;
  } else if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      segs.length == 2 &&
      segs.first == 'i') {
    token = segs[1];
  }
  return token != null && re.hasMatch(token) ? token : null;
}

/// The hash the server matches address-book e-mails against
/// (server/src/invites.js, emailHash).
String emailHash(String email) => base64Encode(
    hash.sha256.convert(utf8.encode('securelyhello-email|${email.trim().toLowerCase()}')).bytes);

/// Holds an invite opened from a link until someone is signed in to accept
/// it. Kept across restarts, so signing up first still works.
class PendingInvites extends ChangeNotifier {
  static const _key = 'sh_pending_invite';
  String? _token;
  StreamSubscription<Uri>? _sub;

  String? get token => _token;

  Future<void> init() async {
    try {
      _token = (await SharedPreferences.getInstance()).getString(_key);
    } catch (_) {}
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) return;
    try {
      final links = AppLinks();
      final first = await links.getInitialLink();
      if (first != null) await offer(first.toString());
      _sub = links.uriLinkStream.listen((u) => offer(u.toString()));
    } on MissingPluginException {
      // Desktop builds without link handling: pasting a link still works.
    } on PlatformException {
      // Same.
    }
  }

  /// Remembers [link] if it is an invite. Returns whether it was one.
  Future<bool> offer(String link) async {
    final token = inviteTokenFrom(link);
    if (token == null) return false;
    _token = token;
    try {
      await (await SharedPreferences.getInstance()).setString(_key, token);
    } catch (_) {}
    notifyListeners();
    return true;
  }

  /// Takes the pending token (once).
  Future<String?> take() async {
    final t = _token;
    _token = null;
    try {
      await (await SharedPreferences.getInstance()).remove(_key);
    } catch (_) {}
    return t;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
