import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:securelyhello/core/calls/call_service.dart';

/// What the phone shows for the current call.
enum CallUi { none, ringing, outgoing, ongoing }

/// Shows the incoming-call notification (full-screen on a locked phone,
/// Accept / Decline). NotificationService implements it.
abstract class IncomingCallNotifier {
  Future<void> showIncomingCall({required String callId, required String name, required bool video});
  Future<void> cancelIncomingCall();
}

/// Ties calls to Android (android/…/CallBridge.kt): an incoming call rings
/// like a phone call, a call in progress runs in a foreground service with
/// an ongoing notification (Hang up / Mute), voice calls use the proximity
/// sensor, and video calls go picture-in-picture when the user leaves the
/// app. Elsewhere it does nothing.
class CallSystem {
  CallSystem({
    required Listenable listenable,
    required ActiveCall? Function() current,
    required String Function(String peer) nameOf,
    required IncomingCallNotifier notifier,
    required Future<void> Function(String action) onAction,
    bool? enabled,
    MethodChannel channel = const MethodChannel('securelyhello/call'),
  })  : _listenable = listenable,
        _current = current,
        _nameOf = nameOf,
        _notifier = notifier,
        _onAction = onAction,
        _channel = channel,
        enabled = enabled ?? (!kIsWeb && Platform.isAndroid) {
    if (!this.enabled) return;
    _listenable.addListener(_sync);
    _channel.setMethodCallHandler(_fromNative);
    _sync();
  }

  /// Wires a [CallService]: actions from the notification hang up, mute or
  /// show the call ([onOpen]).
  factory CallSystem.forService(
    CallService calls, {
    required String Function(String peer) nameOf,
    required IncomingCallNotifier notifier,
    void Function()? onOpen,
  }) =>
      CallSystem(
        listenable: calls,
        current: () => calls.call,
        nameOf: nameOf,
        notifier: notifier,
        onAction: (a) async {
          switch (a) {
            case 'hangup':
              await calls.hangUp();
            case 'mute':
              calls.toggleMute();
            case 'open':
              onOpen?.call();
          }
        },
      );

  final Listenable _listenable;
  final ActiveCall? Function() _current;
  final String Function(String peer) _nameOf;
  final IncomingCallNotifier _notifier;
  final Future<void> Function(String action) _onAction;
  final MethodChannel _channel;
  final bool enabled;

  /// True while the app is a picture-in-picture window.
  final ValueNotifier<bool> inPictureInPicture = ValueNotifier(false);

  String? _sent;

  static CallUi uiFor(ActiveCall? c) => switch (c?.phase) {
        null || CallPhase.ended => CallUi.none,
        CallPhase.incoming => CallUi.ringing,
        CallPhase.outgoing => CallUi.outgoing,
        CallPhase.connecting || CallPhase.active => CallUi.ongoing,
      };

  void _sync() {
    final c = _current();
    final ui = uiFor(c);
    // Everything the native side shows, so unchanged states aren't resent.
    final key = c == null
        ? 'none'
        : '$ui|${c.id}|${c.muted}|${c.speakerOn}|${c.connectedAt?.millisecondsSinceEpoch}';
    if (key == _sent) return;
    final previous = _sent;
    _sent = key;
    unawaited(_apply(c, ui, wasRinging: previous?.startsWith('${CallUi.ringing}') ?? false));
  }

  Future<void> _apply(ActiveCall? c, CallUi ui, {required bool wasRinging}) async {
    try {
      if (ui != CallUi.ringing && wasRinging) await _notifier.cancelIncomingCall();
      switch (ui) {
        case CallUi.none:
          await _channel.invokeMethod('stop');
        case CallUi.ringing:
          await _notifier.showIncomingCall(callId: c!.id, name: _nameOf(c.peer), video: c.video);
          await _channel.invokeMethod('ringing');
        case CallUi.outgoing:
        case CallUi.ongoing:
          await _channel.invokeMethod('ongoing', {
            'name': _nameOf(c!.peer),
            'video': c.video,
            'muted': c.muted,
            'outgoing': ui == CallUi.outgoing,
            'since': c.connectedAt?.millisecondsSinceEpoch ?? 0,
          });
          await _channel.invokeMethod('proximity', {'on': !c.video && !c.speakerOn});
          await _channel.invokeMethod('pip', {'enabled': c.video});
      }
    } on MissingPluginException {
      // Not on Android, or tests without the native side.
    } catch (e) {
      debugPrint('Call system update failed: $e');
    }
  }

  Future<Object?> _fromNative(MethodCall call) async {
    final args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'action':
        final a = args['action'];
        if (a is String) await _onAction(a);
      case 'pip':
        inPictureInPicture.value = args['on'] == true;
    }
    return null;
  }

  /// Whether Android lets the call notification take the full screen
  /// (Android 14+ can withdraw it).
  Future<bool> canUseFullScreen() async {
    if (!enabled) return true;
    try {
      return await _channel.invokeMethod<bool>('canFullScreen') ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> openFullScreenSettings() async {
    try {
      await _channel.invokeMethod('openFullScreenSettings');
    } catch (_) {}
  }

  void dispose() {
    if (!enabled) return;
    _listenable.removeListener(_sync);
    _channel.setMethodCallHandler(null);
    inPictureInPicture.dispose();
  }
}

/// Provided to the widget tree: the app's [CallSystem] and what to do when
/// the ongoing-call notification is tapped (set by the home screen).
class CallSystemHolder {
  CallSystemHolder(CallService calls, {required String Function(String peer) nameOf, required IncomingCallNotifier notifier}) {
    system = CallSystem.forService(calls, nameOf: nameOf, notifier: notifier, onOpen: () => onOpen?.call());
  }

  late final CallSystem system;
  void Function()? onOpen;
}
