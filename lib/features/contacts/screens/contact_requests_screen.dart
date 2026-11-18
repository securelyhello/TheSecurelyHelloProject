import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'package:securelyhello/core/providers/contacts_provider.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';
import 'package:securelyhello/shared/widgets/app_dialogs.dart';
import 'package:securelyhello/shared/widgets/avatar_widget.dart';
import 'package:securelyhello/shared/widgets/empty_state.dart';
import 'package:securelyhello/shared/widgets/search_field.dart';
import 'package:securelyhello/shared/widgets/skeleton_loader.dart';

/// Incoming requests (accept / decline) and requests you sent (pending).
class ContactRequestsScreen extends StatefulWidget {
  const ContactRequestsScreen({super.key});

  @override
  State<ContactRequestsScreen> createState() => _ContactRequestsScreenState();
}

class _ContactRequestsScreenState extends State<ContactRequestsScreen> {
  final Set<String> _busy = {};

  Future<void> _accept(ContactRequest req, String name) async {
    final provider = context.read<ContactsProvider>();
    setState(() => _busy.add(req.id));
    final ok = await provider.acceptContactRequest(req.id);
    if (!mounted) return;
    setState(() => _busy.remove(req.id));
    if (ok) {
      showAppSnackBar(context, '$name is now a contact', success: true);
    } else {
      showAppSnackBar(
        context,
        friendlyError(
          provider.errorMessage,
          fallback: 'Could not accept the request',
        ),
        error: true,
      );
    }
  }

  Future<void> _decline(ContactRequest req, String name) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Decline request?',
      message:
          '$name won’t be added to your contacts. They can send you a '
          'new request later.',
      confirmLabel: 'Decline',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final provider = context.read<ContactsProvider>();
    setState(() => _busy.add(req.id));
    final ok = await provider.rejectContactRequest(req.id);
    if (!mounted) return;
    setState(() => _busy.remove(req.id));
    if (ok) {
      showAppSnackBar(context, 'Request from $name declined');
    } else {
      showAppSnackBar(
        context,
        friendlyError(
          provider.errorMessage,
          fallback: 'Could not decline the request',
        ),
        error: true,
      );
    }
  }

  String _nameOf(UserSearchResult? u) {
    if (u == null) return 'Unknown user';
    return u.displayName.isNotEmpty ? u.displayName : '@${u.username}';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final provider = context.watch<ContactsProvider>();
    final received = provider.receivedRequests;
    final sent = provider.sentRequests;

    final loading = provider.isLoading && received.isEmpty && sent.isEmpty;
    final loadError =
        !provider.isLoading &&
        received.isEmpty &&
        sent.isEmpty &&
        provider.errorMessage?.startsWith('Failed to load contacts') == true;

    final slivers = <Widget>[];
    if (loading) {
      slivers.add(
        SliverToBoxAdapter(child: SkeletonLoader.contactList(rows: 4)),
      );
    } else if (loadError) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyStateWidget.error(
            title: "Couldn't load requests",
            message: friendlyError(provider.errorMessage),
            onRetry: provider.loadContacts,
          ),
        ),
      );
    } else if (received.isEmpty && sent.isEmpty) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyStateWidget(
            icon: LucideIcons.inbox,
            title: 'No pending requests',
            subtitle:
                'When someone wants to chat with you, their request shows '
                'up here.',
            actionLabel: 'Find people',
            actionIcon: LucideIcons.userPlus,
            onAction: () => Navigator.pushNamed(context, '/add-contact'),
          ),
        ),
      );
    } else {
      if (received.isNotEmpty) {
        slivers
          ..add(
            SliverToBoxAdapter(
              child: SectionHeader('Received — ${received.length}'),
            ),
          )
          ..add(
            SliverList.builder(
              itemCount: received.length,
              itemBuilder: (context, i) {
                final req = received[i];
                final sender = req.sender;
                final name = _nameOf(sender);
                final busy = _busy.contains(req.id);
                return ListTile(
                  leading: AvatarWidget(
                    displayName: name,
                    seed: req.senderId,
                    isOnline: sender?.isOnline ?? false,
                    ringColor: p.background,
                  ),
                  title: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  isThreeLine: req.fromNewAccount,
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        sender == null ? 'wants to connect' : '@${sender.username}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (req.fromNewAccount)
                        Text.rich(
                          key: ValueKey('new-account-${req.id}'),
                          TextSpan(children: [
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Icon(LucideIcons.triangleAlert, size: 13, color: p.warning),
                            ),
                            TextSpan(
                              text: ' New account, joined ${_age(req.senderJoinedAt!)}. '
                                  "Only accept if you know them.",
                            ),
                          ]),
                          style: TextStyle(color: p.warning, fontSize: 12),
                        ),
                    ],
                  ),
                  trailing: busy
                      ? const SizedBox(
                          width: 44,
                          child: Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                              ),
                            ),
                          ),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Decline',
                              icon: Icon(LucideIcons.x, color: p.textSecondary),
                              onPressed: () => _decline(req, name),
                            ),
                            FilledButton(
                              onPressed: () => _accept(req, name),
                              child: const Text('Accept'),
                            ),
                          ],
                        ),
                );
              },
            ),
          );
      }
      if (sent.isNotEmpty) {
        slivers
          ..add(
            SliverToBoxAdapter(child: SectionHeader('Sent — ${sent.length}')),
          )
          ..add(
            SliverList.builder(
              itemCount: sent.length,
              itemBuilder: (context, i) {
                final req = sent[i];
                final receiver = req.receiver;
                final name = _nameOf(receiver);
                return ListTile(
                  leading: AvatarWidget(
                    displayName: name,
                    seed: req.receiverId,
                    ringColor: p.background,
                  ),
                  title: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    receiver == null
                        ? 'Awaiting reply'
                        : '@${receiver.username}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: p.inputFill,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Text(
                      'Pending',
                      style: Theme.of(
                        context,
                      ).textTheme.labelMedium?.copyWith(color: p.textSecondary),
                    ),
                  ),
                );
              },
            ),
          );
      }
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Contact requests')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: RefreshIndicator(
            onRefresh: provider.loadContacts,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: slivers,
            ),
          ),
        ),
      ),
    );
  }
}

String _age(DateTime joined) {
  final d = DateTime.now().difference(joined);
  if (d.inHours < 1) return 'minutes ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return d.inDays == 1 ? 'yesterday' : '${d.inDays} days ago';
}
