import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/networking/directory_service.dart';

import 'support/fake_api.dart';

Future<DirectoryService> _signedIn(FakeApi api) async {
  api.on(
    'POST',
    '/api/auth/signin',
    (_) => FakeApi.json({'token': 'tok-1', 'user': fakeUser()}),
  );
  final dir = api.directory();
  await dir.signIn('alice@example.com', 'password123');
  return dir;
}

void main() {
  group('password reset', () {
    test('requestPasswordReset posts the email without a token', () async {
      final api = FakeApi()
        ..on(
          'POST',
          '/api/auth/request-password-reset',
          (_) => FakeApi.json({'ok': true}),
        );
      await api.directory().requestPasswordReset('alice@example.com');

      final req = api.seen('POST', '/api/auth/request-password-reset').single;
      expect(req.body, {'email': 'alice@example.com'});
      expect(req.hasBearer, isFalse);
    });

    test('requestPasswordReset surfaces 429 as rate limited', () async {
      final api = FakeApi()
        ..on(
          'POST',
          '/api/auth/request-password-reset',
          (_) => FakeApi.error(429, 'rate_limited', 'Slow down'),
        );
      await expectLater(
        api.directory().requestPasswordReset('a@b.co'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.isRateLimited,
            'isRateLimited',
            true,
          ),
        ),
      );
    });

    test('resetPassword sends email, code and new_password; 204 ok', () async {
      final api = FakeApi()
        ..on('POST', '/api/auth/reset-password', (_) => FakeApi.empty());
      await api.directory().resetPassword(
        email: 'alice@example.com',
        code: '012345',
        newPassword: 'n3wpass!!',
      );

      final req = api.seen('POST', '/api/auth/reset-password').single;
      expect(req.body, {
        'email': 'alice@example.com',
        'code': '012345',
        'new_password': 'n3wpass!!',
      });
      expect(req.hasBearer, isFalse);
    });

    test(
      'resetPassword works even while signed in, still without a token',
      () async {
        final api = FakeApi()
          ..on('POST', '/api/auth/reset-password', (_) => FakeApi.empty());
        final dir = await _signedIn(api);
        await dir.resetPassword(
          email: 'alice@example.com',
          code: '111111',
          newPassword: 'abcdefgh',
        );
        expect(
          api.seen('POST', '/api/auth/reset-password').single.hasBearer,
          isFalse,
        );
      },
    );

    test('resetPassword maps invalid_code', () async {
      final api = FakeApi()
        ..on(
          'POST',
          '/api/auth/reset-password',
          (_) => FakeApi.error(400, 'invalid_code', 'Invalid code'),
        );
      await expectLater(
        api.directory().resetPassword(
          email: 'x@y.z',
          code: '000000',
          newPassword: 'abcdefgh',
        ),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'invalid_code'),
        ),
      );
    });
  });

  group('email verification', () {
    test('requestEmailVerification needs a session', () async {
      final api = FakeApi();
      await expectLater(
        api.directory().requestEmailVerification(),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
      );
      expect(api.requests, isEmpty);
    });

    test('requestEmailVerification posts with the bearer token', () async {
      final api = FakeApi()
        ..on(
          'POST',
          '/api/auth/request-verification',
          (_) => FakeApi.json({'ok': true}),
        );
      final dir = await _signedIn(api);
      await dir.requestEmailVerification();
      final req = api.seen('POST', '/api/auth/request-verification').single;
      expect(req.hasBearer, isTrue);
    });

    test('verifyEmail posts the code and returns the profile', () async {
      final api = FakeApi()
        ..on(
          'POST',
          '/api/auth/verify-email',
          (_) => FakeApi.json(fakeUser(emailVerified: true)),
        );
      final dir = await _signedIn(api);
      final me = await dir.verifyEmail('654321');
      expect(me['email_verified'], isTrue);
      final req = api.seen('POST', '/api/auth/verify-email').single;
      expect(req.body, {'code': '654321'});
      expect(req.hasBearer, isTrue);
    });
  });
}
