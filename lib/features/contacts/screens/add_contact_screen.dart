import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/auth_provider.dart';
import 'package:securelyhello/core/providers/chat_provider.dart';
import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/empty_state.dart';
import 'package:securelyhello/shared/widgets/search_field.dart';
import 'package:securelyhello/shared/widgets/skeleton_loader.dart';

/// Find people by username and send / answer contact requests.
class AddContactScreen extends StatefulWidget {
  const AddContactScreen({super.key});

  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen> {
  final _search = TextEditingController();
  final Set<String> _busy = {};
  late final ContactsProvider _provider;

  @override
  void initState() {
    super.initState();
    _provider = context.read<ContactsProvider>();
  }

  @override
  void dispose() {
    _search.dispose();
    // Leave no stale results behind for the next visit.
    final provider = _provider;
    Future.microtask(provider.clearSearch);
    super.dispose();
  }

  String get _query => _search.text.trim();

  void _onChanged(String value) {
    setState(() {});
    _provider.searchUsers(value);
  }

  Future<void> _run(
    String userId,
    Future<bool> Function() action, {
    required String success,
    required String failure,
  }) async {
    setState(() => _busy.add(userId));
    final ok = await action();
    if (!mounted) return;
    setState(() => _busy.remove(userId));
    if (ok) {
      showAppSnackBar(context, success, success: true);
      if (_query.isNotEmpty) _provider.searchUsers(_query);
    } else {
      showAppSnackBar(
        context,
        friendlyError(_provider.errorMessage, fallback: failure),
        error: true,
      );
    }
  }

  Future<void> _message(UserSearchResult r) async {
    try {
      await context.read<ChatProvider>().getOrCreateConversation(r.userId);
    } catch (_) {}
    if (!mounted) return;
    Navigator.pushNamed(context, '/chat', arguments: r.userId);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ContactsProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Find people')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: SearchField(
                  controller: _search,
                  hint: 'Search by username',
                  autofocus: true,
                  onChanged: _onChanged,
                ),
              ),
              AnimatedOpacity(
                opacity: provider.isSearching ? 1 : 0,
                duration: AppMotion.fast,
                child: const LinearProgressIndicator(minHeight: 2),
              ),
              Expanded(child: _body(provider)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(ContactsProvider provider) {
    if (_query.isEmpty) return const _SearchIntro();

    final results = provider.searchResults;
    if (results.isEmpty && provider.isSearching) {
      return SkeletonLoader.contactList(rows: 4);
    }
    if (results.isEmpty &&
        provider.errorMessage?.startsWith('Search failed') == true) {
      return EmptyStateWidget.error(
        title: 'Search failed',
        message: 'Check your connection and try again.',
        onRetry: () => provider.searchUsers(_query),
      );
    }
    if (results.isEmpty) {
      return EmptyStateWidget.noSearchResults(query: _query);
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: results.length,
      itemBuilder: (context, i) {
        final r = results[i];
        final name = r.displayName.isNotEmpty ? r.displayName : r.username;
        return ListTile(
          leading: AvatarWidget(
            displayName: name,
            seed: r.userId,
            isOnline: r.isOnline,
            ringColor: context.palette.background,
          ),
          title: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '@${r.username}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: _trailing(r, name),
        );
      },
    );
  }

  Widget _trailing(UserSearchResult r, String name) {
    final p = context.palette;
    if (_busy.contains(r.userId)) {
      return const SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
        ),
      );
    }
    switch (r.relationship) {
      case ContactRelationship.contact:
        return TextButton.icon(
          onPressed: () => _message(r),
          icon: const Icon(LucideIcons.messageCircle, size: 16),
          label: const Text('Message'),
        );
      case ContactRelationship.requestSent:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: p.inputFill,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.clock3, size: 14, color: p.textSecondary),
              const SizedBox(width: 6),
              Text(
                'Requested',
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: p.textSecondary),
              ),
            ],
          ),
        );
      case ContactRelationship.requestReceived:
        final requestId = r.requestId;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Decline',
              icon: Icon(LucideIcons.x, color: p.textSecondary),
              onPressed: requestId == null
                  ? null
                  : () => _run(
                      r.userId,
                      () => _provider.rejectContactRequest(requestId),
                      success: 'Request from $name declined',
                      failure: 'Could not decline the request',
                    ),
            ),
            FilledButton(
              onPressed: requestId == null
                  ? null
                  : () => _run(
                      r.userId,
                      () => _provider.acceptContactRequest(requestId),
                      success: '$name is now a contact',
                      failure: 'Could not accept the request',
                    ),
              child: const Text('Accept'),
            ),
          ],
        );
      case ContactRelationship.none:
        return FilledButton.tonalIcon(
          onPressed: () => _run(
            r.userId,
            () => _provider.sendContactRequest(r.userId),
            success: 'Request sent to @${r.username}',
            failure: 'Could not send the request',
          ),
          icon: const Icon(LucideIcons.userPlus, size: 16),
          label: const Text('Add'),
        );
    }
  }
}

class _SearchIntro extends StatelessWidget {
  const _SearchIntro();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final username = context.select<AuthProvider, String>((a) => a.username);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 24),
        Center(
          child: Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: p.accentContainer.withAlpha(140),
              shape: BoxShape.circle,
            ),
            child: Icon(
              LucideIcons.userSearch,
              size: 36,
              color: p.onAccentContainer,
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Find people by username',
          textAlign: TextAlign.center,
          style: t.titleLarge?.copyWith(fontSize: 20),
        ),
        const SizedBox(height: 8),
        Text(
          'Send a contact request. Once they accept, you can message each '
          'other with end-to-end encryption.',
          textAlign: TextAlign.center,
          style: t.bodyMedium?.copyWith(color: p.textSecondary, height: 1.45),
        ),
        if (username.isNotEmpty) ...[
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: p.divider),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.atSign, color: p.accent, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Your username',
                        style: t.bodySmall?.copyWith(color: p.textSecondary),
                      ),
                      Text(
                        '@$username',
                        style: t.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: '@$username'));
                    showAppSnackBar(context, 'Username copied');
                  },
                  icon: const Icon(LucideIcons.copy, size: 16),
                  label: const Text('Copy'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Share it so people can find you.',
            textAlign: TextAlign.center,
            style: t.bodySmall?.copyWith(color: p.textMuted),
          ),
        ],
      ],
    );
  }
}
