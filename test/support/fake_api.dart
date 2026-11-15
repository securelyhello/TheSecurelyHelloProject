import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';

/// One request the fake server saw.
class SeenRequest {
  final String method;
  final String path;
  final Map<String, String> headers;
  final dynamic body;
  const SeenRequest(this.method, this.path, this.headers, this.body);

  String get route => '$method $path';
  bool get hasBearer =>
      (headers['authorization'] ?? headers['Authorization'] ?? '').startsWith(
        'Bearer ',
      );
}

typedef FakeHandler = http.Response Function(SeenRequest req);

/// A scripted Securely Hello server behind [MockClient].
///
/// Register handlers with [on]; unhandled routes answer 404 `not_found`.
class FakeApi {
  final Map<String, FakeHandler> _handlers = {};
  final List<SeenRequest> requests = [];

  void on(String method, String path, FakeHandler handler) =>
      _handlers['$method $path'] = handler;

  List<SeenRequest> seen(String method, String path) =>
      requests.where((r) => r.route == '$method $path').toList();

  late final MockClient client = MockClient((request) async {
    dynamic body;
    if (request.body.isNotEmpty) {
      try {
        body = jsonDecode(request.body);
      } catch (_) {
        body = request.body;
      }
    }
    final seen = SeenRequest(
      request.method,
      request.url.path,
      request.headers,
      body,
    );
    requests.add(seen);
    final handler = _handlers[seen.route];
    if (handler == null) {
      return json({'error': 'not_found', 'message': 'Not found'}, 404);
    }
    return handler(seen);
  });

  DirectoryService directory({SessionTokenStore? tokenStore}) =>
      DirectoryService(
        baseUrl: 'http://api.test',
        tokenStore:
            tokenStore ?? SecureKeyStore(storage: MemorySecretStorage()),
        httpClient: client,
      );

  static http.Response json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  static http.Response empty([int status = 204]) => http.Response('', status);

  static http.Response error(int status, String code, String message) =>
      json({'error': code, 'message': message}, status);
}

/// A user record as the server returns it.
Map<String, dynamic> fakeUser({
  String id = 'u-1',
  String email = 'alice@example.com',
  bool emailVerified = false,
  String? signingKey,
  String? encryptionKey,
}) => {
  'user_id': id,
  'email': email,
  'username': 'alice',
  'display_name': 'Alice',
  'signing_public_key': signingKey,
  'encryption_public_key': encryptionKey,
  'email_verified': emailVerified,
};

/// A [LocalStorage] on a throwaway directory using SQLite FFI.
LocalStorage tempLocalStorage() {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('sh_test_');
  return LocalStorage(
    databaseFactory: databaseFactoryFfiNoIsolate,
    baseDirectory: () async => dir.path,
  );
}
