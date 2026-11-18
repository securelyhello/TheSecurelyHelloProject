import 'package:flutter/foundation.dart';

/// Turns [debugPrint] into a no-op in release builds so diagnostic lines
/// (device addresses, contact ids, error details) never reach the system
/// log (logcat, Console, journald).
void silenceDebugPrintInRelease({bool release = kReleaseMode}) {
  if (!release) return;
  debugPrint = (String? message, {int? wrapWidth}) {};
}
