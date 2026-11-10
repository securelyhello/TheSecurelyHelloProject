import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/features/chat/widgets/composer.dart';
import 'package:securelyhello/features/chat/widgets/conversation_tile.dart';
import 'package:securelyhello/shared/theme/app_palette.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/message_bubble.dart';
import 'package:securelyhello/shared/widgets/message_status_icon.dart';

/// Plain Material theme (no Google Fonts, so no network in tests) carrying
/// the app's palette extension.
Widget _host(Widget child) => MaterialApp(
  theme: ThemeData(
    brightness: Brightness.dark,
    extensions: const [AppPalette.dark],
  ),
  home: Scaffold(body: child),
);

void main() {
  group('MessageBubble', () {
    testWidgets('outgoing shows text, time and read status', (tester) async {
      await tester.pumpWidget(
        _host(
          MessageBubble(
            message: 'Hello there',
            timestamp: DateTime(2025, 1, 1, 9, 7),
            isSent: true,
            status: MessageStatus.read,
          ),
        ),
      );
      expect(
        find.textContaining('Hello there', findRichText: true),
        findsOneWidget,
      );
      // Follows the device's 12/24-hour setting (12-hour in tests).
      expect(find.textContaining('9:07'), findsOneWidget);
      expect(find.bySemanticsLabel('Read'), findsOneWidget);
    });

    testWidgets('failed message offers retry and reports taps', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          MessageBubble(
            message: 'oops',
            timestamp: DateTime(2025, 1, 1, 9, 7),
            isSent: true,
            status: MessageStatus.failed,
            onTap: () => taps++,
          ),
        ),
      );
      expect(find.text('Not sent · Tap to retry'), findsOneWidget);
      // The time overlay sits on top of the text's centre; that's fine, the
      // whole bubble is the tap target.
      await tester.tap(
        find.textContaining('oops', findRichText: true),
        warnIfMissed: false,
      );
      expect(taps, 1);
    });

    testWidgets('incoming message has no status icon', (tester) async {
      await tester.pumpWidget(
        _host(
          MessageBubble(
            message: 'Hi',
            timestamp: DateTime(2025, 1, 1, 18, 0),
            isSent: false,
          ),
        ),
      );
      expect(find.byType(MessageStatusIcon), findsNothing);
    });

    test('status strings map to ticks', () {
      expect(MessageStatus.fromString('read'), MessageStatus.read);
      expect(MessageStatus.fromString('delivered'), MessageStatus.delivered);
      expect(MessageStatus.fromString('sent'), MessageStatus.sent);
      expect(MessageStatus.fromString('failed'), MessageStatus.failed);
      expect(MessageStatus.fromString('sending'), MessageStatus.sending);
      expect(MessageStatus.fromString(null), MessageStatus.sending);
    });
  });

  group('ConversationTile', () {
    testWidgets('shows name, preview, unread badge and own tick', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          ConversationTile(
            contactUserId: 'u1',
            name: 'Ada Lovelace',
            isOnline: true,
            lastMessage: 'See you\ntomorrow',
            lastMessageTime: DateTime.now(),
            unreadCount: 3,
            lastOwnStatus: MessageStatus.delivered,
          ),
        ),
      );
      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('See you tomorrow'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.bySemanticsLabel('Delivered'), findsOneWidget);
    });

    testWidgets('typing replaces the preview', (tester) async {
      await tester.pumpWidget(
        _host(
          const ConversationTile(
            contactUserId: 'u1',
            name: 'Ada',
            isOnline: false,
            lastMessage: 'old text',
            lastMessageTime: null,
            unreadCount: 0,
            isTyping: true,
          ),
        ),
      );
      expect(find.text('typing'), findsOneWidget);
      expect(find.text('old text'), findsNothing);
    });
  });

  group('Composer', () {
    testWidgets('send button appears with text and sends', (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      var sent = 0;
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              const Spacer(),
              Composer(
                controller: controller,
                focusNode: focus,
                onSend: () => sent++,
              ),
            ],
          ),
        ),
      );
      expect(find.byTooltip('Send'), findsNothing);
      expect(find.byTooltip('Send (Enter)'), findsNothing);

      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pumpAndSettle();
      final send = find.bySemanticsLabel('Send');
      expect(send, findsOneWidget);
      await tester.tap(send);
      expect(sent, 1);

      controller.dispose();
      focus.dispose();
    });
  });

  test('avatar initials', () {
    expect(AvatarWidget.initialsOf('Ada Lovelace'), 'AL');
    expect(AvatarWidget.initialsOf('ada'), 'A');
    expect(AvatarWidget.initialsOf('  '), '?');
    expect(AvatarWidget.initialsOf('Jean Paul Sartre'), 'JS');
  });
}
