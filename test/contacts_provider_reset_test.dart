import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/core/storage/local_storage.dart';
import 'package:securelyhello/core/storage/secure_key_store.dart';

/// Search replies are handed out one by one, so a test decides when each lands.
class _SearchDirectory extends DirectoryService {
  _SearchDirectory()
      : super(baseUrl: 'https://fake.invalid', tokenStore: SecureKeyStore(storage: MemorySecretStorage()));

  final replies = <Completer<List<Map<String, dynamic>>>>[];

  @override
  Future<List<Map<String, dynamic>>> searchUsers(String query) {
    final c = Completer<List<Map<String, dynamic>>>();
    replies.add(c);
    return c.future;
  }
}

Map<String, dynamic> _user(String id) => {'user_id': id, 'username': id, 'display_name': id};

// Signing out while a search is in flight must not leave the previous
// account's results in the provider for the next account.
void main() {
  late _SearchDirectory directory;
  late ContactsProvider contacts;

  setUp(() {
    directory = _SearchDirectory();
    contacts = ContactsProvider(directoryService: directory, localStorage: LocalStorage());
  });

  tearDown(() => contacts.dispose());

  Future<void> debounce() => Future<void>.delayed(const Duration(milliseconds: 500));

  test('a search reply that lands after reset() is ignored', () async {
    contacts.searchUsers('mira');
    await debounce();
    expect(directory.replies, hasLength(1));

    await contacts.reset();
    directory.replies.single.complete([_user('u1')]);
    await Future<void>.delayed(Duration.zero);

    expect(contacts.searchResults, isEmpty);
    expect(contacts.isSearching, isFalse);
  });

  test('an error that lands after reset() is not shown to the next account', () async {
    contacts.searchUsers('mira');
    await debounce();
    await contacts.reset();
    directory.replies.single.completeError(Exception('boom'));
    await Future<void>.delayed(Duration.zero);
    expect(contacts.errorMessage, isNull);
  });

  test('the same term searched again after reset() is not overwritten by the old reply', () async {
    contacts.searchUsers('mira');
    await debounce();
    await contacts.reset();

    contacts.searchUsers('mira');
    await debounce();
    expect(directory.replies, hasLength(2));
    directory.replies[1].complete([_user('new')]);
    await Future<void>.delayed(Duration.zero);
    expect(contacts.searchResults.map((r) => r.userId), ['new']);

    directory.replies[0].complete([_user('old')]);
    await Future<void>.delayed(Duration.zero);
    expect(contacts.searchResults.map((r) => r.userId), ['new']);
  });

  test('a normal search still lands', () async {
    contacts.searchUsers('mira');
    await debounce();
    directory.replies.single.complete([_user('u1')]);
    await Future<void>.delayed(Duration.zero);
    expect(contacts.searchResults.map((r) => r.userId), ['u1']);
    expect(contacts.isSearching, isFalse);
  });
}
