import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/features/chat/chat_quote.dart';

// Security review L8: a reply can't put words in someone else's mouth.
void main() {
  Message local({String conv = 'bob', String sender = 'me', String content = 'what I really said', bool deleted = false}) =>
      Message(
        id: 'm1',
        conversationId: conv,
        senderId: sender,
        content: content,
        timestamp: DateTime(2026),
        status: 'read',
        isFromMe: sender == 'me',
        deleted: deleted,
      );

  final claimed = {'id': 'm1', 'from': 'bob', 'preview': 'something I never said'};

  test('the local copy decides author and text', () {
    final q = resolveQuote(claimed, local(), conversationId: 'bob');
    expect(q.from, 'me');
    expect(q.text, 'what I really said');
  });

  test('without a local copy, what the sender claims', () {
    final q = resolveQuote(claimed, null, conversationId: 'bob');
    expect(q.from, 'bob');
    expect(q.text, 'something I never said');
  });

  test("a message from another chat is not pulled in", () {
    final q = resolveQuote(claimed, local(conv: 'carol', content: 'secret from carol chat'), conversationId: 'bob');
    expect(q.text, isNot(contains('secret')));
    expect(q.from, 'bob');
  });

  test('an attachment-only local copy keeps the preview text but its own author', () {
    final q = resolveQuote(claimed, local(content: ''), conversationId: 'bob');
    expect(q.from, 'me');
    expect(q.text, 'something I never said');
  });

  test('a deleted local copy keeps its own author', () {
    expect(resolveQuote(claimed, local(deleted: true), conversationId: 'bob').from, 'me');
  });
}
