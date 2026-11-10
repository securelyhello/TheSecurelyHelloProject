import 'package:flutter/material.dart';

/// Provided by [HomeScreen] when it shows the two-pane (wide) layout, so the
/// lists can open a conversation in the right-hand pane instead of pushing
/// the `/chat` route.
class TwoPaneScope extends InheritedWidget {
  const TwoPaneScope({
    super.key,
    required this.selectedContactId,
    required this.onOpenChat,
    required this.onCloseChat,
    required super.child,
  });

  /// Contact whose conversation is open in the right pane, if any.
  final String? selectedContactId;
  final ValueChanged<String> onOpenChat;
  final VoidCallback onCloseChat;

  static TwoPaneScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TwoPaneScope>();

  @override
  bool updateShouldNotify(TwoPaneScope oldWidget) =>
      selectedContactId != oldWidget.selectedContactId;
}

/// Opens the conversation with [contactUserId]: in the right pane on wide
/// windows, otherwise by pushing the `/chat` route.
void openChat(BuildContext context, String contactUserId) {
  final scope = TwoPaneScope.maybeOf(context);
  if (scope != null) {
    scope.onOpenChat(contactUserId);
  } else {
    Navigator.pushNamed(context, '/chat', arguments: contactUserId);
  }
}

/// Closes the conversation with [contactUserId] if it is currently shown
/// (used after deleting a chat or removing a contact).
void closeChatIfOpen(BuildContext context, String contactUserId) {
  final scope = TwoPaneScope.maybeOf(context);
  if (scope != null && scope.selectedContactId == contactUserId) {
    scope.onCloseChat();
  }
}
