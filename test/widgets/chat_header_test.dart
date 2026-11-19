import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/chat/widgets/chat_header.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/connection_badge.dart';

// Regression: on a small phone with large text the "online" / "last seen"
// line was squeezed to nothing by the connection badge.
void main() {
  testWidgets('presence stays readable in a narrow header with large text', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 190,
              child: ChatHeader(
                contactUserId: 'u1',
                contact: const Contact(
                    userId: 'u1',
                    username: 'mira',
                    displayName: 'Mira Kapoor-Venkataraghavan Subramaniam',
                    isOnline: true),
                contactsLoading: false,
                isTyping: false,
                transport: PeerConnectionState.connected,
              ),
            ),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(t.getSize(find.text('online')).width, greaterThan(40));
  });
}
