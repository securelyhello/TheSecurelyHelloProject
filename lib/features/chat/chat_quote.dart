import 'package:securelyhello/core/chat/chat_service.dart';

/// What a reply's quote shows: who wrote the quoted message and its text.
///
/// The sender's reference `{id, from, preview}` says what they quoted.
/// Where this device has that message ([local], looked up by id in the
/// loaded page or in storage) in the same conversation, its own copy wins:
/// the author is the local copy's sender and the text its content (audit
/// run 1 and security review L8). A copy from another conversation is
/// ignored, so a reply can't pull another chat's text into this one.
({String from, String text}) resolveQuote(Map<String, dynamic> ref, Message? local,
    {required String conversationId}) {
  final claimedFrom = ref['from'] as String? ?? '';
  final preview = ref['preview'] as String? ?? '';
  if (local == null || local.conversationId != conversationId) return (from: claimedFrom, text: preview);
  if (local.deleted) return (from: local.senderId, text: preview);
  return (from: local.senderId, text: local.content.isNotEmpty ? local.content : preview);
}
