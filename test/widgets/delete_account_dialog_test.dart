import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/features/settings/widgets/delete_account_dialog.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';

void main() {
  /// Opens the dialog from a button; [result] receives what it popped with.
  Future<List<bool?>> open(
    WidgetTester t, {
    required Future<bool> twoFactorEnabled,
    required DeleteAccountAttempt onDelete,
  }) async {
    final result = <bool?>[];
    await t.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => result.add(await showDialog<bool>(
              context: context,
              builder: (_) => DeleteAccountDialog(twoFactorEnabled: twoFactorEnabled, onDelete: onDelete),
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    return result;
  }

  final confirm = find.byKey(const ValueKey('delete-confirm'));
  final password = find.byKey(const ValueKey('delete-password'));
  final otp = find.byKey(const ValueKey('delete-otp'));
  final submit = find.byKey(const ValueKey('delete-submit'));

  bool enabled(WidgetTester t) => t.widget<FilledButton>(submit).onPressed != null;
  TextField field(WidgetTester t, Finder f) => t.widget<TextField>(f);

  testWidgets('needs DELETE and the password; the password is obscured', (t) async {
    final calls = <(String, String?)>[];
    final result = await open(t, twoFactorEnabled: Future.value(false), onDelete: (pw, code) async {
      calls.add((pw, code));
      return null;
    });
    expect(otp, findsNothing, reason: 'no code field without 2FA');
    expect(field(t, password).obscureText, isTrue);
    expect(enabled(t), isFalse);
    await t.enterText(confirm, 'DELETE');
    await t.pump();
    expect(enabled(t), isFalse, reason: 'password still missing');
    await t.enterText(password, 'my password');
    await t.pump();
    expect(enabled(t), isTrue);
    await t.tap(submit);
    await t.pumpAndSettle();
    expect(calls, [('my password', null)]);
    expect(result, [true]);
  });

  testWidgets('with 2FA on it asks for a 6-digit code', (t) async {
    final calls = <(String, String?)>[];
    await open(t, twoFactorEnabled: Future.value(true), onDelete: (pw, code) async {
      calls.add((pw, code));
      return null;
    });
    expect(otp, findsOneWidget);
    await t.enterText(confirm, 'DELETE');
    await t.enterText(password, 'pw');
    await t.enterText(otp, '12345');
    await t.pump();
    expect(enabled(t), isFalse, reason: 'five digits are not a code');
    await t.enterText(otp, '123456');
    await t.pump();
    expect(enabled(t), isTrue);
    await t.tap(submit);
    await t.pumpAndSettle();
    expect(calls, [('pw', '123456')]);
  });

  testWidgets('a wrong password is shown inline and the dialog stays', (t) async {
    final result = await open(t, twoFactorEnabled: Future.value(false), onDelete: (_, _) async {
      return const DeleteAccountFailure('invalid_credentials', 'Current password is wrong');
    });
    await t.enterText(confirm, 'DELETE');
    await t.enterText(password, 'wrong');
    await t.pump();
    await t.tap(submit);
    await t.pumpAndSettle();
    expect(result, isEmpty, reason: 'still open');
    expect(find.byType(DeleteAccountDialog), findsOneWidget);
    expect(find.text('Wrong password'), findsOneWidget);
  });

  testWidgets('otp_required reveals the code field; invalid_otp is shown on it', (t) async {
    var answer = const DeleteAccountFailure('otp_required', 'Enter the code');
    final calls = <(String, String?)>[];
    final status = Completer<bool>();
    final result = await open(t, twoFactorEnabled: status.future, onDelete: (pw, code) async {
      calls.add((pw, code));
      return answer;
    });
    status.completeError(Exception('2FA status could not be loaded'));
    await t.pump();
    expect(otp, findsNothing);
    await t.enterText(confirm, 'DELETE');
    await t.enterText(password, 'pw');
    await t.pump();
    await t.tap(submit);
    await t.pumpAndSettle();
    expect(otp, findsOneWidget);
    expect(find.text('Enter the code from your authenticator app'), findsOneWidget);
    expect(enabled(t), isFalse, reason: 'the code is now required');

    answer = const DeleteAccountFailure('invalid_otp', 'That code is wrong');
    await t.enterText(otp, '000000');
    await t.pump();
    await t.tap(submit);
    await t.pumpAndSettle();
    expect(find.text('That code is wrong or was already used'), findsOneWidget);
    expect(result, isEmpty);
    expect(calls.last, ('pw', '000000'));
  });

  testWidgets('other failures are shown in the dialog', (t) async {
    await open(t, twoFactorEnabled: Future.value(false), onDelete: (_, _) async {
      return const DeleteAccountFailure(null, "Can't reach the server.");
    });
    await t.enterText(confirm, 'DELETE');
    await t.enterText(password, 'pw');
    await t.pump();
    await t.tap(submit);
    await t.pumpAndSettle();
    expect(find.text("Can't reach the server."), findsOneWidget);
  });

  testWidgets('cancel pops false without deleting', (t) async {
    var called = false;
    final result = await open(t, twoFactorEnabled: Future.value(false), onDelete: (_, _) async {
      called = true;
      return null;
    });
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(result, [false]);
    expect(called, isFalse);
  });
}
