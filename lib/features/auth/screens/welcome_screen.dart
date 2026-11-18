import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';

/// First launch: what makes this messenger different, then sign up or log
/// in. Shown until the person moves past it once.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  static const _seenKey = 'sh_onboarded';

  static Future<bool> seen() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_seenKey) ?? false;
    } catch (_) {
      return true;
    }
  }

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _Page {
  final IconData icon;
  final String title;
  final String body;
  const _Page(this.icon, this.title, this.body);
}

const _pages = [
  _Page(LucideIcons.lock, 'Only you and them',
      'Every message, photo, file and voice note is encrypted on your phone. Only the people '
          "you're talking to can open it. Not us, not the server."),
  _Page(LucideIcons.shieldCheck, "Know who you're talking to",
      "Compare a safety number or scan a code to be sure. If someone's keys ever change, "
          'the app tells you before sending anything.'),
  _Page(LucideIcons.userCheck, 'Only people you choose',
      'Strangers need your OK before they can message you. No phone number needed, no ads, '
          'no tracking.'),
];

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _pager = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  Future<void> _done(String route) async {
    try {
      await (await SharedPreferences.getInstance()).setBool(WelcomeScreen._seenKey, true);
    } catch (_) {}
    if (mounted) Navigator.of(context).pushReplacementNamed(route);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final last = _page == _pages.length - 1;
    return Scaffold(
      backgroundColor: p.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(children: [
              Align(
                alignment: Alignment.centerRight,
                child: AnimatedOpacity(
                  opacity: last ? 0 : 1,
                  duration: AppMotion.fast,
                  child: TextButton(
                    key: const ValueKey('welcome-skip'),
                    onPressed: last ? null : () => _done('/login'),
                    child: const Text('Skip'),
                  ),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _pager,
                  itemCount: _pages.length,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (context, i) {
                    final page = _pages[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Container(
                          width: 112,
                          height: 112,
                          decoration: BoxDecoration(color: p.accentContainer, shape: BoxShape.circle),
                          child: Icon(page.icon, size: 48, color: p.onAccentContainer),
                        ),
                        const SizedBox(height: 32),
                        Text(page.title,
                            textAlign: TextAlign.center,
                            style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 14),
                        Text(page.body,
                            textAlign: TextAlign.center,
                            style: t.bodyLarge?.copyWith(color: p.textSecondary, height: 1.5)),
                      ]),
                    );
                  },
                ),
              ),
              Semantics(
                label: 'Page ${_page + 1} of ${_pages.length}',
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (var i = 0; i < _pages.length; i++)
                    AnimatedContainer(
                      duration: AppMotion.fast,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: i == _page ? 22 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == _page ? p.accent : p.divider,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                child: last
                    ? Column(children: [
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            key: const ValueKey('welcome-signup'),
                            onPressed: () => _done('/signup'),
                            child: const Text('Create an account'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          key: const ValueKey('welcome-login'),
                          onPressed: () => _done('/login'),
                          child: const Text('I already have an account'),
                        ),
                      ])
                    : SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          key: const ValueKey('welcome-next'),
                          onPressed: () => _pager.nextPage(duration: AppMotion.medium, curve: AppMotion.curve),
                          child: const Text('Next'),
                        ),
                      ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
