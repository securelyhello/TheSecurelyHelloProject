import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/networking/turn_credentials.dart';

import 'support/fake_api.dart';

const _stun = [
  {'urls': 'stun:stun.example.org:19302'},
];

const _staticTurn = {
  'urls': ['turn:static.example.org:3478'],
  'username': 'static',
  'credential': 'static-pw',
};

TurnCredentials _creds({String user = '1700000000:u-1', int ttl = 3600}) =>
    TurnCredentials(
      urls: const ['turn:turn.thenn.in:3478?transport=udp'],
      username: user,
      credential: 'c2VjcmV0',
      ttl: Duration(seconds: ttl),
    );

/// A controllable clock.
class _Clock {
  DateTime now = DateTime.utc(2026, 11, 15, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  group('DirectoryService.fetchTurnCredentials', () {
    Future<DirectoryService> signedIn(FakeApi api) async {
      api.on(
        'POST',
        '/api/auth/signin',
        (_) => FakeApi.json({'token': 'tok', 'user': fakeUser()}),
      );
      final dir = api.directory();
      await dir.signIn('alice@example.com', 'password123');
      return dir;
    }

    test(
      'GETs /api/turn with the bearer token and parses the answer',
      () async {
        final api = FakeApi()
          ..on(
            'GET',
            '/api/turn',
            (_) => FakeApi.json({
              'urls': [
                'turn:turn.thenn.in:3478?transport=udp',
                'turn:turn.thenn.in:3478?transport=tcp',
              ],
              'username': '1700000000:u-1',
              'credential': 'c2VjcmV0',
              'ttl': 86400,
            }),
          );
        final dir = await signedIn(api);
        final creds = await dir.fetchTurnCredentials();

        expect(api.seen('GET', '/api/turn').single.hasBearer, isTrue);
        expect(creds, isNotNull);
        expect(creds!.urls, hasLength(2));
        expect(creds.username, '1700000000:u-1');
        expect(creds.credential, 'c2VjcmV0');
        expect(creds.ttl, const Duration(seconds: 86400));
        expect(creds.toIceServer(), {
          'urls': [
            'turn:turn.thenn.in:3478?transport=udp',
            'turn:turn.thenn.in:3478?transport=tcp',
          ],
          'username': '1700000000:u-1',
          'credential': 'c2VjcmV0',
        });
      },
    );

    test('unconfigured server ({urls: [], ttl: 0}) yields null', () async {
      final api = FakeApi()
        ..on('GET', '/api/turn', (_) => FakeApi.json({'urls': [], 'ttl': 0}));
      final dir = await signedIn(api);
      expect(await dir.fetchTurnCredentials(), isNull);
    });

    test('malformed answer yields null rather than throwing', () async {
      final api = FakeApi()
        ..on(
          'GET',
          '/api/turn',
          (_) => FakeApi.json({'urls': 'nope', 'ttl': 'x'}),
        );
      final dir = await signedIn(api);
      expect(await dir.fetchTurnCredentials(), isNull);
    });

    test('requires a session', () async {
      final api = FakeApi();
      await expectLater(
        api.directory().fetchTurnCredentials(),
        throwsA(isA<ApiException>()),
      );
      expect(api.requests, isEmpty);
    });
  });

  group('TurnCredentialCache', () {
    late _Clock clock;
    late int fetches;

    setUp(() {
      clock = _Clock();
      fetches = 0;
    });

    TurnCredentialCache cache(
      Future<TurnCredentials?> Function() fetch, {
      List<Map<String, dynamic>> fallback = const [..._stun, _staticTurn],
      String? Function()? scope,
      Duration fetchTimeout = const Duration(seconds: 5),
    }) => TurnCredentialCache(
      fetch: () {
        fetches++;
        return fetch();
      },
      fallback: fallback,
      scope: scope,
      clock: clock.call,
      fetchTimeout: fetchTimeout,
    );

    test('merges the fetched server after the fallback servers', () async {
      final c = cache(() async => _creds());
      final servers = await c.iceServers();
      expect(servers, [..._stun, _staticTurn, _creds().toIceServer()]);
    });

    test('does not mutate the fallback list', () async {
      final fallback = [..._stun];
      final c = cache(() async => _creds(), fallback: fallback);
      await c.iceServers();
      expect(fallback, _stun);
    });

    test('reuses cached credentials until 5 minutes before expiry', () async {
      final c = cache(() async => _creds(ttl: 3600));
      await c.iceServers();
      clock.advance(const Duration(minutes: 54));
      await c.iceServers();
      expect(fetches, 1);

      clock.advance(const Duration(minutes: 1, seconds: 1)); // 55m01s
      await c.iceServers();
      expect(fetches, 2);
    });

    test(
      'serves cached credentials immediately and refreshes in the background',
      () async {
        var calls = 0;
        final gate = Completer<TurnCredentials?>();
        final c = cache(() {
          calls++;
          return calls == 1 ? Future.value(_creds(user: '1:old')) : gate.future;
        });
        expect((await c.iceServers()).last['username'], '1:old');

        clock.advance(const Duration(minutes: 56)); // inside refresh window
        // Must not wait for the (stuck) refresh.
        final servers = await c.iceServers().timeout(
          const Duration(milliseconds: 200),
        );
        expect(servers.last['username'], '1:old');
        expect(fetches, 2, reason: 'refresh started');

        // Further calls while the refresh is in flight neither wait nor
        // start another fetch.
        await c.iceServers().timeout(const Duration(milliseconds: 200));
        expect(fetches, 2);

        gate.complete(_creds(user: '1:new'));
        await Future<void>.delayed(Duration.zero);
        expect((await c.iceServers()).last['username'], '1:new');
        expect(fetches, 2);
      },
    );

    test(
      'a background refresh that fails is not awaited and backs off',
      () async {
        var fail = false;
        final c = cache(() async {
          if (fail) throw const NetworkException('offline');
          return _creds(ttl: 3600);
        });
        await c.iceServers();
        fail = true;
        clock.advance(const Duration(minutes: 56));
        expect((await c.iceServers()).last, _creds().toIceServer());
        await Future<void>.delayed(Duration.zero);
        await c.iceServers();
        expect(
          fetches,
          2,
          reason: 'backoff after the failed background refresh',
        );
      },
    );

    test(
      'without usable credentials and no backoff, waits for the fetch',
      () async {
        final gate = Completer<TurnCredentials?>();
        final c = cache(() => gate.future);
        var done = false;
        final pending = c.iceServers().then((s) {
          done = true;
          return s;
        });
        await Future<void>.delayed(Duration.zero);
        expect(done, isFalse, reason: 'first call waits for credentials');
        gate.complete(_creds());
        expect((await pending).last, _creds().toIceServer());
      },
    );

    test(
      'expired credentials with a background refresh in flight wait for it',
      () async {
        var calls = 0;
        final gate = Completer<TurnCredentials?>();
        final c = cache(() {
          calls++;
          return calls == 1 ? Future.value(_creds(ttl: 600)) : gate.future;
        });
        await c.iceServers();
        clock.advance(const Duration(minutes: 6)); // refresh window
        await c.iceServers(); // starts the background refresh
        clock.advance(const Duration(minutes: 5)); // now expired
        final pending = c.iceServers();
        gate.complete(_creds(user: '1:new'));
        expect((await pending).last['username'], '1:new');
        expect(fetches, 2);
      },
    );

    test('during an unconfigured/failure backoff nothing is awaited', () async {
      final c = cache(() async => throw const NetworkException('offline'));
      await c.iceServers();
      final servers = await c.iceServers().timeout(
        const Duration(milliseconds: 200),
      );
      expect(servers, [..._stun, _staticTurn]);
      expect(fetches, 1);
    });

    test('short ttl refreshes at half-life instead of every call', () async {
      final c = cache(() async => _creds(ttl: 120));
      await c.iceServers();
      clock.advance(const Duration(seconds: 59));
      await c.iceServers();
      expect(fetches, 1);
      clock.advance(const Duration(seconds: 2));
      await c.iceServers();
      expect(fetches, 2);
    });

    test('fetch failure falls back silently to STUN + static TURN', () async {
      final c = cache(() async => throw const NetworkException('offline'));
      expect(await c.iceServers(), [..._stun, _staticTurn]);
    });

    test('a failed refresh keeps using still-valid credentials', () async {
      var fail = false;
      final c = cache(() async {
        if (fail) throw const ApiException(500, 'x', 'boom');
        return _creds(ttl: 3600);
      });
      await c.iceServers();
      fail = true;
      clock.advance(const Duration(minutes: 56)); // inside refresh window
      final servers = await c.iceServers();
      expect(servers.last, _creds().toIceServer());
    });

    test('expired credentials are never handed out', () async {
      var fail = false;
      final c = cache(() async {
        if (fail) throw const NetworkException('offline');
        return _creds(ttl: 600);
      });
      await c.iceServers();
      fail = true;
      clock.advance(const Duration(minutes: 11));
      expect(await c.iceServers(), [..._stun, _staticTurn]);
    });

    test('backs off after a failure instead of retrying every call', () async {
      final c = cache(() async => throw const NetworkException('offline'));
      await c.iceServers();
      await c.iceServers();
      expect(fetches, 1);
      clock.advance(const Duration(minutes: 2));
      await c.iceServers();
      expect(fetches, 2);
    });

    test('unconfigured server is rechecked only occasionally', () async {
      final c = cache(() async => null);
      expect(await c.iceServers(), [..._stun, _staticTurn]);
      clock.advance(const Duration(minutes: 5));
      await c.iceServers();
      expect(fetches, 1);
      clock.advance(const Duration(minutes: 11));
      await c.iceServers();
      expect(fetches, 2);
    });

    test('a slow server times out to the fallback', () async {
      final never = Completer<TurnCredentials?>();
      final c = cache(
        () => never.future,
        fetchTimeout: const Duration(milliseconds: 20),
      );
      expect(await c.iceServers(), [..._stun, _staticTurn]);
    });

    test('concurrent callers share one fetch', () async {
      final gate = Completer<TurnCredentials?>();
      final c = cache(() => gate.future);
      final a = c.iceServers();
      final b = c.iceServers();
      gate.complete(_creds());
      final results = await Future.wait([a, b]);
      expect(fetches, 1);
      expect(results[0].last, _creds().toIceServer());
      expect(results[1].last, _creds().toIceServer());
    });

    test('switching account drops the previous credentials', () async {
      var user = 'u-1';
      final c = cache(() async => _creds(user: '1:$user'), scope: () => user);
      expect((await c.iceServers()).last['username'], '1:u-1');
      user = 'u-2';
      expect((await c.iceServers()).last['username'], '1:u-2');
      expect(fetches, 2);
    });

    test('signed out (null scope) skips the fetch', () async {
      final c = cache(() async => _creds(), scope: () => null);
      expect(await c.iceServers(), [..._stun, _staticTurn]);
      expect(fetches, 0);
    });

    test('clear() forces a new fetch', () async {
      final c = cache(() async => _creds());
      await c.iceServers();
      c.clear();
      await c.iceServers();
      expect(fetches, 2);
    });

    test('prefetch warms the cache and never throws', () async {
      final ok = cache(() async => _creds());
      await ok.prefetch();
      await ok.iceServers();
      expect(fetches, 1);

      final bad = cache(() async => throw StateError('x'));
      await bad.prefetch();
    });

    test('works end to end against DirectoryService', () async {
      final api = FakeApi()
        ..on(
          'POST',
          '/api/auth/signin',
          (_) => FakeApi.json({'token': 'tok', 'user': fakeUser()}),
        )
        ..on(
          'GET',
          '/api/turn',
          (_) => FakeApi.json({
            'urls': ['turn:turn.thenn.in:3478'],
            'username': '9:u-1',
            'credential': 'abc',
            'ttl': 600,
          }),
        );
      final dir = api.directory();
      final c = TurnCredentialCache(
        fetch: dir.fetchTurnCredentials,
        fallback: _stun,
        scope: () => dir.myUserId,
        clock: clock.call,
      );
      // Not signed in yet: no request at all.
      expect(await c.iceServers(), _stun);
      expect(api.seen('GET', '/api/turn'), isEmpty);

      await dir.signIn('alice@example.com', 'password123');
      final servers = await c.iceServers();
      expect(servers, [
        ..._stun,
        {
          'urls': ['turn:turn.thenn.in:3478'],
          'username': '9:u-1',
          'credential': 'abc',
        },
      ]);
    });
  });
}
