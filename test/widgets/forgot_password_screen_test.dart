import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';
import 'package:securelyhello/features/auth/screens/forgot_password_screen.dart';
import 'package:securelyhello/shared/theme/app_palette.dart';

import '../support/fake_api.dart';

class _Harness {
  final api = FakeApi();
  late final AuthProvider auth;
  Object? popped = 'not popped';

  _Harness() {
    final keyStore = SecureKeyStore(storage: MemorySecretStorage());
    auth = AuthProvider(
      directoryService: api.directory(tokenStore: keyStore),
      localStorage: tempLocalStorage(),
      keyStore: keyStore,
    );
    api
      ..on(
        'POST',
        '/api/auth/request-password-reset',
        (_) => FakeApi.json({'ok': true}),
      )
      ..on('POST', '/api/auth/reset-password', (r) {
        if (r.body['code'] != '123456') {
          return FakeApi.error(400, 'invalid_code', 'Invalid code');
        }
        return FakeApi.empty();
      });
  }

  Widget app({String? initialEmail}) => ChangeNotifierProvider.value(
    value: auth,
    child: MaterialApp(
      theme: ThemeData(
        brightness: Brightness.dark,
        extensions: const [AppPalette.dark],
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                popped = await Navigator.of(context).push<String>(
                  MaterialPageRoute(
                    builder: (_) =>
                        ForgotPasswordScreen(initialEmail: initialEmail),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester tester, {String? initialEmail}) async {
    await tester.pumpWidget(app(initialEmail: initialEmail));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }
}

Finder _field(String label) => find.widgetWithText(TextField, label);

Finder get _resetButton => find.widgetWithText(FilledButton, 'Reset password');

Future<void> _toCodeStep(WidgetTester tester, _Harness h) async {
  await h.open(tester);
  await tester.enterText(_field('Email'), ' alice@example.com ');
  await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('step 1 validates the email before sending', (tester) async {
    final h = _Harness();
    await h.open(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your email'), findsOneWidget);

    await tester.enterText(_field('Email'), 'not-an-email');
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid email'), findsOneWidget);
    expect(h.api.requests, isEmpty);
  });

  testWidgets('prefills the email it was opened with', (tester) async {
    final h = _Harness();
    await h.open(tester, initialEmail: 'bob@example.com');
    expect(find.text('bob@example.com'), findsOneWidget);
  });

  testWidgets('sending shows neutral copy and the code step', (tester) async {
    final h = _Harness();
    await _toCodeStep(tester, h);

    final req = h.api.seen('POST', '/api/auth/request-password-reset').single;
    expect(req.body, {'email': 'alice@example.com'});
    expect(
      find.textContaining('If an account exists for this email'),
      findsOneWidget,
    );
    expect(_field('6-digit code'), findsOneWidget);
    expect(_field('New password'), findsOneWidget);
    expect(_field('Repeat new password'), findsOneWidget);
    expect(find.textContaining('stay on this device'), findsOneWidget);
  });

  testWidgets('rate limit on step 1 shows an error and stays', (tester) async {
    final h = _Harness();
    h.api.on(
      'POST',
      '/api/auth/request-password-reset',
      (_) => FakeApi.error(429, 'rate_limited', 'Too many requests'),
    );
    await _toCodeStep(tester, h);
    expect(find.text('Too many requests'), findsOneWidget);
    expect(_field('6-digit code'), findsNothing);
  });

  testWidgets('code step validates code and matching passwords', (
    tester,
  ) async {
    final h = _Harness();
    await _toCodeStep(tester, h);

    await tester.enterText(_field('6-digit code'), '12a');
    await tester.enterText(_field('New password'), 'short');
    await tester.enterText(_field('Repeat new password'), 'other');
    await tester.ensureVisible(_resetButton);
    await tester.tap(_resetButton);
    await tester.pumpAndSettle();

    expect(find.text('Enter the 6-digit code'), findsOneWidget);
    expect(find.text('At least 8 characters'), findsOneWidget);
    expect(find.text('Passwords do not match'), findsOneWidget);
    expect(h.api.seen('POST', '/api/auth/reset-password'), isEmpty);
  });

  testWidgets('wrong code shows the error and keeps the screen', (
    tester,
  ) async {
    final h = _Harness();
    await _toCodeStep(tester, h);
    await tester.enterText(_field('6-digit code'), '000000');
    await tester.enterText(_field('New password'), 'new-password');
    await tester.enterText(_field('Repeat new password'), 'new-password');
    await tester.ensureVisible(_resetButton);
    await tester.tap(_resetButton);
    await tester.pumpAndSettle();

    expect(find.textContaining('wrong or has expired'), findsOneWidget);
    expect(h.popped, 'not popped');
  });

  testWidgets('success pops with the email', (tester) async {
    final h = _Harness();
    await _toCodeStep(tester, h);
    await tester.enterText(_field('6-digit code'), '123456');
    await tester.enterText(_field('New password'), 'new-password');
    await tester.enterText(_field('Repeat new password'), 'new-password');
    await tester.ensureVisible(_resetButton);
    await tester.tap(_resetButton);
    await tester.pumpAndSettle();

    final req = h.api.seen('POST', '/api/auth/reset-password').single;
    expect(req.body, {
      'email': 'alice@example.com',
      'code': '123456',
      'new_password': 'new-password',
    });
    expect(h.popped, 'alice@example.com');
  });

  testWidgets('resend is disabled during the cooldown, then resends', (
    tester,
  ) async {
    final h = _Harness();
    await _toCodeStep(tester, h);

    Finder resend() => find.ancestor(
      of: find.textContaining('Resend code'),
      matching: find.byType(TextButton),
    );
    expect(tester.widget<TextButton>(resend()).onPressed, isNull);
    expect(find.textContaining('Resend code ('), findsOneWidget);

    await tester.pump(const Duration(seconds: 61));
    expect(tester.widget<TextButton>(resend()).onPressed, isNotNull);

    await tester.ensureVisible(resend());
    await tester.tap(resend());
    await tester.pumpAndSettle();
    expect(
      h.api.seen('POST', '/api/auth/request-password-reset'),
      hasLength(2),
    );
    expect(tester.widget<TextButton>(resend()).onPressed, isNull);
  });

  testWidgets('"Use a different email" returns to step 1', (tester) async {
    final h = _Harness();
    await _toCodeStep(tester, h);
    await tester.ensureVisible(find.text('Use a different email'));
    await tester.tap(find.text('Use a different email'));
    await tester.pumpAndSettle();
    expect(_field('Email'), findsOneWidget);
    expect(_field('6-digit code'), findsNothing);
  });
}
