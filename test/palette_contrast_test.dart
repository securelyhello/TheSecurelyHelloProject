import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securelyhello/shared/theme/app_palette.dart';

/// WCAG 2.x contrast ratio between two opaque colours.
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  final themes = {
    'Paper (light)': AppPalette.light,
    'Night (dark)': AppPalette.dark,
  };

  themes.forEach((name, p) {
    group(name, () {
      final grounds = {'background': p.background, 'surface': p.surface};

      grounds.forEach((groundName, ground) {
        test('text tokens are at least 4.5:1 on $groundName', () {
          final text = {
            'textPrimary': p.textPrimary,
            'textSecondary': p.textSecondary,
            'textMuted': p.textMuted,
            'link': p.link,
            'success': p.success,
            'warning': p.warning,
            'danger': p.danger,
            'accent': p.accent,
          };
          text.forEach((token, color) {
            expect(
              contrast(color, ground),
              greaterThanOrEqualTo(4.5),
              reason: '$token on $groundName',
            );
          });
        });

        test('graphical tokens are at least 3:1 on $groundName', () {
          final graphics = {
            'accent': p.accent,
            'online': p.online,
            'danger': p.danger,
          };
          graphics.forEach((token, color) {
            expect(
              contrast(color, ground),
              greaterThanOrEqualTo(3),
              reason: '$token on $groundName',
            );
          });
        });
      });

      test('onBrand on brand is at least 4.5:1', () {
        expect(contrast(p.onBrand, p.brand), greaterThanOrEqualTo(4.5));
      });

      test('onAccent on accent is at least 4.5:1', () {
        expect(contrast(p.onAccent, p.accent), greaterThanOrEqualTo(4.5));
      });

      test('onAccentContainer on accentContainer is at least 4.5:1', () {
        expect(
          contrast(p.onAccentContainer, p.accentContainer),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('bubble text and meta are readable on their bubbles', () {
        expect(
          contrast(p.bubbleOutText, p.bubbleOut),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(p.bubbleOutMeta, p.bubbleOut),
          greaterThanOrEqualTo(4.5),
        );
        expect(contrast(p.bubbleInText, p.bubbleIn), greaterThanOrEqualTo(4.5));
        expect(contrast(p.bubbleInMeta, p.bubbleIn), greaterThanOrEqualTo(4.5));
      });

      test('read tick is at least 3:1 on the outgoing bubble', () {
        expect(contrast(p.tickRead, p.bubbleOut), greaterThanOrEqualTo(3));
      });

      test('text stays readable on chat canvas, input fill and selection', () {
        for (final ground in [
          p.chatBackground,
          p.inputFill,
          p.selection,
          p.elevated,
        ]) {
          expect(contrast(p.textPrimary, ground), greaterThanOrEqualTo(4.5));
          expect(contrast(p.textSecondary, ground), greaterThanOrEqualTo(4.5));
          expect(contrast(p.textMuted, ground), greaterThanOrEqualTo(4.5));
        }
        expect(
          contrast(p.onSystemChip, p.systemChip),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('avatar initials are readable on every avatar colour', () {
        expect(p.avatarOnColors.length, p.avatarColors.length);
        for (var i = 0; i < p.avatarColors.length; i++) {
          expect(
            contrast(p.avatarOnColors[i], p.avatarColors[i]),
            greaterThanOrEqualTo(4.5),
            reason: 'avatar colour $i',
          );
        }
      });

      test('story ring is at least 3:1 on the background', () {
        expect(contrast(p.storyRing, p.background), greaterThanOrEqualTo(3));
      });
    });
  });
}
