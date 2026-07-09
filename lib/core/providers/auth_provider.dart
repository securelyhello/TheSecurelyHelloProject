import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide LocalStorage;
import 'package:securelyhello/core/crypto/crypto_core.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/networking/supabase_directory_service.dart';

/// Authentication state for the app.
enum AuthStatus {
  initial,
  loading,
  authenticated,
  unauthenticated,
  needsVerification,
  needsProfile,
  error,
}

/// Manages authentication state and user identity.
class AuthProvider extends ChangeNotifier {
  final SupabaseDirectoryService _directoryService;
  final LocalStorage _localStorage;

  AuthStatus _status = AuthStatus.initial;
  User? _user;
  CryptoIdentity? _identity;
  String? _errorMessage;
  bool _isLoading = false;
  StreamSubscription<AuthState>? _authSubscription;

  AuthProvider({
    required SupabaseDirectoryService directoryService,
    required LocalStorage localStorage,
  })  : _directoryService = directoryService,
        _localStorage = localStorage;

  // -- Getters --
  AuthStatus get status => _status;
  User? get user => _user;
  CryptoIdentity? get identity => _identity;
  String? get errorMessage => _errorMessage;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _status == AuthStatus.authenticated;
  String? get userId => _user?.id;

  /// Initialize auth state — call once at app start.
  Future<void> init() async {
    _setLoading(true);

    // Listen for auth state changes
    _authSubscription = _directoryService.authStateChanges.listen(
      _handleAuthStateChange,
      onError: (error) {
        _setError('Auth stream error: $error');
      },
    );

    // Check current session
    final currentUser = _directoryService.currentUser;
    if (currentUser != null) {
      _user = currentUser;
      await _loadIdentity();
      if (_identity != null) {
        _setStatus(AuthStatus.authenticated);
      } else {
        _setStatus(AuthStatus.needsProfile);
      }
    } else {
      _setStatus(AuthStatus.unauthenticated);
    }

    _setLoading(false);
  }

  /// Sign up with email and password.
  Future<bool> signUp({
    required String email,
    required String password,
    required String username,
    required String displayName,
  }) async {
    _setLoading(true);
    _clearError();

    try {
      // Check username availability first
      final isAvailable = await _directoryService.isUsernameAvailable(username);
      if (!isAvailable) {
        _setError('Username @$username is already taken');
        _setLoading(false);
        return false;
      }

      // Sign up with Supabase Auth
      final response = await _directoryService.signUp(email, password);

      if (response.user != null) {
        _user = response.user;

        // Generate crypto identity on-device
        _identity = CryptoCore.generateIdentity();

        // Save identity locally (private keys stay on device)
        await _localStorage.saveIdentity(_identity!);

        // Create public profile on Supabase (only public keys)
        await _directoryService.createUserProfile(
          uid: _user!.id,
          username: username,
          displayName: displayName,
          publicSigningKey: _identity!.publicSigningKeyBase64,
          publicEncryptionKey: _identity!.publicEncryptionKeyBase64,
        );

        // Check if email verification is required
        if (response.session == null) {
          _setStatus(AuthStatus.needsVerification);
        } else {
          _setStatus(AuthStatus.authenticated);
        }

        _setLoading(false);
        return true;
      } else {
        _setError('Signup failed — no user returned');
        _setLoading(false);
        return false;
      }
    } on AuthException catch (e) {
      _setError(e.message);
      _setLoading(false);
      return false;
    } catch (e) {
      _setError('Signup failed: $e');
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
      final response = await _directoryService.signIn(email, password);

      if (response.user != null) {
        _user = response.user;

        // Load crypto identity from local storage
        await _loadIdentity();

        if (_identity != null) {
          // Update online status
          await _directoryService.updateOnlineStatus(true);
          _setStatus(AuthStatus.authenticated);
        } else {
          // Identity not found locally — user signed up on another device
          // Generate a new identity and update Supabase profile
          _identity = CryptoCore.generateIdentity();
          await _localStorage.saveIdentity(_identity!);

          // Update public keys on Supabase
          await _directoryService.updateProfile(
            displayName: null,
            avatarUrl: null,
            username: null,
          );

          _setStatus(AuthStatus.authenticated);
        }

        _setLoading(false);
        return true;
      } else {
        _setError('Login failed — no user returned');
        _setLoading(false);
        return false;
      }
    } on AuthException catch (e) {
      _setError(e.message);
      _setLoading(false);
      return false;
    } catch (e) {
      _setError('Login failed: $e');
      _setLoading(false);
      return false;
    }
  }

  /// Sign out.
  Future<void> signOut() async {
    _setLoading(true);
    try {
      await _directoryService.updateOnlineStatus(false);
      await _directoryService.signOut();
      _user = null;
      _identity = null;
      _setStatus(AuthStatus.unauthenticated);
    } catch (e) {
      _setError('Sign out failed: $e');
    }
    _setLoading(false);
  }

  /// Request password reset email.
  Future<bool> resetPassword(String email) async {
    _setLoading(true);
    _clearError();

    try {
      await _directoryService.resetPassword(email);
      _setLoading(false);
      return true;
    } catch (e) {
      _setError('Password reset failed: $e');
      _setLoading(false);
      return false;
    }
  }

  /// Delete account permanently.
  Future<bool> deleteAccount() async {
    _setLoading(true);
    _clearError();

    try {
      await _directoryService.deleteAccount();
      _user = null;
      _identity = null;
      await _localStorage.close();
      _setStatus(AuthStatus.unauthenticated);
      _setLoading(false);
      return true;
    } catch (e) {
      _setError('Account deletion failed: $e');
      _setLoading(false);
      return false;
    }
  }

  /// Resend verification email.
  Future<bool> resendVerificationEmail() async {
    if (_user?.email == null) return false;
    try {
      await Supabase.instance.client.auth.resend(
        type: OtpType.signup,
        email: _user!.email!,
      );
      return true;
    } catch (e) {
      _setError('Failed to resend verification: $e');
      return false;
    }
  }

  // -- Private methods --

  void _handleAuthStateChange(AuthState authState) {
    final event = authState.event;
    final session = authState.session;

    switch (event) {
      case AuthChangeEvent.signedIn:
        if (session?.user != null) {
          _user = session!.user;
          _loadIdentity().then((_) {
            if (_identity != null) {
              _setStatus(AuthStatus.authenticated);
            } else {
              _setStatus(AuthStatus.needsProfile);
            }
          });
        }
        break;
      case AuthChangeEvent.signedOut:
        _user = null;
        _identity = null;
        _setStatus(AuthStatus.unauthenticated);
        break;
      case AuthChangeEvent.tokenRefreshed:
        // Session refreshed, nothing to do
        break;
      case AuthChangeEvent.userUpdated:
        _user = authState.session?.user;
        notifyListeners();
        break;
      default:
        break;
    }
  }

  Future<void> _loadIdentity() async {
    _identity = await _localStorage.loadIdentity();
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
    _authSubscription?.cancel();
    super.dispose();
  }
}
