import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/l10n/app_localizations.dart';

Map<String, dynamic> arb(String code) =>
    jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync()) as Map<String, dynamic>;

Set<String> placeholders(String s) => RegExp(r'\{(\w+)\}').allMatches(s).map((m) => m[1]!).toSet();

void main() {
  final en = arb('en');

  for (final code in ['hi', 'gu']) {
    test('$code has every string, with the same placeholders', () {
      final other = arb(code);
      for (final key in en.keys.where((k) => !k.startsWith('@'))) {
        expect(other.containsKey(key), isTrue, reason: '$code is missing "$key"');
        expect(placeholders(other[key] as String), placeholders(en[key] as String),
            reason: '"$key" in $code');
        expect((other[key] as String).trim(), isNotEmpty);
      }
    });
  }

  test('Hindi is offered and used', () {
    expect(L10n.supportedLocales.map((l) => l.languageCode), containsAll(['en', 'hi']));
    final hi = lookupL10n(const Locale('hi'));
    expect(hi.logIn, 'लॉग इन करें');
    expect(hi.wrongPinLeft(3), contains('3'));
    expect(lookupL10n(const Locale('en')).logIn, 'Log in');
  });

  test('Gujarati is offered and used (1.1)', () {
    expect(L10n.supportedLocales.map((l) => l.languageCode), contains('gu'));
    final gu = lookupL10n(const Locale('gu'));
    expect(gu.logIn, 'લૉગ ઇન કરો');
    expect(gu.tabCalls, 'કૉલ');
    expect(gu.waitSeconds(9), contains('9'));
  });
}
