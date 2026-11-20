import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:securelyhello/shared/theme/app_theme.dart';

/// Shows a bundled legal document (docs/legal/*.md) with light Markdown:
/// headings, bullets, tables, bold and italics.
class LegalScreen extends StatelessWidget {
  final String title;
  final String asset;
  const LegalScreen({super.key, required this.title, required this.asset});

  static const privacy = ('Privacy policy', 'docs/legal/privacy.md');
  static const terms = ('Terms of service', 'docs/legal/terms.md');

  static void open(BuildContext context, (String, String) doc) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LegalScreen(title: doc.$1, asset: doc.$2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: FutureBuilder<String>(
        future: rootBundle.loadString(asset),
        builder: (context, snap) {
          final text = snap.data;
          if (text == null) {
            return Center(
              child: snap.hasError
                  ? const Text('This document is not available.')
                  : const CircularProgressIndicator(),
            );
          }
          return SelectionArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              children: [for (final b in _blocks(text)) _render(context, b)],
            ),
          );
        },
      ),
    );
  }

  /// Splits Markdown into paragraphs, headings, bullets and table rows.
  static List<(String, String)> _blocks(String md) {
    final out = <(String, String)>[];
    final para = <String>[];
    void flush() {
      if (para.isNotEmpty) out.add(('p', para.join(' ')));
      para.clear();
    }

    for (final raw in md.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        flush();
      } else if (line.startsWith('#')) {
        flush();
        final level = line.indexOf(' ');
        out.add(('h${level.clamp(1, 3)}', line.substring(level + 1)));
      } else if (line.startsWith('- ')) {
        flush();
        out.add(('li', line.substring(2)));
      } else if (line.startsWith('  ') && out.isNotEmpty && out.last.$1 == 'li' && para.isEmpty) {
        out.last = ('li', '${out.last.$2} ${line.trim()}');
      } else if (line.startsWith('|')) {
        flush();
        if (RegExp(r'^\|[\s\-|:]+\|$').hasMatch(line)) continue; // separator
        out.add(('tr', line));
      } else {
        para.add(line.trim());
      }
    }
    flush();
    return out;
  }

  static TextSpan _inline(String s, TextStyle? base) {
    final spans = <TextSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|_(.+?)_');
    var i = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > i) spans.add(TextSpan(text: s.substring(i, m.start)));
      spans.add(m.group(1) != null
          ? TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.w700))
          : TextSpan(text: m.group(2), style: const TextStyle(fontStyle: FontStyle.italic)));
      i = m.end;
    }
    if (i < s.length) spans.add(TextSpan(text: s.substring(i)));
    return TextSpan(style: base, children: spans);
  }

  Widget _render(BuildContext context, (String, String) b) {
    final t = Theme.of(context).textTheme;
    final p = context.palette;
    switch (b.$1) {
      case 'h1':
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(b.$2, style: t.headlineSmall),
        );
      case 'h2':
      case 'h3':
        return Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 8),
          child: Text(b.$2, style: t.titleMedium?.copyWith(color: p.accent, fontWeight: FontWeight.w700)),
        );
      case 'li':
        return Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('•  ', style: t.bodyMedium),
            Expanded(child: Text.rich(_inline(b.$2, t.bodyMedium?.copyWith(height: 1.45)))),
          ]),
        );
      case 'tr':
        final cells = b.$2.split('|').map((c) => c.trim()).where((c) => c.isNotEmpty).toList();
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.divider))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < cells.length; i++)
              Text.rich(_inline(cells[i],
                  i == 0 ? t.bodyMedium?.copyWith(fontWeight: FontWeight.w600) : t.bodySmall?.copyWith(height: 1.4))),
          ]),
        );
      default:
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text.rich(_inline(b.$2, t.bodyMedium?.copyWith(height: 1.5))),
        );
    }
  }
}
