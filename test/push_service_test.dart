import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/notifications/push_service.dart';

/// Fake FCM + server: hands out tokens in order and rejects the ones listed
/// in [taken] with 409 push_token_in_use.
class _Fake {
  final List<String?> tokens;
  final Set<String> taken;
  final Object? error;
  int _next = 0;
  int deletes = 0;
  final registered = <String>[];

  _Fake(this.tokens, {this.taken = const {}, this.error});

  Future<String?> getToken() async => tokens[_next.clamp(0, tokens.length - 1)];
  Future<void> deleteToken() async {
    deletes++;
    _next++;
  }

  Future<void> register(String token) async {
    registered.add(token);
    if (error != null) throw error!;
    if (taken.contains(token)) {
      throw const ApiException(409, 'push_token_in_use', 'Another account uses this push token');
    }
  }

  Future<bool> run() => PushService.registerToken(
        getToken: getToken,
        deleteToken: deleteToken,
        register: register,
      );
}

void main() {
  group('PushService.registerToken', () {
    test('registers the current token', () async {
      final fake = _Fake(['tok-a']);
      expect(await fake.run(), isTrue);
      expect(fake.registered, ['tok-a']);
      expect(fake.deletes, 0);
    });

    test('push_token_in_use: rotates the FCM token and registers once more', () async {
      final fake = _Fake(['tok-old', 'tok-new'], taken: {'tok-old'});
      expect(await fake.run(), isTrue);
      expect(fake.deletes, 1);
      expect(fake.registered, ['tok-old', 'tok-new']);
    });

    test('gives up after one retry instead of looping, without throwing', () async {
      final fake = _Fake(['tok-1', 'tok-2', 'tok-3'], taken: {'tok-1', 'tok-2', 'tok-3'});
      expect(await fake.run(), isFalse);
      expect(fake.deletes, 1);
      expect(fake.registered, ['tok-1', 'tok-2']);
    });

    test('other errors do not rotate the token and do not throw', () async {
      final fake = _Fake(['tok-a'], error: const ApiException(500, 'server_error', 'boom'));
      expect(await fake.run(), isFalse);
      expect(fake.deletes, 0);
      expect(fake.registered, ['tok-a']);

      final offline = _Fake(['tok-a'], error: const NetworkException('offline'));
      expect(await offline.run(), isFalse);
      expect(offline.deletes, 0);
    });

    test('no token yet: nothing is registered', () async {
      final fake = _Fake([null]);
      expect(await fake.run(), isFalse);
      expect(fake.registered, isEmpty);
    });

    test('no token after rotating: stops', () async {
      final fake = _Fake(['tok-old', null], taken: {'tok-old'});
      expect(await fake.run(), isFalse);
      expect(fake.registered, ['tok-old']);
    });
  });
}
