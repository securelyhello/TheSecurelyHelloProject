import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/chat/chat_service.dart';

void main() {
  group('ChatService.previewText', () {
    String preview(Object? name, [String text = '']) =>
        ChatService.previewText(text, {'name': name, 'mime': 'application/pdf'});

    test('shows ordinary file names as sent', () {
      expect(preview('report.pdf'), '📎 report.pdf');
      expect(preview('report.pdf', 'see this'), '📎 report.pdf · see this');
    });

    test('sanitises names from contacts (bidi, control characters, paths)', () {
      expect(preview('invoice\u202Efdp.exe'), '📎 invoicefdp.exe');
      expect(preview('a\nb\u0000c.txt'), '📎 abc.txt');
      expect(preview('../../etc/passwd'), '📎 passwd');
      expect(preview('x' * 5000), '📎 ${'x' * 120}');
    });

    test('falls back to "File" when there is no name', () {
      expect(preview(null), '📎 File');
      expect(ChatService.previewText('', {'mime': 'text/plain'}), '📎 File');
    });

    test('images and plain text are unchanged', () {
      expect(ChatService.previewText('hi', null), 'hi');
      expect(ChatService.previewText('', {'name': 'x\u202E.png', 'mime': 'image/png'}), '📷 Photo');
    });
  });
}
