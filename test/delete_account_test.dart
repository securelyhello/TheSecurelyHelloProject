import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';

/// DELETE /api/me needs the password (and 2FA code) again; wrong ones are
/// answered 403 / 401 and must not look like an expired session.
void main() {
  late List<http.Request> sent;
  late SecureKeyStore tokens;

  Future<DirectoryService> service(http.Response Function(http.Request) answer) async {
    sent = [];
    tokens = SecureKeyStore(storage: MemorySecretStorage());
    await tokens.saveSession(const StoredSession(token: 'tok', userId: 'me'));
    final d = DirectoryService(
      baseUrl: 'https://fake.invalid',
      tokenStore: tokens,
      httpClient: MockClient((req) async {
        sent.add(req);
        return answer(req);
      }),
    );
    await d.restoreSession();
    return d;
  }

  http.Response error(int status, String code) =>
      http.Response(jsonEncode({'error': code, 'message': 'msg $code'}), status,
          headers: {'content-type': 'application/json'});

  test('sends the password as a JSON body and clears the session', () async {
    final d = await service((_) => http.Response('', 204));
    await d.deleteAccount(currentPassword: 'pw 123');
    expect(sent.single.method, 'DELETE');
    expect(sent.single.url.path, '/api/me');
    expect(sent.single.headers['Content-Type'], startsWith('application/json'));
    expect(jsonDecode(sent.single.body), {'current_password': 'pw 123'});
    expect(d.session, isNull);
    expect(await tokens.loadSession(), isNull);
  });

  test('sends the code when given', () async {
    final d = await service((_) => http.Response('', 204));
    await d.deleteAccount(currentPassword: 'pw', otp: '123456');
    expect(jsonDecode(sent.single.body), {'current_password': 'pw', 'otp': '123456'});
  });

  for (final (status, code) in [
    (403, 'invalid_credentials'),
    (401, 'otp_required'),
    (401, 'invalid_otp'),
  ]) {
    test('$status $code is thrown, keeps the session and does not sign out', () async {
      final d = await service((_) => error(status, code));
      var expired = 0;
      final sub = d.onSessionExpired.listen((_) => expired++);
      await expectLater(
        d.deleteAccount(currentPassword: 'pw'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', code).having((e) => e.status, 'status', status)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(expired, 0, reason: 'a wrong password or code is not an expired session');
      expect(d.session?.token, 'tok');
      expect(await tokens.loadSession(), isNotNull);
      await sub.cancel();
    });
  }

  test('any other 401 still ends the session', () async {
    final d = await service((_) => error(401, 'unauthorized'));
    var expired = 0;
    final sub = d.onSessionExpired.listen((_) => expired++);
    await expectLater(d.deleteAccount(currentPassword: 'pw'), throwsA(isA<ApiException>()));
    await Future<void>.delayed(Duration.zero);
    expect(expired, 1);
    await sub.cancel();
  });
}
