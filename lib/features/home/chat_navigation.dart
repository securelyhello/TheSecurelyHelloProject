import 'package:flutter/material.dart';

import 'package:securelyhello/features/calls/call_screen.dart';

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
/// Screens pushed on top of the shell (People, Contact requests) are
/// siblings of it in the navigator, not descendants, so [HomeScreen]
/// registers itself with [attach]; its `select` then pops back to the shell
/// first.
abstract final class HomeTabRegistry {
  static HomeTabSelector? _attached;

  /// Registers the running home shell (call from its `initState`).
  static void attach(HomeTabSelector selector) => _attached = selector;

  /// Unregisters [selector]; a no-op when another shell has taken over.
  static void detach(HomeTabSelector selector) {
    if (identical(_attached, selector)) _attached = null;
  }

  /// The shell to switch tabs on, or null outside the signed-in shell.
  static HomeTabSelector? get current => _attached;
}

/// Pops every route above [shell] (the home shell's own route) so it is the
/// one showing. False, with nothing popped, when that must not happen yet:
/// the call screen is up on a locked phone and the user hasn't unlocked
/// (security review H1: the chats must not show over the lock screen).
Future<bool> popToShell(BuildContext context, Route<dynamic>? shell) async {
  if (shell == null || !shell.isActive) return true;
  if (callScreenShowing && !await unlockToLeaveCallScreen(context)) return false;
  // The call may have ended (and its screen closed) while unlocking.
  if (!context.mounted) return false;
  if (shell.isActive) Navigator.of(context).popUntil((r) => r == shell);
  return true;
}

/// Reports the [ModalRoute] it sits in to [onRoute], without making the
/// widgets around it rebuild when a page is pushed over or popped: only
/// this probe depends on the route, and its [child] is the same instance.
class RouteProbe extends StatefulWidget {
  const RouteProbe({super.key, required this.onRoute, required this.child});

  final ValueChanged<ModalRoute<dynamic>?> onRoute;
  final Widget child;

  @override
  State<RouteProbe> createState() => _RouteProbeState();
}

class _RouteProbeState extends State<RouteProbe> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.onRoute(ModalRoute.of(context));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Shows the Find people tab; outside the home shell, pushes the
/// `/add-contact` route instead.
void openFindPeople(BuildContext context) {
  final shell = HomeTabRegistry.current;
  if (shell != null) {
    shell.select(HomeTab.findPeople);
  } else {
    Navigator.pushNamed(context, '/add-contact');
  }
}
