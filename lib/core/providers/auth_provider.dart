import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/crypto/device_manager.dart';
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
///    device identity on a fresh install), and
/// 4. registers itself as one of the account's devices (public identity
///    keys, signed prekey and one-time prekeys), so contacts can start
///    forward-secret sessions with it.
class AuthProvider extends ChangeNotifier {
  final DirectoryService _directoryService;
  final LocalStorage _localStorage;
  final SecureKeyStore _keyStore;
  final DeviceManager _deviceManager;

  AuthStatus _status = AuthStatus.initial;
  AuthUser? _user;
  CryptoIdentity? _identity;
  String? _deviceId;
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
    DeviceManager? deviceManager,
  })  : _directoryService = directoryService,
        _localStorage = localStorage,
        _keyStore = keyStore,
        _deviceManager = deviceManager ??
            DeviceManager(storage: localStorage, directory: directoryService);

  // -- Getters --
  AuthStatus get status => _status;
  AuthUser? get user => _user;
  CryptoIdentity? get identity => _identity;

  /// This device's id within the account (set once registered).
  String? get deviceId => _deviceId;
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

  /// Whether the account's e-mail address is confirmed.
  bool get emailVerified => _profile?['email_verified'] == true;

  /// The server won't let unverified accounts reach anyone.
  bool get emailVerificationRequired =>
      _profile?['email_verification_required'] == true;

  /// The app must show the verification screen before anything else.
  bool get mustVerifyEmail =>
      isAuthenticated && emailVerificationRequired && !emailVerified;

  /// Where to go after signing in: the verification screen or home.
  String get homeRoute => mustVerifyEmail ? '/verify-email' : '/home';

  Map<String, dynamic>? _serverConfig;

  /// Public server settings (cached after the first successful call).
  Future<Map<String, dynamic>?> serverConfig() async {
    if (_serverConfig != null) return _serverConfig;
    try {
      _serverConfig = await _directoryService.getServerConfig();
    } catch (_) {}
    return _serverConfig;
  }

  /// Whether this server can e-mail codes (needed for password reset).
  Future<bool> emailAvailable() async =>
      (await serverConfig())?['password_reset'] == true;

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
      // Keys are generated on-device (in _bootstrap); only public halves
      // ever leave it.
      final profile = await _directoryService.signUp(
        email: email,
        password: password,
        username: username.trim().toLowerCase(),
        displayName: displayName,
      );
      final userId = profile['user_id'] as String;
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

  // ---------------------------------------------------------------------------
  // E-mail verification and password reset
  // ---------------------------------------------------------------------------

  /// E-mails a new verification code.
  Future<bool> resendVerificationEmail() async {
    _errorMessage = null;
    try {
      await _directoryService.sendVerificationEmail();
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = _describe(e, 'Could not send the code');
      notifyListeners();
      return false;
    }
  }

  /// Confirms the e-mail address with the 6-digit [code].
  Future<bool> verifyEmail(String code) async {
    _errorMessage = null;
    _setLoading(true);
    try {
      final profile = await _directoryService.verifyEmail(code.trim());
      _profile = {...?_profile, ...profile};
      final id = _user?.id;
      if (id != null) await _cacheProfile(id, _profile!);
      _setLoading(false);
      return true;
    } catch (e) {
      _errorMessage = _describe(e, 'Verification failed');
      _setLoading(false);
      return false;
    }
  }

  /// Asks the server to e-mail a password-reset code to [email].
  Future<bool> requestPasswordReset(String email) async {
    _clearError();
    _setLoading(true);
    try {
      await _directoryService.requestPasswordReset(email.trim());
      _setLoading(false);
      return true;
    } catch (e) {
      _errorMessage = _describe(e, 'Could not send the code');
      _setLoading(false);
      return false;
    }
  }

  /// Sets a new password with the e-mailed [code] and signs in. Keys on this
  /// device are kept; other devices are signed out.
  Future<bool> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    _clearError();
    _setLoading(true);
    try {
      final profile = await _directoryService.resetPassword(
          email: email.trim(), code: code.trim(), newPassword: newPassword);
      final ok = await _bootstrap(profile['user_id'] as String,
          email: profile['email'] as String?, knownProfile: profile);
      _setLoading(false);
      return ok;
    } catch (e) {
      _errorMessage = _describe(e, 'Password reset failed');
      if (_status == AuthStatus.error) _status = AuthStatus.unauthenticated;
      _setLoading(false);
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Linked devices
  // ---------------------------------------------------------------------------

  /// This account's devices (`device_id`, `name`, `created_at`,
  /// `last_seen_at`, `current`, public keys).
  Future<List<Map<String, dynamic>>> listDevices() =>
      _directoryService.listMyDevices();

  /// Unlinks another device: it is signed out and stops receiving messages.
  Future<bool> removeDevice(String deviceId) async {
    _errorMessage = null;
    try {
      await _directoryService.removeDevice(deviceId);
      return true;
    } catch (e) {
      _errorMessage = _describe(e, 'Could not remove the device');
      notifyListeners();
      return false;
    }
  }

  Future<bool> renameThisDevice(String name) async {
    _errorMessage = null;
    try {
      await _directoryService.renameCurrentDevice(name.trim());
      return true;
    } catch (e) {
      _errorMessage = _describe(e, 'Could not rename the device');
      notifyListeners();
      return false;
    }
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

    // 4. Register this device (or re-bind it after signing in again).
    try {
      _deviceId = await _deviceManager.register(identity);
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        await _directoryService.forgetSession();
        _setStatus(AuthStatus.unauthenticated);
        return false;
      }
      _deviceId = await _deviceManager.storedDeviceId();
      if (_deviceId == null) {
        _setError(_describe(e, 'Could not register this device'));
        return false;
      }
    } catch (e) {
      // Offline start: keep using the device we registered before.
      _deviceId = await _deviceManager.storedDeviceId();
      if (_deviceId == null) {
        _setError("Can't reach the server. Check your connection and try again.");
        return false;
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
    _deviceId = null;
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
      'email_verified': profile['email_verified'],
      'email_verification_required': profile['email_verification_required'],
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
