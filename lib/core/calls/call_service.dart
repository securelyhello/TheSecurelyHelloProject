import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import 'package:securelyhello/core/chat/chat_service.dart';

/// Where a call is.
enum CallPhase {
  /// We're calling; their devices are ringing.
  outgoing,

  /// They're calling; this device is ringing.
  incoming,

  /// Answered; media is being connected.
  connecting,
  active,
  ended,
}

/// Why a call ended.
enum CallEnd {
  hungUp('hangup'),
  declined('declined'),
  busy('busy'),
  noAnswer('noanswer'),
  failed('failed'),

  /// Another of our devices answered or declined.
  elsewhere('elsewhere');

  const CallEnd(this.wire);
  final String wire;

  static CallEnd fromWire(Object? v) =>
      CallEnd.values.firstWhere((e) => e.wire == v, orElse: () => CallEnd.hungUp);
}

/// A 1:1 voice or video call.
class ActiveCall {
  ActiveCall({required this.id, required this.peer, required this.video, required this.outgoing, this.peerDevice})
      : phase = outgoing ? CallPhase.outgoing : CallPhase.incoming;

  final String id;

  /// The contact's user id.
  final String peer;
  final bool video;
  final bool outgoing;

  /// The one device of [peer] this call is with: the caller's, or whichever
  /// of the callee's devices answered.
  String? peerDevice;
  CallPhase phase;
  DateTime? connectedAt;
  CallEnd? endedBy;

  bool muted = false;
  bool cameraOff = false;
  bool speakerOn = false;

  /// No microphone or camera could be opened; the call still connects and
  /// we can hear and see them.
  bool mediaUnavailable = false;

  MediaStream? localStream;
  MediaStream? remoteStream;

  Duration get elapsed => connectedAt == null ? Duration.zero : DateTime.now().difference(connectedAt!);
}

/// Opens the microphone (and camera) for a call.
abstract class CallMedia {
  /// The local stream, or null if nothing could be opened.
  Future<MediaStream?> open({required bool video});
}

class DeviceCallMedia implements CallMedia {
  const DeviceCallMedia();

  @override
  Future<MediaStream?> open({required bool video}) async {
    try {
      return await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': video ? {'facingMode': 'user', 'width': 1280, 'height': 720} : false,
      });
    } catch (e) {
      debugPrint('No call media: $e');
      if (!video) return null;
      // Fall back to a voice-only stream rather than nothing.
      try {
        return await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
      } catch (_) {
        return null;
      }
    }
  }
}

/// For tests and machines without capture devices.
class NoCallMedia implements CallMedia {
  const NoCallMedia();

  @override
  Future<MediaStream?> open({required bool video}) async => null;
}

/// Voice and video calls with contacts.
///
/// Signaling (offer, answer, ICE candidates, hang-up) travels end to end in
/// `call` payloads over the same Double Ratchet sessions as messages. That
/// matters: the SDP carries the DTLS fingerprints that key the media, so a
/// server that could change it could listen in. Media then flows over WebRTC
/// (DTLS-SRTP), directly or through the configured TURN relay.
///
/// Every device of the callee rings; the first to answer takes the call and
/// tells our other devices to stop. Only one call at a time.
class CallService extends ChangeNotifier {
  CallService({
    required ChatService chat,
    required bool Function(String userId) canCall,
    // Empty: the chat's servers (STUN, plus our server's TURN relay).
    List<Map<String, dynamic>> iceServers = const [],
    CallMedia media = const DeviceCallMedia(),
    this.ringTimeout = const Duration(seconds: 45),
  })  : _chat = chat,
        _canCall = canCall,
        _iceServers = iceServers,
        _media = media {
    _sub = chat.onCallSignal.listen((s) => unawaited(_onSignal(s)));
  }

  final ChatService _chat;
  final bool Function(String userId) _canCall;
  final List<Map<String, dynamic>> _iceServers;
  final CallMedia _media;
  final Duration ringTimeout;

  /// Offers older than this are reported as missed rather than ringing
  /// (e.g. queued while the app was closed).
  static const maxOfferAge = Duration(seconds: 60);

  late final StreamSubscription<CallSignal> _sub;
  final _incoming = StreamController<ActiveCall>.broadcast();

  ActiveCall? _call;
  RTCPeerConnection? _pc;
  Timer? _ringTimer;
  Timer? _iceTimer;
  Timer? _clearTimer;
  String? _offerSdp;
  bool _remoteSet = false;
  final List<RTCIceCandidate> _pendingRemote = [];
  final List<Map<String, dynamic>> _pendingLocal = [];

  /// The current call, also for a moment after it ended.
  ActiveCall? get call => _call;

  bool get busy => _call != null && _call!.phase != CallPhase.ended;

  /// A call starts ringing on this device.
  Stream<ActiveCall> get onIncoming => _incoming.stream;

  /// Calls [peer]. Throws [StateError] while another call is going on.
  Future<ActiveCall> start(String peer, {bool video = false}) async {
    if (busy) throw StateError('Already in a call');
    if (!_canCall(peer)) throw StateError('You can only call your contacts');
    final c = ActiveCall(id: const Uuid().v4(), peer: peer, video: video, outgoing: true);
    _reset(c);
    notifyListeners();
    try {
      await _openMedia(c);
      final pc = await _newConnection(c);
      final local = c.localStream;
      for (final kind in [RTCRtpMediaType.RTCRtpMediaTypeAudio, if (video) RTCRtpMediaType.RTCRtpMediaTypeVideo]) {
        final tracks = kind == RTCRtpMediaType.RTCRtpMediaTypeAudio
            ? local?.getAudioTracks() ?? const <MediaStreamTrack>[]
            : local?.getVideoTracks() ?? const <MediaStreamTrack>[];
        // Without a track the transceiver is still negotiated, so the call
        // connects and we receive their media.
        final track = tracks.firstOrNull;
        final init = RTCRtpTransceiverInit(
          direction: TransceiverDirection.SendRecv,
          streams: local == null || track == null ? null : [local],
        );
        if (track != null) {
          await pc.addTransceiver(track: track, kind: kind, init: init);
        } else {
          await pc.addTransceiver(kind: kind, init: init);
        }
      }
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      if (!identical(_call, c)) return c; // hung up meanwhile
      final sent = await _chat.sendCallSignal(peer, {'id': c.id, 't': 'offer', 'sdp': offer.sdp, 'video': video});
      if (!sent) throw StateError("Couldn't reach them");
      _ringTimer = Timer(ringTimeout, () => unawaited(_end(c, CallEnd.noAnswer, tell: true)));
    } catch (e) {
      debugPrint('Call to $peer failed: $e');
      await _end(c, CallEnd.failed, tell: true);
      rethrow;
    }
    return c;
  }

  /// Answers the ringing call ([video] false answers a video call with
  /// voice only).
  Future<void> accept({bool? video}) async {
    final c = _call;
    final sdp = _offerSdp;
    if (c == null || c.phase != CallPhase.incoming || sdp == null) return;
    _ringTimer?.cancel();
    c.phase = CallPhase.connecting;
    notifyListeners();
    try {
      await _openMedia(c, video: video ?? c.video);
      final pc = await _newConnection(c);
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      _remoteSet = true;
      // addTrack reuses the transceivers the offer created and labels the
      // stream, so the caller receives our tracks as one stream.
      final local = c.localStream;
      if (local != null) {
        for (final track in local.getTracks()) {
          await pc.addTrack(track, local);
        }
      }
      for (final t in await pc.getTransceivers()) {
        await t.setDirection(TransceiverDirection.SendRecv);
      }
      await _flushRemoteCandidates();
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      if (!identical(_call, c)) return;
      await _chat.sendCallSignal(c.peer, {'id': c.id, 't': 'answer', 'sdp': answer.sdp}, devices: {c.peerDevice!});
      _tellMyDevices(c, 'answered');
      _sendLocalCandidates(c);
    } catch (e) {
      debugPrint('Answering failed: $e');
      await _end(c, CallEnd.failed, tell: true);
    }
  }

  Future<void> decline() async {
    final c = _call;
    if (c == null || c.phase != CallPhase.incoming) return;
    _tellMyDevices(c, 'declined');
    await _end(c, CallEnd.declined, tell: true);
  }

  Future<void> hangUp() async {
    final c = _call;
    if (c == null || c.phase == CallPhase.ended) return;
    if (c.phase == CallPhase.incoming) return decline();
    await _end(c, c.phase == CallPhase.outgoing ? CallEnd.noAnswer : CallEnd.hungUp, tell: true);
  }

  void toggleMute() {
    final c = _call;
    if (c == null) return;
    c.muted = !c.muted;
    for (final t in c.localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !c.muted;
    }
    notifyListeners();
  }

  void toggleCamera() {
    final c = _call;
    if (c == null) return;
    c.cameraOff = !c.cameraOff;
    for (final t in c.localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !c.cameraOff;
    }
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final track = _call?.localStream?.getVideoTracks().firstOrNull;
    if (track == null) return;
    try {
      await Helper.switchCamera(track);
    } catch (e) {
      debugPrint('Camera switch failed: $e');
    }
  }

  Future<void> toggleSpeaker() async {
    final c = _call;
    if (c == null) return;
    c.speakerOn = !c.speakerOn;
    try {
      await Helper.setSpeakerphoneOn(c.speakerOn);
    } catch (_) {
      // Desktop: the system picks the output.
    }
    notifyListeners();
  }

  // Signaling

  Future<void> _onSignal(CallSignal s) async {
    final d = s.data;
    final id = d['id'] as String;
    final c = _call;
    final me = _chat.myUserId;
    if (s.from == me) {
      // Another of our devices answered or declined a call ringing here.
      if (d['t'] == 'taken' && c != null && c.id == id && c.phase == CallPhase.incoming) {
        await _end(c, d['r'] == 'declined' ? CallEnd.declined : CallEnd.elsewhere, tell: false);
      }
      return;
    }
    switch (d['t']) {
      case 'offer':
        await _onOffer(s, id);
      case 'answer':
        if (c == null || c.id != id || c.phase != CallPhase.outgoing || c.peer != s.from) return;
        final sdp = d['sdp'];
        if (sdp is! String) return;
        _ringTimer?.cancel();
        c.peerDevice = s.fromDevice;
        c.phase = CallPhase.connecting;
        notifyListeners();
        try {
          await _pc?.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
          _remoteSet = true;
          await _flushRemoteCandidates();
          _sendLocalCandidates(c);
        } catch (e) {
          debugPrint('Bad answer: $e');
          await _end(c, CallEnd.failed, tell: true);
        }
      case 'ice':
        if (c == null || c.id != id || c.peer != s.from || c.peerDevice != s.fromDevice) return;
        final list = d['cands'];
        if (list is! List) return;
        for (final x in list.take(50)) {
          if (x is! Map || x['c'] is! String) continue;
          final cand = RTCIceCandidate(x['c'] as String, x['m'] as String?, x['i'] as int?);
          if (_remoteSet) {
            await _addRemote(cand);
          } else {
            _pendingRemote.add(cand);
          }
        }
      case 'end':
        if (c == null || c.id != id || c.peer != s.from) return;
        if (c.peerDevice != null && c.peerDevice != s.fromDevice) return;
        await _end(c, CallEnd.fromWire(d['r']), tell: false);
    }
  }

  Future<void> _onOffer(CallSignal s, String id) async {
    final d = s.data;
    final video = d['video'] == true;
    final sdp = d['sdp'];
    if (sdp is! String || !_canCall(s.from)) return;
    final current = _call;
    if (current != null && current.id == id) return; // a copy we already have
    if (DateTime.now().difference(s.sentAt) > maxOfferAge) {
      await _chat.addCallNotice(s.from, _missed(video));
      return;
    }
    if (busy) {
      // Both called each other at once: the call with the smaller id wins.
      final glare = current!.outgoing &&
          current.peer == s.from &&
          current.phase == CallPhase.outgoing &&
          id.compareTo(current.id) < 0;
      if (!glare) {
        unawaited(_chat.sendCallSignal(s.from, {'id': id, 't': 'end', 'r': CallEnd.busy.wire},
            devices: {s.fromDevice}));
        await _chat.addCallNotice(s.from, _missed(video));
        return;
      }
      await _close(current); // theirs wins; no notice for ours
    }
    final c = ActiveCall(id: id, peer: s.from, video: video, outgoing: false, peerDevice: s.fromDevice);
    _reset(c);
    _offerSdp = sdp;
    _ringTimer = Timer(ringTimeout, () => unawaited(_end(c, CallEnd.noAnswer, tell: false)));
    notifyListeners();
    if (!_incoming.isClosed) _incoming.add(c);
  }

  void _tellMyDevices(ActiveCall c, String how) {
    final me = _chat.myUserId;
    if (me == null) return;
    unawaited(_chat
        .sendCallSignal(me, {'id': c.id, 't': 'taken', 'r': how})
        .catchError((Object e) {
      debugPrint('Telling our devices failed: $e');
      return false;
    }));
  }

  // Media and connection

  Future<void> _openMedia(ActiveCall c, {bool? video}) async {
    c.localStream = await _media.open(video: video ?? c.video);
    c.mediaUnavailable = c.localStream == null;
    if (!identical(_call, c)) {
      await _dispose(c.localStream);
      c.localStream = null;
    }
    notifyListeners();
  }

  Future<RTCPeerConnection> _newConnection(ActiveCall c) async {
    final pc = await createPeerConnection({
      'iceServers': _iceServers.isNotEmpty ? _iceServers : _chat.iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;
    pc.onIceCandidate = (cand) {
      if (cand.candidate == null || !identical(_call, c)) return;
      _pendingLocal.add({'c': cand.candidate, 'm': cand.sdpMid, 'i': cand.sdpMLineIndex});
      // Candidates trickle in quickly; send them in small batches.
      _iceTimer ??= Timer(const Duration(milliseconds: 150), () => _sendLocalCandidates(c));
    };
    pc.onTrack = (e) => unawaited(_onTrack(c, e));
    pc.onConnectionState = (state) {
      if (!identical(_call, c)) return;
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          if (c.phase != CallPhase.active) {
            c.phase = CallPhase.active;
            c.connectedAt = DateTime.now();
            notifyListeners();
          }
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          unawaited(_end(c, CallEnd.failed, tell: true));
        default:
          break;
      }
    };
    return pc;
  }

  Future<void> _onTrack(ActiveCall c, RTCTrackEvent e) async {
    // Both ends send their tracks as a stream; a track without one only
    // comes from a side that captured nothing, so there's nothing to show.
    if (!identical(_call, c) || e.streams.isEmpty) return;
    c.remoteStream = e.streams.first;
    notifyListeners();
  }

  void _sendLocalCandidates(ActiveCall c) {
    _iceTimer?.cancel();
    _iceTimer = null;
    final device = c.peerDevice;
    if (device == null || _pendingLocal.isEmpty || !identical(_call, c)) return;
    final batch = List.of(_pendingLocal);
    _pendingLocal.clear();
    unawaited(_chat
        .sendCallSignal(c.peer, {'id': c.id, 't': 'ice', 'cands': batch}, devices: {device})
        .catchError((Object e) {
      debugPrint('ICE to ${c.peer} failed: $e');
      return false;
    }));
  }

  Future<void> _flushRemoteCandidates() async {
    final list = List.of(_pendingRemote);
    _pendingRemote.clear();
    for (final cand in list) {
      await _addRemote(cand);
    }
  }

  Future<void> _addRemote(RTCIceCandidate cand) async {
    try {
      await _pc?.addCandidate(cand);
    } catch (e) {
      debugPrint('Skipped an ICE candidate: $e');
    }
  }

  // Ending

  void _reset(ActiveCall c) {
    _clearTimer?.cancel();
    _call = c;
    _offerSdp = null;
    _remoteSet = false;
    _pendingRemote.clear();
    _pendingLocal.clear();
  }

  Future<void> _end(ActiveCall c, CallEnd why, {required bool tell}) async {
    if (!identical(_call, c) || c.phase == CallPhase.ended) return;
    final wasActive = c.connectedAt != null;
    final phase = c.phase;
    c.endedBy = why;
    c.phase = CallPhase.ended;
    notifyListeners();
    if (tell) {
      unawaited(_chat
          .sendCallSignal(c.peer, {'id': c.id, 't': 'end', 'r': why.wire},
              devices: c.peerDevice == null ? null : {c.peerDevice!})
          .catchError((Object e) {
        debugPrint('Hang-up signal failed: $e');
        return false;
      }));
    }
    await _close(c);
    final notice = callNotice(c, why, wasActive: wasActive, ringing: phase == CallPhase.incoming);
    try {
      await _chat.addCallNotice(c.peer, notice);
    } catch (e) {
      debugPrint('Call notice not saved: $e');
    }
    // The call screen shows how it ended for a moment, then goes.
    _clearTimer = Timer(const Duration(milliseconds: 1500), () {
      if (identical(_call, c)) {
        _call = null;
        notifyListeners();
      }
    });
  }

  Future<void> _close(ActiveCall c) async {
    _ringTimer?.cancel();
    _iceTimer?.cancel();
    _iceTimer = null;
    final pc = _pc;
    _pc = null;
    try {
      await pc?.close();
    } catch (_) {}
    await _dispose(c.localStream);
    c.localStream = null;
    if (c.phase != CallPhase.ended) c.phase = CallPhase.ended;
  }

  Future<void> _dispose(MediaStream? s) async {
    if (s == null) return;
    for (final t in s.getTracks()) {
      try {
        await t.stop();
      } catch (_) {}
    }
    try {
      await s.dispose();
    } catch (_) {}
  }

  static String _kind(bool video) => video ? 'video call' : 'voice call';
  static String _missed(bool video) => 'Missed ${_kind(video)}';

  /// The line left in the chat after a call.
  @visibleForTesting
  static String callNotice(ActiveCall c, CallEnd why, {required bool wasActive, required bool ringing}) {
    final kind = _kind(c.video);
    final label = '${c.outgoing ? 'Outgoing' : 'Incoming'} $kind';
    if (wasActive) return '$label · ${clock(c.elapsed)}';
    if (c.outgoing) {
      return switch (why) {
        CallEnd.declined => '$label · Declined',
        CallEnd.busy => '$label · Busy',
        CallEnd.failed => '$label · Couldn’t connect',
        _ => '$label · No answer',
      };
    }
    return switch (why) {
      CallEnd.declined => 'Declined ${_kind(c.video)}',
      CallEnd.elsewhere => '${kind[0].toUpperCase()}${kind.substring(1)} answered on another device',
      CallEnd.failed when !ringing => '$label · Couldn’t connect',
      _ => _missed(c.video),
    };
  }

  /// m:ss, or h:mm:ss for long calls.
  static String clock(Duration d) {
    final s = d.inSeconds;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
    return '${h > 0 ? '$h:' : ''}$mm:${sec.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    final c = _call;
    if (c != null) unawaited(_close(c));
    _clearTimer?.cancel();
    unawaited(_incoming.close());
    super.dispose();
  }
}
