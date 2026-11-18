import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/invites/invites.dart';

void main() {
  const token = 'AbCdEfGhIjKlMnOpQrStUv';

  test('invite tokens from every link form', () {
    expect(inviteTokenFrom('securelyhello://invite/$token'), token);
    expect(inviteTokenFrom('https://hello.example/i/$token'), token);
    expect(inviteTokenFrom('  https://hello.example/i/$token/  '), token);
    expect(inviteTokenFrom(token), token);
    expect(inviteTokenFrom("Let's chat. Open this to add me (@mira): https://hello.example/i/$token"),
        token,
        reason: 'people paste the whole shared message');
  });

  test('anything else is not an invite', () {
    expect(inviteTokenFrom('https://hello.example/x/$token'), isNull);
    expect(inviteTokenFrom('securelyhello://verify/$token'), isNull);
    expect(inviteTokenFrom('https://hello.example/i/short'), isNull);
    expect(inviteTokenFrom('https://hello.example/i/${token}x'), isNull);
    expect(inviteTokenFrom('javascript:alert(1)'), isNull);
    expect(inviteTokenFrom(''), isNull);
    expect(inviteTokenFrom('see https://hello.example/i/${token}x'), isNull);
  });

  test('e-mail hashes match the server (server/src/invites.js)', () {
    expect(emailHash(' Alice@Example.TEST '), 'iWgvR2Jv3wgobNLUoiU+6GR5p05C+FrTMsrgo57ltDc=');
  });
}
