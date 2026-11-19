import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/l10n/app_localizations.dart';
import 'package:securelyhello/features/settings/screens/legal_screen.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';

void main() {
  for (final doc in [LegalScreen.privacy, LegalScreen.terms]) {
    testWidgets('${doc.$1} is bundled and renders', (t) async {
      await t.pumpWidget(MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          theme: AppTheme.dark, home: LegalScreen(title: doc.$1, asset: doc.$2)));
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(find.text(doc.$1), findsWidgets);
      expect(find.textContaining('Last updated'), findsWidgets);
      // Finished documents: no drafting notes or placeholders.
      expect(find.textContaining('lawyer'), findsNothing);
      expect(find.textContaining('['), findsNothing);
      expect(find.text('This document is not available.'), findsNothing);
    });
  }
}
