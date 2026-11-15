import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';

import 'support/fake_api.dart';

/// A tiny stateful server: one account whose password and published keys
/// change like the real thing.
class _Server {
  final api = FakeApi();
  String password = 'old-password';
  String? signingKey;
  String? encryptionKey;
  bool verified = false;
  int tokens = 0;

  _Server() {
    Map<String, dynamic> me() => fakeUser(
      emailVerified: verified,
      signingKey: signingKey,
      encryptionKey: encryptionKey,
    );

    api
      ..on('POST', '/api/auth/signin', (r) {
        if (r.body['password'] != password) {
          return FakeApi.error(401, 'invalid_credentials', 'Wrong password');
        }
        return FakeApi.json({'token': 'tok-${++tokens}', 'user': me()});
      })
      ..on('POST', '/api/auth/signout', (_) => FakeApi.empty())
      ..on('GET', '/api/me', (_) => FakeApi.json(me()))
      ..on('PUT', '/api/me/keys', (r) {
        signingKey = r.body['signing_public_key'] as String;
        encryptionKey = r.body['encryption_public_key'] as String;
        return FakeApi.empty();
      })
      ..on(
        'POST',
        '/api/auth/request-password-reset',
        (_) => FakeApi.json({'ok': true}),
      )
      ..on('POST', '/api/auth/reset-password', (r) {
        if (r.body['code'] != '123456') {
          return FakeApi.error(400, 'invalid_code', 'Invalid code');
        }
        if ((r.body['new_password'] as String).length < 8) {
          return FakeApi.error(400, 'weak_password', 'Password too weak');
        }
        password = r.body['new_password'] as String;
        verified = true;
        return FakeApi.empty();
      })
      ..on('POST', '/api/auth/request-verification', (_) {
        if (verified) {
          return FakeApi.error(409, 'already_verified', 'Already verified');
        }
        return FakeApi.json({'ok': true});
      })
      ..on('POST', '/api/auth/verify-email', (r) {
        if (r.body['code'] != '654321') {
          return FakeApi.error(400, 'invalid_code', 'Invalid code');
        }
        verified = true;
        return FakeApi.json(me());
      });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Server server;
  late SecureKeyStore keyStore;
  late AuthProvider auth;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    server = _Server();
    keyStore = SecureKeyStore(storage: MemorySecretStorage());
    final directory = server.api.directory(tokenStore: keyStore);
    auth = AuthProvider(
      directoryService: directory,
      localStorage: tempLocalStorage(),
      keyStore: keyStore,
    );
  });

  test(
    'sign in, out, reset, in: same identity, keys not republished',
    () async {
      expect(
        await auth.signIn(email: 'alice@example.com', password: 'old-password'),
        isTrue,
      );
      final firstSigning = auth.identity!.publicSigningKeyBase64;
      final firstEncryption = auth.identity!.publicEncryptionKeyBase64;
      expect(server.api.seen('PUT', '/api/me/keys'), hasLength(1));

      await auth.signOut();
      expect(auth.isAuthenticated, isFalse);

      expect(await auth.requestPasswordReset('alice@example.com'), isTrue);
      expect(
        await auth.resetPassword(
          email: 'alice@example.com',
          code: '123456',
          newPassword: 'new-password',
        ),
        isTrue,
      );
      // The reset does not sign in.
      expect(auth.isAuthenticated, isFalse);

      expect(
        await auth.signIn(email: 'alice@example.com', password: 'new-password'),
        isTrue,
      );
      expect(auth.identity!.publicSigningKeyBase64, firstSigning);
      expect(auth.identity!.publicEncryptionKeyBase64, firstEncryption);
      expect(
        server.api.seen('PUT', '/api/me/keys'),
        hasLength(1),
        reason: 'keys must not be republished after a reset',
      );
      // Successful reset marks the email verified server-side.
      expect(auth.emailVerified, isTrue);
    },
  );

  test(
    'resetPassword failure sets errorMessage without an error status',
    () async {
      final ok = await auth.resetPassword(
        email: 'alice@example.com',
        code: '000000',
        newPassword: 'whatever1',
      );
      expect(ok, isFalse);
      expect(auth.errorMessage, contains('code'));
      expect(auth.status, isNot(AuthStatus.error));
    },
  );

  test('weak password error is reported', () async {
    final ok = await auth.resetPassword(
      email: 'alice@example.com',
      code: '123456',
      newPassword: 'short',
    );
    expect(ok, isFalse);
    expect(auth.errorMessage, isNotNull);
    expect(server.password, 'old-password');
  });

  test('requestPasswordReset reports network failure', () async {
    server.api.on(
      'POST',
      '/api/auth/request-password-reset',
      (_) => throw Exception('socket'),
    );
    expect(await auth.requestPasswordReset('alice@example.com'), isFalse);
    expect(auth.errorMessage, isNotNull);
  });

  group('email verification', () {
    setUp(() async {
      await auth.signIn(email: 'alice@example.com', password: 'old-password');
    });

    test('emailVerified reflects the profile', () {
      expect(auth.emailVerified, isFalse);
    });

    test('request + verify flips emailVerified and notifies', () async {
      var notified = 0;
      auth.addListener(() => notified++);
      expect(await auth.requestEmailVerification(), isTrue);
      expect(auth.emailVerified, isFalse);
      expect(await auth.verifyEmail('654321'), isTrue);
      expect(auth.emailVerified, isTrue);
      expect(notified, greaterThan(0));
    });

    test('wrong code keeps unverified and sets an error', () async {
      expect(await auth.verifyEmail('111111'), isFalse);
      expect(auth.emailVerified, isFalse);
      expect(auth.errorMessage, contains('code'));
      expect(auth.isAuthenticated, isTrue);
    });

    test('409 already_verified counts as verified', () async {
      server.verified = true;
      expect(await auth.requestEmailVerification(), isTrue);
      expect(auth.emailVerified, isTrue);
    });

    test('503 unavailable reports a readable error', () async {
      server.api.on(
        'POST',
        '/api/auth/request-verification',
        (_) => FakeApi.error(503, 'unavailable', 'x'),
      );
      expect(await auth.requestEmailVerification(), isFalse);
      expect(auth.errorMessage, contains('later'));
    });

    test('verified flag survives the offline profile cache', () async {
      await auth.verifyEmail('654321');
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('sh_profile_u-1');
      expect(cached, contains('"email_verified":true'));
    });
  });
}
