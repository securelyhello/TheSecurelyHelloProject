import 'package:flutter_test/flutter_test.dart';
import 'package:securelyhello/core/config/app_config.dart';

void main() {
  String resolve({
    String defined = '',
    String? fromProcess,
    String? fromEnv,
    bool isRelease = false,
    bool isAndroid = false,
  }) =>
      AppConfig.resolveBaseUrl(
        defined: defined,
        fromProcess: fromProcess,
        fromEnv: fromEnv,
        isRelease: isRelease,
        isAndroid: isAndroid,
      );

  group('AppConfig.resolveBaseUrl', () {
    test('release defaults to production when nothing is set', () {
      expect(resolve(isRelease: true), 'https://api.hello.thenn.in');
      expect(resolve(isRelease: true, isAndroid: true),
          'https://api.hello.thenn.in');
    });

    test('empty or blank values count as unset in release', () {
      expect(resolve(isRelease: true, fromEnv: '', fromProcess: '  '),
          AppConfig.productionBaseUrl);
    });

    test('debug defaults to the local dev server', () {
      expect(resolve(), 'http://127.0.0.1:8787');
      expect(resolve(isAndroid: true), 'http://10.0.2.2:8787');
      expect(resolve(fromEnv: ''), 'http://127.0.0.1:8787');
    });

    test('precedence: dart-define, then process env, then .env', () {
      expect(
          resolve(
              defined: 'https://a.example',
              fromProcess: 'https://b.example',
              fromEnv: 'https://c.example',
              isRelease: true),
          'https://a.example');
      expect(
          resolve(fromProcess: 'https://b.example', fromEnv: 'https://c.example'),
          'https://b.example');
      expect(resolve(fromEnv: ' https://c.example/ ', isRelease: true),
          'https://c.example');
    });
  });
}
