import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securelyhello/core/security/sensitive_clipboard.dart';

void main() {
  String? clip;

  setUp(() {
    clip = null;
    TestWidgetsFlutterBinding.ensureInitialized()
        .defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          clip = (call.arguments as Map)['text'] as String?;
          return null;
        case 'Clipboard.getData':
          return clip == null ? null : {'text': clip};
      }
      return null;
    });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('copies, then clears after 60 s', (tester) async {
    await SensitiveClipboard.copy('JBSWY3DPEHPK3PXP');
    expect(clip, 'JBSWY3DPEHPK3PXP');
    await tester.pump(const Duration(seconds: 59));
    expect(clip, 'JBSWY3DPEHPK3PXP');
    await tester.pump(const Duration(seconds: 2));
    expect(clip, isEmpty);
  });

  testWidgets('leaves something the user copied since then alone', (tester) async {
    await SensitiveClipboard.copy('recovery-1\nrecovery-2');
    clip = 'my own note';
    await tester.pump(const Duration(seconds: 61));
    expect(clip, 'my own note');
  });

  testWidgets('a later copy is not cleared by the earlier timer', (tester) async {
    await SensitiveClipboard.copy('first');
    await tester.pump(const Duration(seconds: 30));
    await SensitiveClipboard.copy('second');
    await tester.pump(const Duration(seconds: 31));
    expect(clip, 'second');
    await tester.pump(const Duration(seconds: 30));
    expect(clip, isEmpty);
  });

  test('clears after a minute by default', () {
    expect(SensitiveClipboard.clearAfter, const Duration(seconds: 60));
  });
}
