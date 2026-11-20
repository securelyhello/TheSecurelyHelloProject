import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/core/config/app_version.dart';
import 'package:securelyhello/features/whats_new/whats_new.dart';

void main() {
  test('AppVersion matches pubspec.yaml', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(line.trim(), 'version: ${AppVersion.name}+${AppVersion.code}');
  });

  test('no other file in lib/ hard-codes a version number', () {
    final literal = RegExp(r"'\d+\.\d+\.\d+'");
    final offenders = [
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') && !f.path.endsWith('core/config/app_version.dart') && literal.hasMatch(f.readAsStringSync()))
          f.path,
    ];
    expect(offenders, isEmpty);
  });

  group("What's new", () {
    test('shown once after an update', () async {
      SharedPreferences.setMockInitialValues({'whats_new_seen': '1.0.0'});
      expect(await WhatsNew.due(hadAccountBefore: true), isTrue);
      expect(await WhatsNew.due(hadAccountBefore: true), isFalse, reason: 'only once');
    });
    test('not after a fresh install (the welcome pages are enough)', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await WhatsNew.due(hadAccountBefore: false), isFalse);
      expect(await WhatsNew.due(hadAccountBefore: true), isFalse, reason: 'remembered as seen');
    });
  });
}
