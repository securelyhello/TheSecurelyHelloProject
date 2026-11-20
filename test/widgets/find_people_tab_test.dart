import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/features/contacts/screens/add_contact_screen.dart';
import 'package:securelyhello/features/home/chat_navigation.dart';
import 'package:securelyhello/l10n/app_localizations.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';

class _Contacts extends ChangeNotifier implements ContactsProvider {
  List<ContactRequest> requests = [];
  List<UserSearchResult> results = [];
  final searches = <String>[];
  var clears = 0;

  @override
  List<ContactRequest> get receivedRequests => requests;
  @override
  List<UserSearchResult> get searchResults => results;
  bool searching = false;
  @override
  bool get isSearching => searching;
  @override
  String? get errorMessage => null;
  @override
  void searchUsers(String query) => searches.add(query);
  @override
  void clearSearch() => clears++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Auth extends ChangeNotifier implements AuthProvider {
  @override
  String get username => 'tirth';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Chat extends ChangeNotifier implements ChatProvider {
  final opened = <String>[];
  @override
  Future<String> getOrCreateConversation(String contactUserId) async {
    opened.add(contactUserId);
    return contactUserId;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ContactRequest _req(String id) =>
    ContactRequest(id: id, senderId: 's$id', receiverId: 'me', status: 'pending');

void main() {
  late _Contacts contacts;
  late _Chat chat;

  setUp(() {
    contacts = _Contacts();
    chat = _Chat();
  });

  Future<void> pump(
    WidgetTester tester, {
    required bool embedded,
    Widget Function(Widget child)? wrap,
    Map<String, WidgetBuilder> routes = const {},
  }) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget screen = AddContactScreen(embedded: embedded);
    if (wrap != null) screen = wrap(screen);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<ContactsProvider>.value(value: contacts),
        ChangeNotifierProvider<AuthProvider>.value(value: _Auth()),
        ChangeNotifierProvider<ChatProvider>.value(value: chat),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        routes: routes,
        home: screen,
      ),
    ));
    await tester.pump();
  }

  testWidgets('embedded: tab-style title, no back button, no autofocus', (tester) async {
    await pump(tester, embedded: true);
    final search = find.byKey(const ValueKey('find-people-search'));
    expect(search, findsOneWidget);
    expect(find.text('Find people'), findsOneWidget); // the title
    expect(find.byType(BackButton), findsNothing);
    expect(find.byType(AppBar), findsOneWidget);
    expect(tester.widget<AppBar>(find.byType(AppBar)).automaticallyImplyLeading, isFalse);
    final editable = tester.widget<EditableText>(
        find.descendant(of: search, matching: find.byType(EditableText)));
    expect(editable.autofocus, isFalse);
    expect(editable.focusNode.hasFocus, isFalse);
  });

  testWidgets('standalone route keeps autofocus and the key', (tester) async {
    await pump(tester, embedded: false);
    final search = find.byKey(const ValueKey('find-people-search'));
    final editable = tester.widget<EditableText>(
        find.descendant(of: search, matching: find.byType(EditableText)));
    expect(editable.autofocus, isTrue);
  });

  testWidgets('the progress bar is built only while searching, in a fixed 2dp slot', (tester) async {
    await pump(tester, embedded: true);
    final slot = find.byKey(const ValueKey('find-people-progress-slot'));
    expect(find.byType(LinearProgressIndicator), findsNothing, reason: 'nothing ticking at opacity 0');
    expect(tester.getSize(slot).height, 2);
    final top = tester.getTopLeft(slot).dy;

    contacts.searching = true;
    contacts.notifyListeners();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.getSize(slot).height, 2);
    expect(tester.getTopLeft(slot).dy, top, reason: 'no layout jump');

    contacts.searching = false;
    contacts.notifyListeners();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('typing searches through the provider', (tester) async {
    await pump(tester, embedded: true);
    await tester.enterText(find.byKey(const ValueKey('find-people-search')), 'mira');
    expect(contacts.searches, ['mira']);
  });

  testWidgets('embedded: leaving the tab never clears the results', (tester) async {
    await pump(tester, embedded: true);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(contacts.clears, 0);
  });

  testWidgets('standalone: results are cleared on close', (tester) async {
    await pump(tester, embedded: false);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(contacts.clears, 1);
  });

  testWidgets('requests tile appears with a count and opens /contact-requests', (tester) async {
    contacts.requests = [_req('1'), _req('2')];
    await pump(tester, embedded: true, routes: {
      '/contact-requests': (_) => const Scaffold(body: Text('requests route')),
    });
    final tile = find.byKey(const ValueKey('find-requests'));
    expect(tile, findsOneWidget);
    expect(find.text('Contact requests (2)'), findsOneWidget);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text('requests route'), findsOneWidget);
  });

  testWidgets('no requests tile when nothing is pending', (tester) async {
    await pump(tester, embedded: true);
    expect(find.byKey(const ValueKey('find-requests')), findsNothing);
  });

  testWidgets('the tile updates when a request arrives', (tester) async {
    await pump(tester, embedded: true);
    expect(find.byKey(const ValueKey('find-requests')), findsNothing);
    contacts.requests = [_req('1')];
    contacts.notifyListeners();
    await tester.pump();
    expect(find.text('Contact requests (1)'), findsOneWidget);
  });

  testWidgets('Message on a contact result uses openChat (two-pane aware)', (tester) async {
    contacts.results = const [
      UserSearchResult(
        userId: 'u1',
        username: 'mira',
        displayName: 'Mira Kapoor',
        relationship: ContactRelationship.contact,
      ),
    ];
    final opened = <String>[];
    await pump(
      tester,
      embedded: true,
      wrap: (child) => TwoPaneScope(
        selectedContactId: null,
        onOpenChat: opened.add,
        onCloseChat: () {},
        child: child,
      ),
      routes: {'/chat': (_) => const Scaffold(body: Text('chat route'))},
    );
    await tester.enterText(find.byKey(const ValueKey('find-people-search')), 'mira');
    await tester.pump();
    await tester.tap(find.text('Message'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 500));
    expect(chat.opened, ['u1']);
    expect(opened, ['u1']);
    expect(find.text('chat route'), findsNothing);
  });
}
