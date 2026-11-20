import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:securelyhello/features/settings/screens/settings_screen.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';

Future<void> _loadFonts() async {
  const files = {
    'Inter': ['Inter-Regular', 'Inter-Medium', 'Inter-SemiBold', 'Inter-Bold'],
    'Chillax': ['Chillax-Medium', 'Chillax-Semibold'],
    'PlusJakartaSans': ['PlusJakartaSans-Medium', 'PlusJakartaSans-SemiBold', 'PlusJakartaSans-Bold'],
  };
  for (final e in files.entries) {
    final loader = FontLoader(e.key);
    for (final f in e.value) {
      final file = File('assets/fonts/$f.ttf');
      if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }
}

void main() {
  setUpAll(_loadFonts);

  /// A settings row laid out like the screen's: a 12dp-inset group on a
  /// 360dp phone, label left, dropdown right.
  Future<void> pump(
    WidgetTester t, {
    required String label,
    required List<(String, String)> options,
    String? selected,
    double textScale = 1,
    double width = 360,
  }) async {
    t.view.physicalSize = Size(width, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(children: [
            SettingsDropdownTile<String>(
              icon: LucideIcons.timer,
              label: label,
              value: selected ?? options.first.$1,
              options: options,
              onChanged: (_) {},
            ),
          ]),
        ),
      ),
    ));
    await t.pumpAndSettle();
  }

  const timer = [('0', 'Off'), ('86400', '1 day'), ('604800', '1 week')];
  const languages = [('', 'System default'), ('en', 'English'), ('hi', 'हिन्दी'), ('gu', 'ગુજરાતી')];

  for (final scale in [1.0, 1.3]) {
    testWidgets('360dp, text scale $scale: "Language" stays whole on one line, nothing overflows', (t) async {
      await pump(t, label: 'Language', options: languages, selected: 'en', textScale: scale);
      expect(t.takeException(), isNull);
      final p = t.renderObject<RenderParagraph>(find.text('Language'));
      expect(p.didExceedMaxLines, isFalse);
      final lineHeight = (p.text.style?.fontSize ?? 16) * scale * 1.6;
      expect(p.size.height, lessThan(lineHeight), reason: 'one line: not broken mid-word');
    });

    testWidgets('360dp, text scale $scale: the long label is shown in full, wrapped, no overflow', (t) async {
      await pump(t, label: 'Disappearing messages for new chats', options: timer, textScale: scale);
      expect(t.takeException(), isNull);
      final p = t.renderObject<RenderParagraph>(find.text('Disappearing messages for new chats'));
      expect(p.didExceedMaxLines, isFalse, reason: 'not cut to "Disappe…"');
      // Every word is whole: the paragraph's width fits its longest word.
      final longest = TextPainter(
        text: TextSpan(text: 'Disappearing', style: p.text.style),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.linear(scale),
      )..layout();
      expect(p.size.width, greaterThanOrEqualTo(longest.width));
    });
  }

  testWidgets('in a wide window the row is still the 380dp list pane: "Language" stays whole', (t) async {
    await pump(t, label: 'Language', options: languages, selected: 'en', textScale: 1.3, width: 1200);
    expect(t.takeException(), isNull);
    // (The harness row is as wide as the window; the cap is what is under test.)
    expect(t.getSize(find.byType(DropdownButton<String>)).width, lessThanOrEqualTo(380 * 0.45 + 0.01));
  });

  testWidgets('the dropdown is not stretched to a fixed width', (t) async {
    await pump(t, label: 'Language', options: timer);
    final w = t.getSize(find.byType(DropdownButton<String>)).width;
    expect(w, lessThan(130), reason: 'sized to its options (Off / 1 day / 1 week)');
  });

  testWidgets('the dropdown is capped at 45% of the screen and long option text ends in an ellipsis', (t) async {
    await pump(t, label: 'Sound', options: [('a', 'Phone default sound with a very long name indeed')], textScale: 1.3);
    expect(t.takeException(), isNull);
    final w = t.getSize(find.byType(DropdownButton<String>)).width;
    expect(w, lessThanOrEqualTo(360 * 0.45 + 0.01));
    final p = t.renderObject<RenderParagraph>(find.textContaining('Phone default', skipOffstage: false).first);
    expect(p.didExceedMaxLines, isTrue, reason: 'ellipsized');
  });
}
