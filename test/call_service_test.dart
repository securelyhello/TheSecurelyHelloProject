import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:securelyhello/core/calls/call_service.dart';
import 'package:securelyhello/core/chat/wire_protocol.dart';

void main() {
  ActiveCall call({bool outgoing = true, bool video = false, Duration? talked}) {
    final c = ActiveCall(id: 'c', peer: 'p', video: video, outgoing: outgoing);
    if (talked != null) c.connectedAt = DateTime.now().subtract(talked);
    return c;
  }

  String notice(ActiveCall c, CallEnd why, {bool ringing = false}) =>
      CallService.callNotice(c, why, wasActive: c.connectedAt != null, ringing: ringing);

  test('call records in the chat', () {
    expect(notice(call(talked: const Duration(minutes: 2, seconds: 31)), CallEnd.hungUp),
        'Outgoing voice call · 2:31');
    expect(notice(call(outgoing: false, video: true, talked: const Duration(seconds: 9)), CallEnd.hungUp),
        'Incoming video call · 0:09');
    expect(notice(call(), CallEnd.declined), 'Outgoing voice call · Declined');
    expect(notice(call(), CallEnd.busy), 'Outgoing voice call · Busy');
    expect(notice(call(), CallEnd.noAnswer), 'Outgoing voice call · No answer');
    expect(notice(call(outgoing: false), CallEnd.noAnswer, ringing: true), 'Missed voice call');
    expect(notice(call(outgoing: false), CallEnd.hungUp, ringing: true), 'Missed voice call',
        reason: 'the caller gave up');
    expect(notice(call(outgoing: false, video: true), CallEnd.declined, ringing: true), 'Declined video call');
    expect(notice(call(outgoing: false), CallEnd.elsewhere, ringing: true), 'Voice call answered on another device');
  });

  test('clock', () {
    expect(CallService.clock(Duration.zero), '0:00');
    expect(CallService.clock(const Duration(seconds: 65)), '1:05');
    expect(CallService.clock(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
  });

  test('call signals are checked like any payload', () {
    Uint8List wire(Object? call) =>
        Uint8List.fromList(utf8.encode(jsonEncode({'k': 'call', 'from': 'a', 'to': 'b', 't': 1, 'call': call})));
    final ok = WirePayload.decode(wire({'id': 'x', 't': 'offer', 'sdp': 'v=0'}));
    expect(ok.call!['sdp'], 'v=0');
    for (final bad in [
      null,
      {'t': 'offer'},
      {'id': '', 't': 'offer'},
      {'id': 'x' * 65, 't': 'ice'},
      {'id': 'x', 't': 'dance'},
      'offer',
    ]) {
      expect(() => WirePayload.decode(wire(bad)), throwsFormatException, reason: '$bad');
    }
  });

  // Regression: the other side dropped 4–5 s after a hang-up. The hang-up
  // now also goes over the call's own data channel.
  test('control-channel hang-ups', () {
    expect(CallService.parseControlHangUp('{"t":"end","id":"c1","r":"hangup"}', 'c1'), CallEnd.hungUp);
    expect(CallService.parseControlHangUp('{"t":"end","id":"c1","r":"declined"}', 'c1'), CallEnd.declined);
    expect(CallService.parseControlHangUp('{"t":"end","id":"c2","r":"hangup"}', 'c1'), isNull,
        reason: 'another call');
    expect(CallService.parseControlHangUp('{"t":"ice","id":"c1"}', 'c1'), isNull);
    expect(CallService.parseControlHangUp('not json', 'c1'), isNull);
    expect(CallService.parseControlHangUp('[1]', 'c1'), isNull);
    expect(CallService.parseControlHangUp('{"t":"end","id":"c1","pad":"${'x' * 300}"}', 'c1'), isNull,
        reason: 'oversized');
  });

  test('low-bandwidth mode asks the camera for much less', () {
    final low = DeviceCallMedia.videoConstraints(low: true);
    final normal = DeviceCallMedia.videoConstraints(low: false);
    expect(low['width'] as int, lessThan(normal['width'] as int));
    expect(low['frameRate'], 15);
  });
}
