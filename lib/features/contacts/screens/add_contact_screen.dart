import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/features/contacts/screens/suggestions_screen.dart';
import 'package:securelyhello/features/home/chat_navigation.dart';
import 'package:securelyhello/l10n/app_localizations.dart';
import 'package:securelyhello/features/contacts/screens/invite_screen.dart';
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
///
/// Shown as the Find people tab of the home shell ([embedded]) and as the
/// `/add-contact` route elsewhere.
class AddContactScreen extends StatefulWidget {
  const AddContactScreen({super.key, this.embedded = false});

  /// A tab of the home shell: no back button, the search box does not grab
  /// focus (the keyboard would cover the screen on every start) and the
  /// results stay when you switch tabs.
  final bool embedded;

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
    // Leave no stale results behind for the next visit (a tab lives as
    // long as the shell, so it keeps its results).
    if (!widget.embedded) {
      final provider = _provider;
      Future.microtask(provider.clearSearch);
    }
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
    openChat(context, r.userId);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ContactsProvider>();
    final requests = provider.receivedRequests.length;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: Text(L10n.of(context).findPeople),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: SearchField(
                  key: const ValueKey('find-people-search'),
                  controller: _search,
                  hint: 'Search by username',
                  autofocus: !widget.embedded,
                  onChanged: _onChanged,
                ),
              ),
              AnimatedOpacity(
                opacity: provider.isSearching ? 1 : 0,
                duration: AppMotion.of(context, AppMotion.fast),
                child: const LinearProgressIndicator(minHeight: 2),
              ),
              if (requests > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: _RequestsTile(count: requests),
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
        final theme = Theme.of(context);
        return ListTile(
          minVerticalPadding: 10,
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
            style: theme.textTheme.titleMedium,
          ),
          subtitle: Text(
            '@${r.username}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
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
    final phone = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    final invite = _EntryTile(
      key: const ValueKey('find-invite'),
      icon: LucideIcons.qrCode,
      title: 'Invite friends',
      subtitle: 'Share a link or show your QR code',
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const InviteScreen())),
    );
    final fromContacts = phone
        ? _EntryTile(
            icon: LucideIcons.contact,
            title: 'From your contacts',
            subtitle: 'See who you know on Securely Hello',
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => const SuggestionsScreen())),
          )
        : null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text(
          'Find people by username',
          style: t.titleLarge,
        ),
        const SizedBox(height: 6),
        Text(
          'Send a contact request. Once they accept, you can message each '
          'other with end-to-end encryption.',
          style: t.bodyMedium?.copyWith(color: p.textSecondary, height: 1.45),
        ),
        const SizedBox(height: 20),
        if (fromContacts == null)
          invite
        else
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: invite),
                const SizedBox(width: 12),
                Expanded(child: fromContacts),
              ],
            ),
          ),
        if (username.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: p.border),
              boxShadow: p.paperShadow,
            ),
            child: Row(
              children: [
                _PearCircle(icon: LucideIcons.atSign),
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
                        style: t.titleMedium,
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
          const SizedBox(height: 10),
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

/// A large tile: icon in a pear circle, title, one line of help.
class _EntryTile extends StatelessWidget {
  const _EntryTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    return Material(
      color: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PearCircle(icon: icon, size: 48),
              const SizedBox(height: 14),
              Text(title, style: t.titleMedium),
              const SizedBox(height: 4),
              Text(subtitle, style: t.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "Contact requests (n)" row above the results.
class _RequestsTile extends StatelessWidget {
  const _RequestsTile({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      key: const ValueKey('find-requests'),
      color: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        side: BorderSide(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: _PearCircle(icon: LucideIcons.inbox),
        title: Text(
          L10n.of(context).contactRequestsCount(count),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        trailing: Icon(LucideIcons.chevronRight, size: 18, color: p.textMuted),
        onTap: () => Navigator.pushNamed(context, '/contact-requests'),
      ),
    );
  }
}

/// A Lucide icon in a pear circle (the app's one illustration device).
class _PearCircle extends StatelessWidget {
  const _PearCircle({required this.icon, this.size = 40});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: p.brand, shape: BoxShape.circle),
      child: Icon(icon, size: size * 0.5, color: p.onBrand),
    );
  }
}
