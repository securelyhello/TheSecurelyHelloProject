import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/crypto/verify_code.dart';

void main() {
  const number = '12345 67890 12345 67890 12345 67890 12345 67890 12345 67890 12345 67890';

  test('a code shown by the contact matches on our side', () {
    final code = VerifyCode.encode(from: 'bob', to: 'alice', safetyNumber: number);
    expect(VerifyCode.check(code, me: 'alice', contact: 'bob', safetyNumber: number),
        VerifyResult.match);
  });

  test('a different number is a mismatch', () {
    final code = VerifyCode.encode(from: 'bob', to: 'alice', safetyNumber: number);
    expect(
        VerifyCode.check(code,
            me: 'alice', contact: 'bob', safetyNumber: number.replaceFirst('1', '9')),
        VerifyResult.mismatch);
  });

  test('a code from another pair or another app is rejected', () {
    final other = VerifyCode.encode(from: 'carol', to: 'alice', safetyNumber: number);
    expect(VerifyCode.check(other, me: 'alice', contact: 'bob', safetyNumber: number),
        VerifyResult.wrongPerson);
    final ours = VerifyCode.encode(from: 'alice', to: 'bob', safetyNumber: number);
    expect(VerifyCode.check(ours, me: 'alice', contact: 'bob', safetyNumber: number),
        VerifyResult.wrongPerson, reason: 'scanning your own code proves nothing');
    expect(VerifyCode.check('https://example.com', me: 'alice', contact: 'bob', safetyNumber: number),
        VerifyResult.notACode);
  });
}
