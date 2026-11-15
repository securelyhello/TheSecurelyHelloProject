import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';
import 'package:securelyhello/core/networking/directory_service.dart';

/// Authentication state for the app.
enum AuthStatus {
  initial,
  loading,
  authenticated,
  unauthenticated,
  error,
}

/// The signed-in account.
class AuthUser {
  final String id;
  final String? email;
  const AuthUser({required this.id, this.email});
}

/// Manages authentication state, the directory profile and the on-device
/// cryptographic identity.
///
/// On every sign-in the device:
/// 1. loads its profile from the server (or the cached copy when offline),
/// 2. opens this account's encrypted local database,
/// 3. loads its private keys from the platform keystore (generating a new
///    identity on a fresh install), and
/// 4. publishes its public keys if the directory holds different ones, so
///    contacts always encrypt to the device that is actually signed in.
class AuthProvider extends ChangeNotifier {
  final DirectoryService _directoryService;
  final LocalStorage _localStorage;
  final SecureKeyStore _keyStore;

  AuthStatus _status = AuthStatus.initial;
  AuthUser? _user;
  CryptoIdentity? _identity;
  Map<String, dynamic>? _profile;
  String? _errorMessage;
  bool _isLoading = false;
  StreamSubscription<void>? _expiredSubscription;

  bool _signingOut = false;
  final List<Future<void> Function()> _signOutHooks = [];

  AuthProvider({
    required DirectoryService directoryService,
    required LocalStorage localStorage,
    required SecureKeyStore keyStore,
  })  : _directoryService = directoryService,
        _localStorage = localStorage,
        _keyStore = keyStore;

  // -- Getters --
  AuthStatus get status => _status;
  AuthUser? get user => _user;
  CryptoIdentity? get identity => _identity;
  String? get errorMessage => _errorMessage;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _status == AuthStatus.authenticated;

  /// The account id: the id contacts and messages use.
  String? get userId => _user?.id;
  String? get myUserId => _user?.id;
  String? get email => _user?.email;
  String get username => _profile?['username'] as String? ?? '';
  String get displayName =>
      _profile?['display_name'] as String? ?? username;

  /// Whether the account's e-mail address has been confirmed. Verification
  /// is optional: it only drives the reminder banner in Settings.
  bool get emailVerified => _profile?['email_verified'] == true;

  /// Drops a stale error (e.g. when moving between login and sign up).
  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    if (_status == AuthStatus.error) _status = AuthStatus.unauthenticated;
    notifyListeners();
  }

  /// Runs before local state is torn down on sign-out / account deletion.
  void addSignOutHook(Future<void> Function() hook) => _signOutHooks.add(hook);

  /// Initialize auth state: call once at app start.
  Future<void> init() async {
    _setLoading(true);

    _expiredSubscription ??=
        _directoryService.onSessionExpired.listen((_) => _onSessionExpired());

    try {
      final session = await _directoryService.restoreSession();
      if (session != null) {
        await _bootstrap(session.userId, email: session.email);
      } else {
        _setStatus(AuthStatus.unauthenticated);
      }
    } catch (e) {
      debugPrint('Restoring the session failed: $e');
      _setStatus(AuthStatus.unauthenticated);
    }

    _setLoading(false);
  }

  /// Sign up with email, password and a unique username.
  Future<bool> signUp({
    required String email,
    required String password,
    required String username,
    required String displayName,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      // Keys are generated on-device; only public halves ever leave it.
      final identity = CryptoCore.generateIdentity();
      final profile = await _directoryService.signUp(
        email: email,
        password: password,
        username: username.trim().toLowerCase(),
        displayName: displayName,
        publicSigningKey: identity.publicSigningKeyBase64,
        publicEncryptionKey: identity.publicEncryptionKeyBase64,
      );
      final userId = profile['user_id'] as String;
      await _keyStore.saveIdentity(userId, identity);
      final ok = await _bootstrap(userId,
          email: profile['email'] as String?, knownProfile: profile);
      _setLoading(false);
      return ok;
    } catch (e) {
      _setError(_describe(e, 'Sign up failed'));
      _setLoading(false);
      return false;
    }
  }

  /// Sign in with email and password.
  Future<bool> signIn({
    required String email,
    required String password,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      final profile = await _directoryService.signIn(email, password);
      final ok = await _bootstrap(profile['user_id'] as String,
          email: profile['email'] as String?, knownProfile: profile);
      _setLoading(false);
      return ok;
    } catch (e) {
      _setError(_describe(e, 'Log in failed'));
      _setLoading(false);
      return false;
    }
  }

  /// Sign out.
  Future<void> signOut() async {
    _setLoading(true);
    _signingOut = true;
    try {
      await _runSignOutHooks();
      await _directoryService.signOut();
    } catch (e) {
      debugPrint('Sign out error: $e');
    }
    await _clearSession();
    _signingOut = false;
    _setLoading(false);
  }

  /// Changes the password. Other devices are signed out by the server.
  Future<bool> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    _errorMessage = null;
    try {
      await _directoryService.changePassword(
          currentPassword: currentPassword, newPassword: newPassword);
      return true;
    } catch (e) {
      _errorMessage = _describe(e, 'Could not change the password');
      notifyListeners();
      return false;
    }
  }

  /// Asks for a password-reset code. Succeeds for any well-formed address:
  /// the server never reveals whether an account exists.
  Future<bool> requestPasswordReset(String email) async {
    _errorMessage = null;
    try {
      await _directoryService.requestPasswordReset(email.trim());
      return true;
    } catch (e) {
      _errorMessage = _describe(e, 'Could not send the code');
      notifyListeners();
      return false;
    }
  }

  /// Sets a new password with an e-mailed code. Does not sign in: every
  /// session is revoked and the user logs in again. Keys on this device are
  /// untouched, so chats survive.
  Future<bool> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    _errorMessage = null;
    try {
      await _directoryService.resetPassword(
          email: email.trim(), code: code.trim(), newPassword: newPassword);
      return true;
    } catch (e) {
      _errorMessage = _describe(e, 'Could not reset the password');
      notifyListeners();
      return false;
    }
  }

  /// E-mails a verification code to the account address. An address that is
  /// already verified counts as success (and updates [emailVerified]).
  Future<bool> requestEmailVerification() async {
    _errorMessage = null;
    try {
      await _directoryService.requestEmailVerification();
      return true;
    } on ApiException catch (e) {
      if (e.code == 'already_verified') {
        await _markEmailVerified();
        return true;
      }
      _errorMessage = _describe(e, 'Could not send the code');
      notifyListeners();
      return false;
    } catch (e) {
      _errorMessage = _describe(e, 'Could not send the code');
      notifyListeners();
      return false;
    }
  }

  /// Confirms the account address with an e-mailed [code].
  Future<bool> verifyEmail(String code) async {
    _errorMessage = null;
    try {
      final me = await _directoryService.verifyEmail(code.trim());
      final userId = _user?.id;
      if (userId != null) {
        _profile = {...?_profile, ...me, 'email_verified': true};
        await _cacheProfile(userId, _profile!);
      }
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = _describe(e, 'Could not verify the email');
      notifyListeners();
      return false;
    }
  }

  Future<void> _markEmailVerified() async {
    final userId = _user?.id;
    if (userId == null) return;
    _profile = {...?_profile, 'email_verified': true};
    await _cacheProfile(userId, _profile!);
    notifyListeners();
  }

  /// Delete account permanently: server profile, local history and keys.
  Future<bool> deleteAccount() async {
    final userId = _user?.id;
    if (userId == null) return false;
    _setLoading(true);
    _clearError();
    _signingOut = true;

    try {
      // Server first: if it fails, nothing local has been destroyed yet.
      await _directoryService.deleteAccount();
      await _runSignOutHooks();
      await _localStorage.deleteDatabaseForUser(userId);
      await _keyStore.deleteAll(userId);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_profileCacheKey(userId));
      await _clearSession();
      _signingOut = false;
      _setLoading(false);
      return true;
    } catch (e) {
      _signingOut = false;
      _errorMessage = _describe(e, 'Account deletion failed');
      _setLoading(false);
      return false;
    }
  }

  /// Change the public display name.
  Future<bool> updateDisplayName(String name) async {
    final trimmed = name.trim();
    final userId = _user?.id;
    if (trimmed.isEmpty || userId == null) return false;
    try {
      await _directoryService.updateProfile(displayName: trimmed);
      _profile = {...?_profile, 'display_name': trimmed};
      await _cacheProfile(userId, _profile!);
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = _describe(e, 'Could not update name');
      notifyListeners();
      return false;
    }
  }

  /// Tells contacts whether the app is in the foreground. Being connected is
  /// what makes us "online"; this only toggles "away".
  Future<void> setPresence(bool online) async {
    if (!isAuthenticated) return;
    _directoryService.setAway(!online);
    if (online) _directoryService.nudgeRealtime();
  }

  // ---------------------------------------------------------------------------
  // Session bootstrap
  // ---------------------------------------------------------------------------

  Future<bool> _bootstrap(
    String userId, {
    String? email,
    Map<String, dynamic>? knownProfile,
  }) async {
    // 1. Directory profile (fall back to the cached copy when offline).
    Map<String, dynamic>? profile = knownProfile;
    if (profile == null) {
      try {
        profile = await _directoryService.getMyProfile();
      } on ApiException catch (e) {
        if (e.isUnauthorized || e.status == 404) {
          await _directoryService.forgetSession();
          _setStatus(AuthStatus.unauthenticated);
          return false;
        }
        profile = await _loadCachedProfile(userId);
      } catch (_) {
        profile = await _loadCachedProfile(userId);
      }
      if (profile == null) {
        // Never signed in on this device while online: nothing to show.
        _setError("Can't reach the server. Check your connection and try again.");
        return false;
      }
    }
    _user = AuthUser(id: userId, email: profile['email'] as String? ?? email);
    _profile = profile;
    await _cacheProfile(userId, profile);

    // 2. This account's local database.
    final dbKey = await _keyStore.getOrCreateLocalDbKey(userId);
    await _localStorage.openForUser(userId, encryptionKey: dbKey);

    // 3. Private keys: keystore, or a fresh identity on a new device.
    var identity = await _keyStore.loadIdentity(userId);
    if (identity == null) {
      identity = CryptoCore.generateIdentity();
      await _keyStore.saveIdentity(userId, identity);
    }
    _identity = identity;

    // 4. Make sure contacts encrypt to *this* device.
    if (profile['signing_public_key'] != identity.publicSigningKeyBase64 ||
        profile['encryption_public_key'] !=
            identity.publicEncryptionKeyBase64) {
      try {
        await _directoryService.updatePublicKeys(
          publicSigningKey: identity.publicSigningKeyBase64,
          publicEncryptionKey: identity.publicEncryptionKeyBase64,
        );
        _profile = {
          ...profile,
          'signing_public_key': identity.publicSigningKeyBase64,
          'encryption_public_key': identity.publicEncryptionKeyBase64,
        };
        await _cacheProfile(userId, _profile!);
      } catch (e) {
        // Retried automatically on next launch (the mismatch persists).
        debugPrint('Publishing public keys failed: $e');
      }
    }

    _clearError();
    _setStatus(AuthStatus.authenticated);
    return true;
  }

  /// The server rejected our token (revoked, expired, account deleted).
  void _onSessionExpired() {
    if (_signingOut || _status != AuthStatus.authenticated) return;
    _signingOut = true;
    unawaited(() async {
      await _runSignOutHooks();
      await _directoryService.forgetSession();
      await _clearSession();
      _signingOut = false;
    }());
  }

  static String _describe(Object error, String fallback) {
    if (error is ApiException) {
      switch (error.code) {
        case 'invalid_code':
          return 'That code is wrong or has expired. Check it or request a '
              'new one.';
        case 'unavailable':
          return "Verification emails can't be sent right now. Please try "
              'again later.';
      }
    }
    if (error is ApiException || error is NetworkException) {
      return error.toString();
    }
    debugPrint('$fallback: $error');
    return fallback;
  }

  Future<void> _runSignOutHooks() async {
    for (final hook in _signOutHooks) {
      try {
        await hook();
      } catch (e) {
        debugPrint('Sign-out hook failed: $e');
      }
    }
  }

  Future<void> _clearSession() async {
    await _localStorage.close();
    _user = null;
    _identity = null;
    _profile = null;
    _setStatus(AuthStatus.unauthenticated);
  }

  // ---------------------------------------------------------------------------
  // Profile caching (offline start)
  // ---------------------------------------------------------------------------

  static String _profileCacheKey(String authId) => 'sh_profile_$authId';
  Future<void> _cacheProfile(String authId, Map<String, dynamic> profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profileCacheKey(authId), jsonEncode({
      'user_id': profile['user_id'],
      'email': profile['email'],
      'username': profile['username'],
      'display_name': profile['display_name'],
      'signing_public_key': profile['signing_public_key'],
      'encryption_public_key': profile['encryption_public_key'],
      'email_verified': profile['email_verified'] == true,
    }));
  }

  Future<Map<String, dynamic>?> _loadCachedProfile(String authId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profileCacheKey(authId));
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  void _setStatus(AuthStatus status) {
    _status = status;
    notifyListeners();
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void _setError(String message) {
    _errorMessage = message;
    _status = AuthStatus.error;
    notifyListeners();
  }

  void _clearError() {
    _errorMessage = null;
  }

  @override
  void dispose() {
    _expiredSubscription?.cancel();
    super.dispose();
  }
}
