import 'package:flutter/material.dart';

import 'package:securelyhello/features/auth/screens/auth_paper.dart';
import 'package:securelyhello/shared/widgets/brand_logo.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:securelyhello/l10n/app_localizations.dart';
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

List<_Page> _pagesFor(L10n l) => [
      _Page(LucideIcons.lock, l.welcome1Title, l.welcome1Body),
      _Page(LucideIcons.shieldCheck, l.welcome2Title, l.welcome2Body),
      _Page(LucideIcons.userCheck, l.welcome3Title, l.welcome3Body),
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
    final l = L10n.of(context);
    final pages = _pagesFor(l);
    final last = _page == pages.length - 1;
    final sheetContent = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: 'Page ${_page + 1} of ${pages.length}',
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < pages.length; i++)
              AnimatedContainer(
                duration: AppMotion.of(context, AppMotion.fast),
                curve: AppMotion.snap,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: i == _page ? 22 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: i == _page ? p.textPrimary : p.border,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 24),
        if (last) ...[
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: const ValueKey('welcome-signup'),
              onPressed: () => _done('/signup'),
              child: Text(l.welcomeCreateAccount),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const ValueKey('welcome-login'),
            onPressed: () => _done('/login'),
            child: Text(l.welcomeHaveAccount),
          ),
        ] else
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: const ValueKey('welcome-next'),
              onPressed: () => _pager.nextPage(
                duration: AppMotion.of(context, AppMotion.medium),
                curve: AppMotion.curve,
              ),
              child: Text(l.welcomeNext),
            ),
          ),
      ],
    );
    return Scaffold(
      backgroundColor: p.background,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Align(
            alignment: Alignment.centerRight,
            child: AnimatedOpacity(
              opacity: last ? 0 : 1,
              duration: AppMotion.of(context, AppMotion.fast),
              child: Padding(
                padding: const EdgeInsets.only(right: 8, top: 4),
                child: TextButton(
                  key: const ValueKey('welcome-skip'),
                  onPressed: last ? null : () => _done('/login'),
                  child: Text(l.welcomeSkip),
                ),
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: PageView.builder(
                  controller: _pager,
                  itemCount: pages.length,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (context, i) {
                    final page = pages[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        if (i == 0)
                          const BrandLogo(size: 160, float: true)
                        else
                          Container(
                            width: 120,
                            height: 120,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: p.brand),
                            child: Icon(page.icon, size: 50, color: p.onBrand),
                          ),
                        const SizedBox(height: 32),
                        Text(page.title, textAlign: TextAlign.center, style: t.headlineMedium),
                        const SizedBox(height: 14),
                        Text(page.body,
                            textAlign: TextAlign.center,
                            style: t.bodyLarge?.copyWith(color: p.textSecondary, height: 1.5)),
                      ]),
                    );
                  },
                ),
              ),
            ),
          ),
          SizedBox(
            width: double.infinity,
            child: TornPaperSheet(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: AnimatedSize(
                    duration: AppMotion.of(context, AppMotion.medium),
                    curve: AppMotion.snap,
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(24, 28, 24, 24 + MediaQuery.paddingOf(context).bottom),
                      child: sheetContent,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
