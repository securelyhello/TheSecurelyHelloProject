import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/networking/app_trust.dart';

// Regression: Android 7.0 has no ISRG Root X1, so it couldn't reach the
// server or the website (both Let's Encrypt). The app bundles the roots.
void main() {
  test('the bundled roots are exactly ISRG Root X1 and X2', () {
    final ders = RegExp(r'-----BEGIN CERTIFICATE-----([^-]+)-----END CERTIFICATE-----')
        .allMatches(AppTrust.isrgRootsPem)
        .map((m) => base64Decode(m.group(1)!.replaceAll(RegExp(r'\s'), '')))
        .toList();
    expect(ders.map((d) => sha256.convert(d).toString()).toList(), [
      '96bcec06264976f37460779acf28c5a7cfe8a3c0aae11a8ffcee05c0bddf08c6',
      '69729b8e15a86efc177a57afb7171dfc64add28c2fca8cf1507e34453ccb1470',
    ]);
  });

  test('a context with them builds even where they are already trusted', () {
    expect(AppTrust.build, returnsNormally);
    expect(AppTrust.httpClient(), isNotNull);
  });
}
