import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';

/// Someone's name in a chat: "You", a contact's name, or the public name of
/// a group member who isn't a contact.
String personName(ChatProvider chat, ContactsProvider contacts, String userId) {
  if (userId == chat.myUserId) return 'You';
  return contacts.getContact(userId)?.displayLabel ?? chat.memberName(userId) ?? 'Someone';
}

/// The title of a chat: the group's name, or the contact's.
String chatTitle(ChatProvider chat, ContactsProvider contacts, String conversationId) {
  final group = chat.groupOf(conversationId);
  if (group != null) return group.name;
  return contacts.getContact(conversationId)?.displayLabel ?? 'Unknown contact';
}
