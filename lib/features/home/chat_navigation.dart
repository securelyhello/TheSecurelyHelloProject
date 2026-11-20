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

/// The tabs of the signed-in shell, in bar order.
enum HomeTab { chats, findPeople, calls, settings }

/// Something that can switch the home shell to a tab.
abstract interface class HomeTabSelector {
  void select(HomeTab tab);
}

/// Lets any screen switch the home shell's tab.
///
/// Screens inside the shell find it as an ancestor. Screens pushed on top
/// of the shell (People, Contact requests) are siblings of it in the
/// navigator, so [HomeScreen] also registers itself with [attach]; its
/// `select` then pops back to the shell first.
class HomeTabScope extends InheritedWidget implements HomeTabSelector {
  const HomeTabScope({
    super.key,
    required this.current,
    required this.onSelect,
    required super.child,
  });

  final HomeTab current;
  final ValueChanged<HomeTab> onSelect;

  @override
  void select(HomeTab tab) => onSelect(tab);

  static HomeTabSelector? _attached;

  /// Registers the running home shell (call from its `initState`).
  static void attach(HomeTabSelector selector) => _attached = selector;

  /// Unregisters [selector]; a no-op when another shell has taken over.
  static void detach(HomeTabSelector selector) {
    if (identical(_attached, selector)) _attached = null;
  }

  /// The shell to switch tabs on, or null outside the signed-in shell.
  static HomeTabSelector? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HomeTabScope>() ?? _attached;

  @override
  bool updateShouldNotify(HomeTabScope oldWidget) => current != oldWidget.current;
}

/// Shows the Find people tab; outside the home shell, pushes the
/// `/add-contact` route instead.
void openFindPeople(BuildContext context) {
  final shell = HomeTabScope.maybeOf(context);
  if (shell != null) {
    shell.select(HomeTab.findPeople);
  } else {
    Navigator.pushNamed(context, '/add-contact');
  }
}
