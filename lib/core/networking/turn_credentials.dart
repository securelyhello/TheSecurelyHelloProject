import 'dart:async';

import 'package:flutter/foundation.dart';

/// Short-lived TURN credentials handed out by `GET /api/turn`.
///
/// The server signs `username` (`<unix_expiry>:<userId>`) with the coturn
/// shared secret; [ttl] says how long they stay valid from now.
class TurnCredentials {
  final List<String> urls;
  final String username;
  final String credential;
  final Duration ttl;

  const TurnCredentials({
    required this.urls,
    required this.username,
    required this.credential,
    required this.ttl,
  });

  /// Parses the server's answer. Returns `null` when TURN is not configured
  /// (`{urls: [], ttl: 0}`) or the answer is malformed.
  static TurnCredentials? fromJson(Object? json) {
    if (json is! Map) return null;
    final rawUrls = json['urls'];
    final username = json['username'];
    final credential = json['credential'];
    final ttl = json['ttl'];
    if (rawUrls is! List || username is! String || credential is! String) {
      return null;
    }
    if (ttl is! num || ttl <= 0) return null;
    final urls = rawUrls
        .whereType<String>()
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toList(growable: false);
    if (urls.isEmpty) return null;
    return TurnCredentials(
      urls: urls,
      username: username,
      credential: credential,
      ttl: Duration(seconds: ttl.toInt()),
    );
  }

  /// The entry for `RTCConfiguration.iceServers`.
  Map<String, dynamic> toIceServer() => {
    'urls': List<String>.of(urls),
    'username': username,
    'credential': credential,
  };
}

/// Caches server-issued TURN credentials and builds the ICE server list for
/// each new peer connection.
///
/// * Credentials are reused until [refreshMargin] (capped at half the ttl)
///   before they expire. From then on the cached value is still handed out
///   immediately and the refresh runs in the background, so a call never
///   waits on the network while usable credentials exist.
/// * The fetch is only awaited when there are no usable credentials and no
///   failure / unconfigured back-off is pending (bounded by [fetchTimeout]).
/// * Any failure (offline, timeout, server error, TURN not configured) falls
///   back silently to [fallback]: STUN plus the optional static `.env` TURN.
/// * A failed refresh keeps handing out credentials that have not expired
///   yet; retries are spaced by [failureBackoff] / [unconfiguredBackoff].
/// * [scope] (the signed-in user id) keys the cache: switching account drops
///   the old credentials, and no request is made while signed out.
class TurnCredentialCache {
  final Future<TurnCredentials?> Function() _fetch;
  final List<Map<String, dynamic>> _fallback;
  final String? Function()? _scope;
  final DateTime Function() _clock;
  final Duration refreshMargin;
  final Duration failureBackoff;
  final Duration unconfiguredBackoff;
  final Duration fetchTimeout;

  TurnCredentials? _creds;
  DateTime? _expiresAt;
  DateTime? _refreshAt;
  DateTime? _nextAttempt;
  String? _cachedScope;
  Future<void>? _inflight;

  TurnCredentialCache({
    required Future<TurnCredentials?> Function() fetch,
    required List<Map<String, dynamic>> fallback,
    String? Function()? scope,
    DateTime Function()? clock,
    this.refreshMargin = const Duration(minutes: 5),
    this.failureBackoff = const Duration(minutes: 1),
    this.unconfiguredBackoff = const Duration(minutes: 15),
    this.fetchTimeout = const Duration(seconds: 5),
  }) : _fetch = fetch,
       _fallback = List.unmodifiable(fallback),
       _scope = scope,
       _clock = clock ?? DateTime.now;

  /// ICE servers for a new peer connection. Never throws.
  Future<List<Map<String, dynamic>>> iceServers() async {
    final scope = _scope?.call();
    if (_scope != null && scope == null) {
      clear();
      return [..._fallback];
    }
    if (scope != _cachedScope) {
      clear();
      _cachedScope = scope;
    }

    final usable = _usable();
    if (usable != null) {
      // Serve what we have; refresh behind the caller's back if due.
      if (_needsRefresh()) unawaited(_refresh(scope));
      return [..._fallback, usable.toIceServer()];
    }
    // Nothing usable: wait for credentials unless we're backing off (then
    // the fallback is all there is).
    if (_needsRefresh()) await _refresh(scope);
    final fresh = _usable();
    return [..._fallback, if (fresh != null) fresh.toIceServer()];
  }

  /// The cached credentials if they have not expired yet.
  TurnCredentials? _usable() {
    final creds = _creds;
    final expiresAt = _expiresAt;
    if (creds != null && expiresAt != null && _clock().isBefore(expiresAt)) {
      return creds;
    }
    return null;
  }

  /// Warms the cache (e.g. once the realtime connection is up).
  Future<void> prefetch() async {
    try {
      await iceServers();
    } catch (_) {
      // iceServers() already swallows errors; belt and braces.
    }
  }

  /// Forgets cached credentials and any back-off.
  void clear() {
    _creds = null;
    _expiresAt = null;
    _refreshAt = null;
    _nextAttempt = null;
    _cachedScope = null;
    _inflight = null;
  }

  bool _needsRefresh() {
    final now = _clock();
    final next = _nextAttempt;
    if (next != null && now.isBefore(next)) return false;
    final refreshAt = _refreshAt;
    return refreshAt == null || !now.isBefore(refreshAt);
  }

  Future<void> _refresh(String? scope) {
    final pending = _inflight;
    if (pending != null) return pending;
    final run = _doRefresh(scope);
    _inflight = run;
    run.whenComplete(() {
      if (identical(_inflight, run)) _inflight = null;
    });
    return run;
  }

  Future<void> _doRefresh(String? scope) async {
    try {
      final creds = await _fetch().timeout(fetchTimeout);
      if (scope != _cachedScope) return; // account switched meanwhile
      final now = _clock();
      if (creds == null) {
        _creds = null;
        _expiresAt = null;
        _refreshAt = null;
        _nextAttempt = now.add(unconfiguredBackoff);
        return;
      }
      final halfLife = creds.ttl ~/ 2;
      final margin = refreshMargin < halfLife ? refreshMargin : halfLife;
      _creds = creds;
      _expiresAt = now.add(creds.ttl);
      _refreshAt = _expiresAt!.subtract(margin);
      _nextAttempt = null;
    } catch (e) {
      debugPrint('TURN credentials unavailable, using fallback: $e');
      if (scope == _cachedScope) {
        _nextAttempt = _clock().add(failureBackoff);
      }
    }
  }
}
