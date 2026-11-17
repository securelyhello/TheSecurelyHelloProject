import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:securelyhello/core/crypto/verify_code.dart';

/// Our side of the verification QR code.
Future<void> showVerifyQr(BuildContext context, {required String data, required String name}) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Let $name scan this'),
        content: SizedBox(
          width: 260,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: QrImageView(
                key: const ValueKey('verify-qr'),
                data: data,
                size: 236,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            const Text('They open your contact info on their phone and tap Scan.'),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
      ),
    );

/// Camera scanning is available on phones and Macs.
bool get canScanQr =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

/// Opens the camera and returns the first QR payload seen, or null.
Future<String?> scanVerifyQr(BuildContext context) => Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _ScanScreen()),
    );

class _ScanScreen extends StatefulWidget {
  const _ScanScreen();

  @override
  State<_ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<_ScanScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scan their code')),
        body: MobileScanner(
          onDetect: (capture) {
            final raw = capture.barcodes.firstOrNull?.rawValue;
            if (_done || raw == null) return;
            _done = true;
            Navigator.pop(context, raw);
          },
        ),
      );
}

/// What to tell the user after a scan.
String verifyResultText(VerifyResult r, String name) => switch (r) {
      VerifyResult.match => 'Verified. Your safety numbers with $name match.',
      VerifyResult.mismatch =>
        "The safety numbers don't match. Don't mark $name as verified; someone "
            'may be intercepting. Check again in person.',
      VerifyResult.wrongPerson => "That code belongs to someone else's chat.",
      VerifyResult.notACode => "That isn't a Securely Hello verification code.",
    };

/// Small badge shown next to verified contacts' names.
class VerifiedBadge extends StatelessWidget {
  final double size;
  const VerifiedBadge({super.key, this.size = 16});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Verified',
        child: Icon(LucideIcons.badgeCheck, size: size, color: Theme.of(context).colorScheme.primary),
      );
}
