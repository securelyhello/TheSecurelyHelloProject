import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';
import 'package:securelyhello/features/auth/screens/forgot_password_screen.dart';
import 'package:securelyhello/features/auth/screens/login_screen.dart';
import 'package:securelyhello/shared/theme/app_palette.dart';

import '../support/fake_api.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('"Forgot password?" opens the reset flow and prefills on return',
      (tester) async {
    final api = FakeApi()
      ..on('POST', '/api/auth/request-password-reset',
          (_) => FakeApi.json({'ok': true}))
      ..on('POST', '/api/auth/reset-password', (_) => FakeApi.empty());
    final keyStore = SecureKeyStore(storage: MemorySecretStorage());
    final auth = AuthProvider(
      directoryService: api.directory(tokenStore: keyStore),
      localStorage: tempLocalStorage(),
      keyStore: keyStore,
    );
    String? openedWith;

    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: auth,
      child: MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          extensions: const [AppPalette.dark],
        ),
        home: const LoginScreen(),
        onGenerateRoute: (settings) {
          if (settings.name != '/forgot-password') return null;
          openedWith = settings.arguments as String?;
          return MaterialPageRoute<String>(
            builder: (_) => ForgotPasswordScreen(initialEmail: openedWith),
            settings: settings,
          );
        },
      ),
    ));
    await tester.pump();

    await tester.enterText(
        find.widgetWithText(TextField, 'Email'), 'alice@example.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'old-guess');
    await tester.ensureVisible(find.text('Forgot password?'));
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    expect(openedWith, 'alice@example.com');
    expect(find.byType(ForgotPasswordScreen), findsOneWidget);

    // Change the address in the reset flow; login should pick it up.
    await tester.enterText(
        find.widgetWithText(TextField, 'Email'), 'alice2@example.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, '6-digit code'), '123456');
    await tester.enterText(
        find.widgetWithText(TextField, 'New password'), 'new-password');
    await tester.enterText(
        find.widgetWithText(TextField, 'Repeat new password'), 'new-password');
    final reset = find.widgetWithText(FilledButton, 'Reset password');
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();

    expect(find.byType(ForgotPasswordScreen), findsNothing);
    expect(find.text('alice2@example.com'), findsOneWidget);
    expect(find.text('old-guess'), findsNothing);
    expect(find.text('Password reset. Log in with your new password.'),
        findsOneWidget);
  });
}
