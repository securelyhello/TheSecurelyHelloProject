import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:securelyhello/core/storage/secure_key_store.dart';

/// An error answered by the Securely Hello server.
class ApiException implements Exception {
  final int status;
  final String code;
  final String message;

  /// The full error body, for errors that carry data (e.g. device lists).
  final Map<String, dynamic>? details;
  const ApiException(this.status, this.code, this.message, {this.details});

  bool get isUnauthorized => status == 401;
  bool get isRateLimited => status == 429;

  @override
  String toString() => message;
}

/// A relay send listed a stale set of the recipient's devices. [devices]
/// is the current list; refresh and retry.
class DevicesChangedException implements Exception {
  final List<String> devices;
  const DevicesChangedException(this.devices);
  @override
  String toString() => 'The recipient\'s devices changed';
}

/// The server could not be reached at all (offline, DNS, TLS, timeout).
class NetworkException implements Exception {
  final String message;
  const NetworkException(this.message);
  @override
  String toString() => message;
}

/// One WebRTC signaling frame from a contact's device.
class SignalEvent {
  final String from;
  final String fromDevice;
  final String sessionId;

  /// `offer`, `answer`, `ice` or `bye`.
  final String kind;
  final String? sdp;
  final Map<String, dynamic>? candidate;
  const SignalEvent({
    required this.from,
    required this.fromDevice,
    required this.sessionId,
    required this.kind,
    this.sdp,
    this.candidate,
  });
}

/// The server could not forward one of our signaling frames.
class SignalError {
  final String to;
  final String toDevice;
  final String sessionId;

  /// `offline` or `not_contacts`.
  final String reason;
  const SignalError(this.to, this.toDevice, this.sessionId, this.reason);
}

/// A contact came online or went offline.
class PresenceEvent {
  final String userId;
  final bool online;
  final DateTime? lastSeen;
  const PresenceEvent(this.userId, this.online, this.lastSeen);
}

/// A change in the social graph pushed by the server.
///
/// [type] is `contact_request` (new incoming request),
/// `contact_request_update` (one we sent was accepted / rejected, or one we
/// received was cancelled), `contact_removed` or `devices_changed` (the
/// user, a contact or we ourselves added or removed a device).
class ContactEvent {
  final String type;
  final Map<String, dynamic>? request;
  final String? userId;
  const ContactEvent(this.type, {this.request, this.userId});

  String? get status => request?['status'] as String?;
}

/// Client for the Securely Hello server (`server/`): the phonebook and the
/// switchboard.
///
/// * HTTPS for accounts, the user directory, contacts and the ciphertext
///   relay queue.
/// * One authenticated WebSocket for live WebRTC signaling, presence and
///   push notifications. It reconnects on its own with capped exponential
///   back-off and jitter.
///
/// **Security invariants:** private keys never leave the device; the only
/// message data sent here is a signed, NaCl-box-encrypted envelope; the
/// server derives who we are from the session token, never from a field we
/// send.
class DirectoryService {
  static const _requestTimeout = Duration(seconds: 20);
  static const _userAgent = 'SecurelyHello/1.0 (Flutter)';

  final Uri _base;
  final SessionTokenStore _tokenStore;
  final http.Client _http;
  final Random _random = Random();

  StoredSession? _session;

  // ---- realtime state ----
  WebSocket? _socket;
  bool _realtimeWanted = false;
  bool _socketReady = false;
  bool _connecting = false;
  bool _away = false;
  int _attempt = 0;
  Timer? _reconnectTimer;
  int _generation = 0;

  final _signals = StreamController<SignalEvent>.broadcast();
  final _signalErrors = StreamController<SignalError>.broadcast();
  final _presence = StreamController<PresenceEvent>.broadcast();
  final _contactEvents = StreamController<ContactEvent>.broadcast();
  final _relayPushes = StreamController<Map<String, dynamic>>.broadcast();
  final _prekeysLow = StreamController<int>.broadcast();
  final _realtimeState = StreamController<bool>.broadcast();
  final _sessionExpired = StreamController<void>.broadcast();

  DirectoryService({
    required String baseUrl,
    required SessionTokenStore tokenStore,
    http.Client? httpClient,
  })  : _base = _parseBase(baseUrl),
        _tokenStore = tokenStore,
        _http = httpClient ?? http.Client();

  static Uri _parseBase(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError(
          'API_BASE_URL is not set. Add it to .env (see .env.example).');
    }
    final uri = Uri.parse(trimmed);
    if (!uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw ArgumentError('API_BASE_URL must start with http:// or https://');
    }
    return uri;
  }

  // ===========================================================================
  // Streams
  // ===========================================================================

  /// Offers, answers, ICE candidates and hang-ups from contacts.
  Stream<SignalEvent> get signals => _signals.stream;
  Stream<SignalError> get signalErrors => _signalErrors.stream;
  Stream<PresenceEvent> get presenceEvents => _presence.stream;
  Stream<ContactEvent> get contactEvents => _contactEvents.stream;

  /// Relay envelopes pushed live:
  /// `{id, sender_id, sender_device, envelope, created_at}`.
  Stream<Map<String, dynamic>> get relayPushes => _relayPushes.stream;

  /// The server handed out one-time prekeys and this device is running low.
  Stream<int> get prekeysLow => _prekeysLow.stream;

  /// `true` each time the socket is authenticated and ready (also after a
  /// reconnect: fetch whatever was missed), `false` when it drops.
  Stream<bool> get realtimeState => _realtimeState.stream;

  /// The server rejected our session token (revoked, expired, account gone).
  Stream<void> get onSessionExpired => _sessionExpired.stream;

  bool get isRealtimeConnected => _socketReady;
  StoredSession? get session => _session;
  String? get myUserId => _session?.userId;

  // ===========================================================================
  // Auth
  // ===========================================================================

  /// Loads the saved session token, if any.
  Future<StoredSession?> restoreSession() async {
    _session = await _tokenStore.loadSession();
    return _session;
  }

  /// Creates an account and signs in. Keys are registered per device
  /// afterwards ([registerDevice]).
  Future<Map<String, dynamic>> signUp({
    required String email,
    required String password,
    required String username,
    required String displayName,
  }) async {
    final res = await _request('POST', '/api/auth/signup', auth: false, body: {
      'email': email,
      'password': password,
      'username': username,
      'display_name': displayName,
    }) as Map<String, dynamic>;
    return _adoptSession(res);
  }

  Future<Map<String, dynamic>> signIn(String email, String password) async {
    final res = await _request('POST', '/api/auth/signin',
        auth: false,
        body: {'email': email, 'password': password}) as Map<String, dynamic>;
    return _adoptSession(res);
  }

  Future<Map<String, dynamic>> _adoptSession(Map<String, dynamic> res) async {
    final user = Map<String, dynamic>.from(res['user'] as Map);
    final session = StoredSession(
      token: res['token'] as String,
      userId: user['user_id'] as String,
      email: user['email'] as String?,
    );
    _session = session;
    await _tokenStore.saveSession(session);
    return user;
  }

  /// Revokes this session on the server (best effort) and forgets it locally.
  Future<void> signOut() async {
    await stopRealtime();
    if (_session != null) {
      try {
        await _request('POST', '/api/auth/signout');
      } catch (_) {
        // Offline: the token is forgotten locally and expires server-side.
      }
    }
    await forgetSession();
  }

  /// Drops the local session without talking to the server.
  Future<void> forgetSession() async {
    await stopRealtime();
    _session = null;
    await _tokenStore.clearSession();
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _request('POST', '/api/auth/change-password', body: {
      'current_password': currentPassword,
      'new_password': newPassword,
    });
  }

  /// Public server settings: `{email_verification: 'required'|'optional',
  /// password_reset: bool}`.
  Future<Map<String, dynamic>> getServerConfig() async =>
      Map<String, dynamic>.from(
          await _request('GET', '/api/config', auth: false) as Map);

  /// E-mails a fresh verification code to the signed-in account.
  Future<void> sendVerificationEmail() =>
      _request('POST', '/api/auth/email/send-verification');

  /// Confirms the e-mail address; returns the updated profile.
  Future<Map<String, dynamic>> verifyEmail(String code) async =>
      Map<String, dynamic>.from(await _request('POST', '/api/auth/email/verify',
          body: {'code': code}) as Map);

  /// E-mails a password-reset code (the server answers the same whether or
  /// not the address has an account).
  Future<void> requestPasswordReset(String email) => _request(
      'POST', '/api/auth/password/forgot',
      auth: false, body: {'email': email});

  /// Sets a new password with the e-mailed code and signs in. Every other
  /// session of the account is signed out.
  Future<Map<String, dynamic>> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final res = await _request('POST', '/api/auth/password/reset',
        auth: false,
        body: {'email': email, 'code': code, 'new_password': newPassword})
        as Map<String, dynamic>;
    return _adoptSession(res);
  }

  /// Deletes the account and everything the server holds about it.
  Future<void> deleteAccount() async {
    await stopRealtime();
    await _request('DELETE', '/api/me');
    _session = null;
    await _tokenStore.clearSession();
  }

  // ===========================================================================
  // Directory
  // ===========================================================================

  Future<Map<String, dynamic>> getMyProfile() async =>
      Map<String, dynamic>.from(await _request('GET', '/api/me') as Map);

  // ===========================================================================
  // Devices and prekeys (only public keys are ever sent)
  // ===========================================================================

  /// Registers (or re-registers) this device and binds the session to it.
  /// Returns `{device_id, prekeys_remaining}`.
  Future<Map<String, dynamic>> registerDevice({
    String? deviceId,
    required String name,
    required String signingKey,
    required String identityKey,
    required Map<String, dynamic> signedPreKey,
    List<Map<String, dynamic>> oneTimePreKeys = const [],
  }) async =>
      Map<String, dynamic>.from(await _request('PUT', '/api/devices/current',
          body: {
            if (deviceId != null) 'device_id': deviceId,
            'name': name,
            'signing_public_key': signingKey,
            'identity_public_key': identityKey,
            'signed_prekey': signedPreKey,
            'one_time_prekeys': oneTimePreKeys,
          }) as Map);

  /// `{device_id, prekeys_remaining}` for this session's device.
  Future<Map<String, dynamic>> getCurrentDevice() async =>
      Map<String, dynamic>.from(
          await _request('GET', '/api/devices/current') as Map);

  /// Uploads more one-time prekeys; returns how many the server now holds.
  Future<int> uploadPreKeys(List<Map<String, dynamic>> keys) async {
    final res = await _request('POST', '/api/devices/current/prekeys',
        body: {'one_time_prekeys': keys}) as Map;
    return res['prekeys_remaining'] as int;
  }

  Future<void> rotateSignedPreKey(Map<String, dynamic> spk) =>
      _request('PUT', '/api/devices/current/signed-prekey', body: spk);

  /// Our own devices with names: `{device_id, name, created_at,
  /// last_seen_at, current, signing_public_key, identity_public_key}`.
  Future<List<Map<String, dynamic>>> listMyDevices() async =>
      _list(await _request('GET', '/api/devices'));

  Future<void> renameCurrentDevice(String name) =>
      _request('PATCH', '/api/devices/current', body: {'name': name});

  /// Unlinks one of our devices (its sessions end, its queue is dropped).
  Future<void> removeDevice(String deviceId) =>
      _request('DELETE', '/api/devices/${Uri.encodeComponent(deviceId)}');

  /// Registers this device's FCM token for content-free wake-ups.
  Future<void> registerPushToken(String token) => _request(
      'PUT', '/api/devices/current/push',
      body: {'platform': 'fcm', 'token': token});

  Future<void> clearPushToken() =>
      _request('DELETE', '/api/devices/current/push');

  /// Public device keys of [userId].
  Future<List<Map<String, dynamic>>> getUserDevices(String userId) async =>
      _list(await _request(
          'GET', '/api/users/${Uri.encodeComponent(userId)}/devices'));

  /// Claims one prekey bundle per device (contacts or ourselves only).
  Future<List<Map<String, dynamic>>> claimPreKeyBundles(
          String userId, List<String> deviceIds) async =>
      _list(await _request(
          'POST', '/api/users/${Uri.encodeComponent(userId)}/prekey-bundles',
          body: {'device_ids': deviceIds}));

  Future<void> updateProfile({String? displayName, String? username}) async {
    final body = <String, dynamic>{
      if (displayName != null) 'display_name': displayName,
      if (username != null) 'username': username,
    };
    if (body.isEmpty) return;
    await _request('PATCH', '/api/me', body: body);
  }

  Future<Map<String, dynamic>?> getUserById(String userId) =>
      _maybeUser('/api/users/${Uri.encodeComponent(userId)}');

  Future<Map<String, dynamic>?> getUserByUsername(String username) =>
      _maybeUser('/api/users/by-username/${Uri.encodeComponent(username)}');

  Future<Map<String, dynamic>?> _maybeUser(String path) async {
    try {
      return Map<String, dynamic>.from(await _request('GET', path) as Map);
    } on ApiException catch (e) {
      if (e.status == 404 || e.status == 400) return null;
      rethrow;
    }
  }

  /// Substring search on usernames (never returns yourself).
  Future<List<Map<String, dynamic>>> searchUsers(String query) async {
    final q = query.trim().replaceFirst(RegExp(r'^@'), '');
    if (q.isEmpty || q.length > 30) return const [];
    return _list(await _request(
        'GET', '/api/users/search?q=${Uri.encodeQueryComponent(q)}'));
  }

  Future<bool> isUsernameAvailable(String username) async {
    final res = await _request(
        'GET', '/api/usernames/${Uri.encodeComponent(username)}/available',
        auth: false) as Map;
    return res['available'] == true;
  }

  // ===========================================================================
  // Contact requests & contacts
  // ===========================================================================

  /// Returns the request; its `status` is `accepted` straight away when the
  /// other person had already asked us.
  Future<Map<String, dynamic>> sendContactRequest(String receiverUserId) async =>
      Map<String, dynamic>.from(await _request('POST', '/api/contact-requests',
          body: {'receiver_id': receiverUserId}) as Map);

  Future<void> acceptContactRequest(String requestId) => _request(
      'POST', '/api/contact-requests/${Uri.encodeComponent(requestId)}/accept');

  Future<void> rejectContactRequest(String requestId) => _request(
      'POST', '/api/contact-requests/${Uri.encodeComponent(requestId)}/reject');

  /// Withdraws a pending request we sent.
  Future<void> cancelContactRequest(String requestId) => _request(
      'DELETE', '/api/contact-requests/${Uri.encodeComponent(requestId)}');

  /// Pending requests in both directions, each with `sender` and `receiver`.
  Future<List<Map<String, dynamic>>> fetchPendingRequests() async =>
      _list(await _request('GET', '/api/contact-requests'));

  /// Each row carries the contact's profile under `contact_user`.
  Future<List<Map<String, dynamic>>> getContacts() async =>
      _list(await _request('GET', '/api/contacts'));

  /// Blocks [userId] (removes the contact; they can no longer reach us).
  Future<void> blockUser(String userId) =>
      _request('POST', '/api/blocks', body: {'user_id': userId});

  Future<void> unblockUser(String userId) =>
      _request('DELETE', '/api/blocks/${Uri.encodeComponent(userId)}');

  /// `{user_id, username, display_name, blocked_at}`, newest first.
  Future<List<Map<String, dynamic>>> listBlocked() async =>
      _list(await _request('GET', '/api/blocks'));

  /// Reports [userId]. [evidence] holds only messages the user chose to
  /// share: `{from: 'reported'|'reporter', text, at}`.
  Future<void> reportUser(String userId,
          {required String reason,
          String details = '',
          List<Map<String, dynamic>> evidence = const []}) =>
      _request('POST', '/api/reports', body: {
        'user_id': userId,
        'reason': reason,
        'details': details,
        'evidence': evidence,
      });

  /// Removes the contact for both people.
  Future<void> removeContact(String contactUserId) => _request(
      'DELETE', '/api/contacts/${Uri.encodeComponent(contactUserId)}');

  // ===========================================================================
  // Attachments (ciphertext only)
  // ===========================================================================

  /// Uploads an encrypted blob; returns its id.
  Future<String> uploadAttachment(Uint8List ciphertext) async {
    final res = await _bytesRequest('POST', '/api/attachments', body: ciphertext);
    return (jsonDecode(utf8.decode(res)) as Map)['id'] as String;
  }

  /// Downloads an encrypted blob.
  Future<Uint8List> downloadAttachment(String id) =>
      _bytesRequest('GET', '/api/attachments/${Uri.encodeComponent(id)}');

  Future<Uint8List> _bytesRequest(String method, String path, {Uint8List? body}) async {
    final session = _session;
    if (session == null) {
      throw const ApiException(401, 'unauthorized', 'Not signed in');
    }
    final request = http.Request(method, Uri.parse('${_base.origin}${_basePath()}$path'))
      ..headers['Authorization'] = 'Bearer ${session.token}'
      ..headers['User-Agent'] = _userAgent;
    if (body != null) {
      request.headers['Content-Type'] = 'application/octet-stream';
      request.bodyBytes = body;
    }
    http.Response response;
    try {
      response = await http.Response.fromStream(
          await _http.send(request).timeout(const Duration(minutes: 2)));
    } on TimeoutException {
      throw const NetworkException('The transfer took too long');
    } on SocketException {
      throw const NetworkException("Can't reach the server. Check your connection.");
    } on http.ClientException {
      throw const NetworkException("Can't reach the server. Check your connection.");
    }
    if (response.statusCode < 400) return response.bodyBytes;
    Map? decoded;
    try {
      decoded = jsonDecode(response.body) as Map?;
    } catch (_) {}
    throw ApiException(
      response.statusCode,
      decoded?['error']?.toString() ?? 'http_${response.statusCode}',
      decoded?['message']?.toString() ?? 'Transfer failed (${response.statusCode})',
    );
  }

  // ===========================================================================
  // Relay queue (ciphertext only)
  // ===========================================================================

  /// Parks one envelope per device of [recipientId] (ourselves for sync).
  /// [knownDevices] is our view of all their devices; the server refuses a
  /// stale view with [DevicesChangedException]. [envelopes] maps device id
  /// to envelope JSON and may cover a subset (the rest went P2P).
  Future<void> queueRelayMessages(String recipientId,
      {required List<String> knownDevices,
      required Map<String, String> envelopes}) async {
    try {
      await _request('POST', '/api/relay', body: {
        'recipient_id': recipientId,
        'known_devices': knownDevices,
        'messages': [
          for (final e in envelopes.entries)
            {'device_id': e.key, 'envelope': e.value}
        ],
      });
    } on ApiException catch (e) {
      if (e.status == 409 && e.code == 'devices_changed') {
        throw DevicesChangedException(e.details?['devices'] is List
            ? (e.details!['devices'] as List).cast<String>()
            : const []);
      }
      rethrow;
    }
  }

  /// Envelopes waiting for this device, oldest first:
  /// `{id, sender_id, sender_device, envelope}`.
  Future<List<Map<String, dynamic>>> fetchRelayMessages() async =>
      _list(await _request('GET', '/api/relay?limit=200'));

  /// Deletes envelopes we have stored locally. Uses the socket when it is
  /// up (no HTTP round trip), otherwise HTTP.
  Future<void> ackRelayMessages(List<String> ids) async {
    if (ids.isEmpty) return;
    for (var i = 0; i < ids.length; i += 200) {
      final chunk = ids.sublist(i, min(i + 200, ids.length));
      if (_sendFrame({'type': 'relay_ack', 'ids': chunk})) continue;
      await _request('POST', '/api/relay/ack', body: {'ids': chunk});
    }
  }

  // ===========================================================================
  // Realtime
  // ===========================================================================

  /// Opens (and keeps open) the WebSocket. Idempotent.
  Future<void> startRealtime() async {
    if (_session == null) throw StateError('Not signed in');
    _realtimeWanted = true;
    if (_socket == null && !_connecting) {
      _attempt = 0;
      await _connect();
    }
  }

  Future<void> stopRealtime() async {
    _realtimeWanted = false;
    _generation++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final socket = _socket;
    _socket = null;
    final wasReady = _socketReady;
    _socketReady = false;
    if (socket != null) {
      try {
        await socket.close(WebSocketStatus.normalClosure);
      } catch (_) {}
    }
    if (wasReady && !_realtimeState.isClosed) _realtimeState.add(false);
  }

  /// Reconnect now instead of waiting for the back-off (app resumed, network
  /// came back).
  void nudgeRealtime() {
    if (!_realtimeWanted || _socket != null || _connecting) return;
    _reconnectTimer?.cancel();
    _attempt = 0;
    unawaited(_connect());
  }

  /// Tells contacts we are away (app in background) or back.
  void setAway(bool away) {
    _away = away;
    _sendFrame({'type': 'presence', 'state': away ? 'away' : 'online'});
  }

  /// Sends one signaling frame to one device. Returns `false` if the socket
  /// is down.
  bool sendSignal({
    required String to,
    required String toDevice,
    required String sessionId,
    required String kind,
    String? sdp,
    Map<String, dynamic>? candidate,
    String? reason,
  }) =>
      _sendFrame({
        'type': 'signal',
        'to': to,
        'to_device': toDevice,
        'session_id': sessionId,
        'kind': kind,
        if (sdp != null) 'sdp': sdp,
        if (candidate != null) 'candidate': candidate,
        if (reason != null) 'reason': reason,
      });

  Uri get _wsUri => _base.replace(
        scheme: _base.scheme == 'https' ? 'wss' : 'ws',
        path: '${_basePath()}/api/ws',
      );

  String _basePath() =>
      _base.path.endsWith('/') ? _base.path.substring(0, _base.path.length - 1) : _base.path;

  Future<void> _connect() async {
    final session = _session;
    if (session == null || !_realtimeWanted || _connecting) return;
    _connecting = true;
    final generation = _generation;
    try {
      final socket = await WebSocket.connect(
        _wsUri.toString(),
        headers: {
          'Authorization': 'Bearer ${session.token}',
          'User-Agent': _userAgent,
        },
      ).timeout(const Duration(seconds: 15));
      if (generation != _generation || !_realtimeWanted) {
        unawaited(socket.close());
        return;
      }
      socket.pingInterval = const Duration(seconds: 25);
      _socket = socket;
      socket.listen(
        (data) => _onFrame(socket, data),
        onDone: () => _onSocketClosed(socket),
        onError: (Object _) => _onSocketClosed(socket),
        cancelOnError: true,
      );
    } catch (e) {
      if (generation != _generation) return;
      debugPrint('Realtime connect failed: $e');
      // A rejected upgrade can't be told apart from a network error here, so
      // ask the API whether the session is still valid.
      unawaited(_checkSession());
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  Future<void> _checkSession() async {
    try {
      await _request('GET', '/api/me');
    } catch (_) {
      // 401 is reported by _request itself; anything else is just "offline".
    }
  }

  void _onSocketClosed(WebSocket socket) {
    if (!identical(_socket, socket)) return;
    final code = socket.closeCode;
    _socket = null;
    final wasReady = _socketReady;
    _socketReady = false;
    if (wasReady && !_realtimeState.isClosed) _realtimeState.add(false);
    if (code == 4003 || code == 4004) {
      // Account deleted, or this device unlinked, elsewhere.
      if (!_sessionExpired.isClosed) _sessionExpired.add(null);
      return;
    }
    _scheduleReconnect();
  }

  /// 1 s, 2 s, 4 s … capped at 30 s, with ±30 % jitter so a server restart
  /// does not bring every client back in the same instant.
  void _scheduleReconnect() {
    if (!_realtimeWanted || _session == null) return;
    _reconnectTimer?.cancel();
    final base = min(30000, 1000 * pow(2, min(_attempt, 5)).toInt());
    final jitter = 0.7 + _random.nextDouble() * 0.6;
    _attempt++;
    _reconnectTimer = Timer(
        Duration(milliseconds: (base * jitter).round()), () => _connect());
  }

  void _onFrame(WebSocket socket, dynamic data) {
    if (!identical(_socket, socket) || data is! String) return;
    Map<String, dynamic> frame;
    try {
      frame = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    try {
      _dispatch(frame);
    } catch (e) {
      debugPrint('Bad realtime frame (${frame['type']}): $e');
    }
  }

  void _dispatch(Map<String, dynamic> frame) {
    switch (frame['type']) {
      case 'hello':
        _attempt = 0;
        _socketReady = true;
        if (_away) _sendFrame({'type': 'presence', 'state': 'away'});
        for (final id in (frame['online'] as List? ?? const [])) {
          _presence.add(PresenceEvent(id as String, true, null));
        }
        _realtimeState.add(true);
        break;
      case 'signal':
        final candidate = frame['candidate'];
        _signals.add(SignalEvent(
          from: frame['from'] as String,
          fromDevice: frame['from_device'] as String,
          sessionId: frame['session_id'] as String,
          kind: frame['kind'] as String,
          sdp: frame['sdp'] as String?,
          candidate: candidate is Map
              ? Map<String, dynamic>.from(candidate)
              : null,
        ));
        break;
      case 'signal_error':
        _signalErrors.add(SignalError(
            frame['to'] as String,
            frame['to_device'] as String,
            frame['session_id'] as String,
            frame['reason'] as String));
        break;
      case 'presence':
        final lastSeen = frame['last_seen'] as String?;
        _presence.add(PresenceEvent(
          frame['user_id'] as String,
          frame['online'] == true,
          lastSeen == null ? null : DateTime.tryParse(lastSeen),
        ));
        break;
      case 'relay':
        _relayPushes.add(Map<String, dynamic>.from(frame['message'] as Map));
        break;
      case 'contact_request':
      case 'contact_request_update':
        _contactEvents.add(ContactEvent(
          frame['type'] as String,
          request: Map<String, dynamic>.from(frame['request'] as Map),
        ));
        break;
      case 'prekeys_low':
        _prekeysLow.add(frame['remaining'] as int? ?? 0);
        break;
      case 'contact_removed':
      case 'devices_changed':
        _contactEvents.add(ContactEvent(frame['type'] as String,
            userId: frame['user_id'] as String?));
        break;
      default:
        break; // pong, error: nothing to do
    }
  }

  bool _sendFrame(Map<String, dynamic> frame) {
    final socket = _socket;
    if (socket == null || !_socketReady) return false;
    try {
      socket.add(jsonEncode(frame));
      return true;
    } catch (_) {
      return false;
    }
  }

  // ===========================================================================
  // HTTP
  // ===========================================================================

  static List<Map<String, dynamic>> _list(dynamic value) => (value as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList(growable: false);

  Future<dynamic> _request(
    String method,
    String path, {
    Object? body,
    bool auth = true,
  }) async {
    final session = _session;
    if (auth && session == null) {
      throw const ApiException(401, 'unauthorized', 'Not signed in');
    }
    final uri = Uri.parse('${_base.origin}${_basePath()}$path');
    final request = http.Request(method, uri)
      ..headers['Accept'] = 'application/json'
      ..headers['User-Agent'] = _userAgent;
    if (auth) request.headers['Authorization'] = 'Bearer ${session!.token}';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    http.Response response;
    try {
      response = await http.Response.fromStream(
          await _http.send(request).timeout(_requestTimeout));
    } on TimeoutException {
      throw const NetworkException('The server took too long to respond');
    } on SocketException {
      throw const NetworkException("Can't reach the server. Check your connection.");
    } on HandshakeException {
      throw const NetworkException('Secure connection to the server failed');
    } on http.ClientException {
      throw const NetworkException("Can't reach the server. Check your connection.");
    }

    if (response.statusCode == 204 || response.body.isEmpty) {
      if (response.statusCode < 400) return null;
    }
    dynamic decoded;
    try {
      decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode < 400) return decoded;

    final code = decoded is Map ? decoded['error']?.toString() : null;
    final message = decoded is Map ? decoded['message']?.toString() : null;
    final error = ApiException(
      response.statusCode,
      code ?? 'http_${response.statusCode}',
      message ??
          (response.statusCode == 429
              ? 'Too many requests. Please wait a moment.'
              : 'Server error (${response.statusCode})'),
      details: decoded is Map ? Map<String, dynamic>.from(decoded) : null,
    );
    // Our token was rejected: the session is gone for good.
    if (auth &&
        response.statusCode == 401 &&
        identical(session, _session) &&
        !_sessionExpired.isClosed) {
      _sessionExpired.add(null);
    }
    throw error;
  }

  Future<void> dispose() async {
    await stopRealtime();
    _http.close();
    await _signals.close();
    await _signalErrors.close();
    await _presence.close();
    await _contactEvents.close();
    await _relayPushes.close();
    await _prekeysLow.close();
    await _realtimeState.close();
    await _sessionExpired.close();
  }
}
