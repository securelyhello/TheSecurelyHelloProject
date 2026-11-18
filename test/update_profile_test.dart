import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';

/// PATCH /api/me: a username change needs the password (and 2FA code) again.
void main() {
  late List<http.Request> sent;

  Future<DirectoryService> service() async {
    sent = [];
    final tokens = SecureKeyStore(storage: MemorySecretStorage());
    await tokens.saveSession(const StoredSession(token: 'tok', userId: 'me'));
    final d = DirectoryService(
      baseUrl: 'https://fake.invalid',
      tokenStore: tokens,
      httpClient: MockClient((req) async {
        sent.add(req);
        return http.Response('{}', 200, headers: {'content-type': 'application/json'});
      }),
    );
    await d.restoreSession();
    return d;
  }

  test('a username change sends the current password', () async {
    final d = await service();
    await d.updateProfile(username: 'new_name', currentPassword: 'pw 123');
    expect(sent.single.method, 'PATCH');
    expect(sent.single.url.path, '/api/me');
    expect(jsonDecode(sent.single.body), {'username': 'new_name', 'current_password': 'pw 123'});
  });

  test('...and the two-step code when given', () async {
    final d = await service();
    await d.updateProfile(username: 'new_name', currentPassword: 'pw', otp: '123456');
    expect(jsonDecode(sent.single.body),
        {'username': 'new_name', 'current_password': 'pw', 'otp': '123456'});
  });

  test('other fields send no credentials', () async {
    final d = await service();
    await d.updateProfile(displayName: 'Ann', discoverable: true);
    expect(jsonDecode(sent.single.body), {'display_name': 'Ann', 'discoverable': true});
  });

  test('a username without the password (or credentials without a username) is a bug', () async {
    final d = await service();
    expect(() => d.updateProfile(username: 'x_name'), throwsA(isA<AssertionError>()));
    expect(() => d.updateProfile(displayName: 'Ann', currentPassword: 'pw'), throwsA(isA<AssertionError>()));
    expect(() => d.updateProfile(displayName: 'Ann', otp: '123456'), throwsA(isA<AssertionError>()));
    expect(sent, isEmpty);
  });
}
