import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/security/proof_of_work.dart';

void main() {
  test('finds the same nonce as the server (server/src/spam.js solvePow)', () async {
    expect(await ProofOfWork.solve('signup', 'abc', 8), '354');
    expect(await ProofOfWork.solve('reset', 'xyz', 12), '419');
  });

  test('difficulty 0 needs no work', () async {
    expect(await ProofOfWork.solve('signup', 'abc', 0), '0');
  });

  test('leading zero bits', () {
    expect(ProofOfWork.leadingZeroBits([0, 0, 0x80]), 16);
    expect(ProofOfWork.leadingZeroBits([0x0f]), 4);
    expect(ProofOfWork.leadingZeroBits([0, 1]), 15);
  });

  test('the default difficulty takes seconds, not minutes', () async {
    final sw = Stopwatch()..start();
    await ProofOfWork.solve('signup', 'timing', 18);
    expect(sw.elapsed, lessThan(const Duration(seconds: 20)));
    // ignore: avoid_print
    print('18 bits: ${sw.elapsedMilliseconds} ms');
  });
}
