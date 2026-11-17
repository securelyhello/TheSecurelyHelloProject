import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/chat/attachment_service.dart';
import 'package:securelyhello/features/chat/widgets/attachment_view.dart';
import 'package:securelyhello/shared/theme/app_theme.dart';

import '../attachment_service_test.dart' show FakeBlobs;

/// All visible text under [finder], in order.
List<String> texts(WidgetTester t) => t
    .widgetList<Text>(find.byType(Text))
    .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
    .toList();

void main() {
  testWidgets('inline and uploaded files look exactly the same to the user', (t) async {
    final dir = Directory.systemTemp.createTempSync('sh_av');
    final service = AttachmentService(directory: FakeBlobs(), cacheDirectory: () async => dir.path);
    final rng = Random(1);
    late Map<String, dynamic> inline;
    late Map<String, dynamic> uploaded;
    await t.runAsync(() async {
      inline = await service.upload(Uint8List.fromList(utf8.encode('minutes ' * 400)),
          name: 'minutes.pdf');
      uploaded = await service.upload(
          Uint8List.fromList(List.generate(200000, (_) => rng.nextInt(256))),
          name: 'minutes.pdf');
    });
    expect(AttachmentService.isInline(inline), isTrue);
    expect(AttachmentService.isInline(uploaded), isFalse);

    Future<List<String>> render(Map<String, dynamic> meta) async {
      await t.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
            body: AttachmentView(meta: {...meta, 'size': 3200}, service: service, isSent: false)),
      ));
      await t.pump();
      return texts(t);
    }

    final a = await render(inline);
    final b = await render(uploaded);
    expect(a, b, reason: 'same name, size and labels either way');
    expect(a, containsAll(['minutes.pdf', '3 KB · encrypted']));
    for (final s in [...a, ...b]) {
      expect(s.contains('FTS1'), isFalse, reason: 'the transport never shows');
    }
  });
}
