import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/calls/call_service.dart';
import 'package:securelyhello/core/calls/call_system.dart';

class FakeNotifier implements IncomingCallNotifier {
  final shown = <String>[];
  int cancelled = 0;

  @override
  Future<void> showIncomingCall({required String callId, required String name, required bool video}) async =>
      shown.add('$callId|$name|$video');

  @override
  Future<void> cancelIncomingCall() async => cancelled++;
}

class Source extends ChangeNotifier {
  ActiveCall? call;
  void set(ActiveCall? c) {
    call = c;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('securelyhello/call');
  late List<MethodCall> native;
  late Source source;
  late FakeNotifier notifier;
  late List<String> actions;
  late CallSystem system;

  setUp(() {
    native = [];
    actions = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
      native.add(c);
      return true;
    });
    source = Source();
    notifier = FakeNotifier();
    system = CallSystem(
      listenable: source,
      current: () => source.call,
      nameOf: (peer) => 'Name of $peer',
      notifier: notifier,
      onAction: (a) async => actions.add(a),
      enabled: true,
    );
  });

  tearDown(() {
    system.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('what the phone shows for each phase', () {
    final incoming = ActiveCall(id: 'c', peer: 'p', video: false, outgoing: false);
    expect(CallSystem.uiFor(null), CallUi.none);
    expect(CallSystem.uiFor(incoming), CallUi.ringing);
    final out = ActiveCall(id: 'c', peer: 'p', video: false, outgoing: true);
    expect(CallSystem.uiFor(out), CallUi.outgoing);
    out.phase = CallPhase.active;
    expect(CallSystem.uiFor(out), CallUi.ongoing);
    out.phase = CallPhase.ended;
    expect(CallSystem.uiFor(out), CallUi.none);
  });

  test('an incoming call rings like a phone; answering moves it to the call service', () async {
    final c = ActiveCall(id: 'c1', peer: 'mira', video: true, outgoing: false);
    source.set(c);
    await settle();
    expect(notifier.shown, ['c1|Name of mira|true']);
    expect(native.map((m) => m.method), contains('ringing'));

    c.phase = CallPhase.connecting;
    source.set(c);
    await settle();
    expect(notifier.cancelled, 1, reason: 'ringing stops');
    final ongoing = native.lastWhere((m) => m.method == 'ongoing');
    expect((ongoing.arguments as Map)['name'], 'Name of mira');
    expect((ongoing.arguments as Map)['video'], isTrue);
    expect(native.where((m) => m.method == 'pip').last.arguments, {'enabled': true}, reason: 'video: PiP');

    c.phase = CallPhase.ended;
    source.set(c);
    await settle();
    expect(native.last.method, 'stop');
  });

  test('voice calls use the proximity sensor unless on speaker', () async {
    final c = ActiveCall(id: 'c2', peer: 'p', video: false, outgoing: true)..phase = CallPhase.active;
    source.set(c);
    await settle();
    expect(native.where((m) => m.method == 'proximity').last.arguments, {'on': true});
    c.speakerOn = true;
    source.set(c);
    await settle();
    expect(native.where((m) => m.method == 'proximity').last.arguments, {'on': false});
  });

  test('the same state is not sent twice', () async {
    final c = ActiveCall(id: 'c3', peer: 'p', video: false, outgoing: true)..phase = CallPhase.active;
    source.set(c);
    await settle();
    final n = native.length;
    source.set(c);
    await settle();
    expect(native.length, n);
  });

  test('Hang up / Mute / open from the notification reach the app', () async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'securelyhello/call',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('action', {'action': 'hangup'})),
      (_) {},
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'securelyhello/call',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('pip', {'on': true})),
      (_) {},
    );
    expect(actions, ['hangup']);
    expect(system.inPictureInPicture.value, isTrue);
  });

  test('off elsewhere: nothing is sent', () async {
    final off = CallSystem(
      listenable: source,
      current: () => source.call,
      nameOf: (p) => p,
      notifier: notifier,
      onAction: (_) async {},
      enabled: false,
    );
    native.clear();
    source.set(ActiveCall(id: 'c', peer: 'p', video: false, outgoing: false));
    await settle();
    expect(native.where((m) => m.method == 'ringing'), hasLength(1), reason: 'only the enabled one');
    off.dispose();
  });
}
