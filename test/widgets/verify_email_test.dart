import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';
import 'package:securelyhello/features/settings/widgets/verify_email_dialog.dart';
import 'package:securelyhello/shared/theme/app_palette.dart';

import '../support/fake_api.dart';

class _Harness {
  final api = FakeApi();
  late final AuthProvider auth;
  bool verified;

  _Harness({this.verified = false}) {
    final keyStore = SecureKeyStore(storage: MemorySecretStorage());
    auth = AuthProvider(
      directoryService: api.directory(tokenStore: keyStore),
      localStorage: tempLocalStorage(),
      keyStore: keyStore,
    );
    api
      ..on(
        'POST',
        '/api/auth/signin',
        (_) => FakeApi.json({
          'token': 'tok',
          'user': fakeUser(emailVerified: verified),
        }),
      )
      ..on('PUT', '/api/me/keys', (_) => FakeApi.empty())
      ..on(
        'POST',
        '/api/auth/request-verification',
        (_) => FakeApi.json({'ok': true}),
      )
      ..on('POST', '/api/auth/verify-email', (r) {
        if (r.body['code'] != '654321') {
          return FakeApi.error(400, 'invalid_code', 'Invalid code');
        }
        verified = true;
        return FakeApi.json(fakeUser(emailVerified: true));
      });
  }

  Future<void> start(WidgetTester tester) async {
    // Sign-in opens a real SQLite file: run it outside the fake clock.
    await tester.runAsync(
      () => auth.signIn(email: 'alice@example.com', password: 'password123'),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: auth,
        child: MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            extensions: const [AppPalette.dark],
          ),
          home: const Scaffold(body: Column(children: [VerifyEmailBanner()])),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Finder get _codeField => find.widgetWithText(TextField, '6-digit code');

Future<void> _openAndSend(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'Verify'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('banner is hidden once the email is verified', (tester) async {
    final h = _Harness(verified: true);
    await h.start(tester);
    expect(find.text('Verify your email'), findsNothing);
  });

  testWidgets('banner shows for an unverified email', (tester) async {
    final h = _Harness();
    await h.start(tester);
    expect(find.text('Verify your email'), findsOneWidget);
  });

  testWidgets('dialog names the address and sends a code', (tester) async {
    final h = _Harness();
    await h.start(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Verify'));
    await tester.pumpAndSettle();
    expect(find.textContaining('alice@example.com'), findsWidgets);
    expect(_codeField, findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    expect(h.api.seen('POST', '/api/auth/request-verification'), hasLength(1));
    expect(_codeField, findsOneWidget);
  });

  testWidgets('correct code verifies, closes and hides the banner', (
    tester,
  ) async {
    final h = _Harness();
    await h.start(tester);
    await _openAndSend(tester);
    await tester.enterText(_codeField, '654321');
    await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
    await tester.pumpAndSettle();

    expect(h.api.seen('POST', '/api/auth/verify-email').single.body, {
      'code': '654321',
    });
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Email verified'), findsOneWidget);
    expect(find.text('Verify your email'), findsNothing);
    expect(h.auth.emailVerified, isTrue);
  });

  testWidgets('malformed code is rejected locally', (tester) async {
    final h = _Harness();
    await h.start(tester);
    await _openAndSend(tester);
    await tester.enterText(_codeField, '12');
    await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the 6-digit code'), findsOneWidget);
    expect(h.api.seen('POST', '/api/auth/verify-email'), isEmpty);
  });

  testWidgets('wrong code shows the error and keeps the dialog', (
    tester,
  ) async {
    final h = _Harness();
    await h.start(tester);
    await _openAndSend(tester);
    await tester.enterText(_codeField, '111111');
    await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
    await tester.pumpAndSettle();
    expect(find.textContaining('wrong or has expired'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(h.auth.emailVerified, isFalse);
  });

  testWidgets('sending failure (503) is shown inline', (tester) async {
    final h = _Harness();
    h.api.on(
      'POST',
      '/api/auth/request-verification',
      (_) => FakeApi.error(503, 'unavailable', 'x'),
    );
    await h.start(tester);
    await _openAndSend(tester);
    expect(find.textContaining('later'), findsOneWidget);
    expect(_codeField, findsNothing);
  });

  testWidgets('already verified (409) closes with success', (tester) async {
    final h = _Harness();
    h.api.on(
      'POST',
      '/api/auth/request-verification',
      (_) => FakeApi.error(409, 'already_verified', 'Already verified'),
    );
    await h.start(tester);
    await _openAndSend(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Email verified'), findsOneWidget);
    expect(find.text('Verify your email'), findsNothing);
  });

  testWidgets('resend has a cooldown', (tester) async {
    final h = _Harness();
    await h.start(tester);
    await _openAndSend(tester);
    Finder resend() => find.ancestor(
      of: find.textContaining('Resend'),
      matching: find.byType(TextButton),
    );
    expect(tester.widget<TextButton>(resend()).onPressed, isNull);
    await tester.pump(const Duration(seconds: 61));
    expect(tester.widget<TextButton>(resend()).onPressed, isNotNull);
    await tester.tap(resend());
    await tester.pumpAndSettle();
    expect(h.api.seen('POST', '/api/auth/request-verification'), hasLength(2));
  });

  testWidgets('cancel closes without verifying', (tester) async {
    final h = _Harness();
    await h.start(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Verify'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Verify your email'), findsOneWidget);
  });
}
