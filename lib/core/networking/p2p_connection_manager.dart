import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Connection lifecycle states for a single peer.
enum P2PConnectionState {
  idle,
  connecting,
  connected,
  disconnected,
  failed,
}

/// Payload emitted when a local ICE candidate is gathered.
class IceCandidateEvent {
  final String contactId;
  final RTCIceCandidate candidate;
  const IceCandidateEvent(this.contactId, this.candidate);
}

/// Payload emitted when a peer's connection state changes.
class ConnectionStateEvent {
  final String contactId;
  final P2PConnectionState state;
  const ConnectionStateEvent(this.contactId, this.state);
}

/// Payload emitted when an encrypted message arrives on a data channel.
class DataChannelMessageEvent {
  final String contactId;
  final Uint8List data;
  const DataChannelMessageEvent(this.contactId, this.data);
}

/// Manages one [RTCPeerConnection] + [RTCDataChannel] per remote device.
///
/// Peers are keyed by an opaque string; `ChatService` uses the device
/// address `userId:deviceId`, and the `*WithPrefix` helpers answer
/// questions about all devices of one user (`'$userId:'`).
///
/// A peer only counts as [P2PConnectionState.connected] once its data
/// channel is open, so [isConnected] is a reliable "can send right now"
/// signal.  The class exposes broadcast [Stream]s for ICE candidates,
/// connection-state changes, and incoming data-channel messages so that the
/// higher-level `ChatService` can react without tight coupling.
class P2PConnectionManager {
  // ---- ICE server configuration ------------------------------------------
  static const List<Map<String, dynamic>> defaultStunServers = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
  ];

  List<Map<String, dynamic>> _iceServers = defaultStunServers;

  /// Short-lived TURN credentials from our server (GET /api/turn).
  Map<String, dynamic>? _serverTurn;

  /// The ICE servers in use, for calls too.
  List<Map<String, dynamic>> get iceServers => [..._iceServers, ?_serverTurn];

  /// Replaces the server-issued TURN entry (null removes it).
  void setServerTurn(Map<String, dynamic>? turn) => _serverTurn = turn;

  // ---- Per-contact state -------------------------------------------------
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, RTCDataChannel> _dataChannels = {};
  final Map<String, P2PConnectionState> _connectionStates = {};
  final Set<String> _remoteDescriptionSet = {};
  final Map<String, List<RTCIceCandidate>> _pendingRemoteCandidates = {};

  // ---- Broadcast streams -------------------------------------------------
  final StreamController<IceCandidateEvent> _iceCandidateController =
      StreamController<IceCandidateEvent>.broadcast();
  final StreamController<ConnectionStateEvent> _connectionStateController =
      StreamController<ConnectionStateEvent>.broadcast();
  final StreamController<DataChannelMessageEvent> _dataMessageController =
      StreamController<DataChannelMessageEvent>.broadcast();

  /// Emitted when a local ICE candidate is gathered and must be relayed to the
  /// remote peer via the signaling server.
  Stream<IceCandidateEvent> get onIceCandidate =>
      _iceCandidateController.stream;

  /// Emitted when a peer's connection state changes.
  Stream<ConnectionStateEvent> get onConnectionStateChange =>
      _connectionStateController.stream;

  /// Emitted when an encrypted binary message arrives over a data channel.
  Stream<DataChannelMessageEvent> get onDataChannelMessage =>
      _dataMessageController.stream;

  // Lifecycle

  /// Sets the ICE servers.  Pass TURN entries here so peers behind symmetric
  /// NAT (most mobile carriers) can still connect.
  Future<void> init({List<Map<String, dynamic>>? iceServers}) async {
    if (iceServers != null && iceServers.isNotEmpty) {
      _iceServers = iceServers;
    }
  }

  // Offer / Answer

  /// Creates a new [RTCPeerConnection] for [contactId], opens a data channel
  /// named `"chat"`, generates an SDP offer, and returns it.
  Future<String> createOffer(String contactId) async {
    final pc = await _createPeerConnection(contactId);

    // Create the data channel before the offer so it's included in the SDP.
    final dc = await pc.createDataChannel(
        'chat', RTCDataChannelInit()..ordered = true);
    _registerDataChannel(contactId, pc, dc);

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _setConnectionState(contactId, P2PConnectionState.connecting);

    return offer.sdp!;
  }

  /// Handles an incoming SDP offer from [contactId]: replaces any existing
  /// connection, sets the remote description, and returns the SDP answer.
  Future<String> handleOffer(String contactId, String sdpOffer) async {
    final pc = await _createPeerConnection(contactId);

    await pc.setRemoteDescription(RTCSessionDescription(sdpOffer, 'offer'));
    await _markRemoteDescriptionSet(contactId, pc);

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    _setConnectionState(contactId, P2PConnectionState.connecting);

    return answer.sdp!;
  }

  /// Applies an incoming SDP answer from [contactId].
  Future<void> handleAnswer(String contactId, String sdpAnswer) async {
    final pc = _peerConnections[contactId];
    if (pc == null) {
      throw StateError('No peer connection exists for contact $contactId');
    }
    await pc.setRemoteDescription(RTCSessionDescription(sdpAnswer, 'answer'));
    await _markRemoteDescriptionSet(contactId, pc);
  }

  /// Adds a trickled ICE candidate from [contactId].  Candidates that arrive
  /// before the remote description are buffered and applied afterwards.
  Future<void> addIceCandidate(
    String contactId,
    Map<String, dynamic> candidate,
  ) async {
    final pc = _peerConnections[contactId];
    if (pc == null) return;

    final ice = RTCIceCandidate(
      candidate['candidate'] as String?,
      candidate['sdpMid'] as String?,
      candidate['sdpMLineIndex'] as int?,
    );
    if (!_remoteDescriptionSet.contains(contactId)) {
      _pendingRemoteCandidates.putIfAbsent(contactId, () => []).add(ice);
      return;
    }
    await pc.addCandidate(ice);
  }

  Future<void> _markRemoteDescriptionSet(
      String contactId, RTCPeerConnection pc) async {
    _remoteDescriptionSet.add(contactId);
    final pending = _pendingRemoteCandidates.remove(contactId) ?? const [];
    for (final ice in pending) {
      try {
        await pc.addCandidate(ice);
      } catch (_) {
        // A stale or duplicate candidate — safe to skip.
      }
    }
  }

  // Messaging

  /// Sends [data] over the open data channel to [contactId].
  ///
  /// Returns `false` (without queueing) if no open channel exists; the caller
  /// is expected to fall back to the relay.
  Future<bool> sendMessage(String contactId, Uint8List data) async {
    final dc = _dataChannels[contactId];
    if (dc == null || dc.state != RTCDataChannelState.RTCDataChannelOpen) {
      return false;
    }
    try {
      await dc.send(RTCDataChannelMessage.fromBinary(data));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Returns the current connection state for [contactId].
  P2PConnectionState getConnectionState(String contactId) {
    return _connectionStates[contactId] ?? P2PConnectionState.idle;
  }

  /// `true` if a data channel to [contactId] is open and usable.
  bool isConnected(String contactId) {
    return getConnectionState(contactId) == P2PConnectionState.connected;
  }

  /// The best state among peers whose key starts with [prefix] (e.g. every
  /// device of one contact).
  P2PConnectionState bestStateWithPrefix(String prefix) {
    const order = [
      P2PConnectionState.connected,
      P2PConnectionState.connecting,
      P2PConnectionState.disconnected,
      P2PConnectionState.failed,
      P2PConnectionState.idle,
    ];
    var best = P2PConnectionState.idle;
    for (final e in _connectionStates.entries) {
      if (!e.key.startsWith(prefix)) continue;
      if (order.indexOf(e.value) < order.indexOf(best)) best = e.value;
    }
    return best;
  }

  /// `true` if any peer under [prefix] has an open channel.
  bool hasConnectionWithPrefix(String prefix) =>
      bestStateWithPrefix(prefix) == P2PConnectionState.connected;

  /// Closes every peer under [prefix].
  Future<void> closeConnectionsWithPrefix(String prefix) async {
    for (final key in _connectionStates.keys.toList()) {
      if (key.startsWith(prefix)) await closeConnection(key);
    }
  }

  /// `true` if any peer connection object exists for [contactId].
  bool hasPeer(String contactId) => _peerConnections.containsKey(contactId);

  // Cleanup

  /// Tears down only the connection for [contactId].
  Future<void> closeConnection(String contactId) async {
    await _closeConnection(contactId);
    _setConnectionState(contactId, P2PConnectionState.disconnected);
  }

  /// Tears down every peer connection (sign-out).  The manager stays usable.
  Future<void> closeAll() async {
    for (final contactId in _peerConnections.keys.toList()) {
      await closeConnection(contactId);
    }
    _connectionStates.clear();
  }

  /// Tears down everything, including the broadcast streams.
  Future<void> dispose() async {
    await closeAll();
    await _iceCandidateController.close();
    await _connectionStateController.close();
    await _dataMessageController.close();
  }

  // Internals

  Future<RTCPeerConnection> _createPeerConnection(String contactId) async {
    if (_peerConnections.containsKey(contactId)) {
      await _closeConnection(contactId);
    }

    final pc = await createPeerConnection({'iceServers': iceServers}, {});
    bool isCurrent() => identical(_peerConnections[contactId], pc);

    pc.onIceCandidate = (candidate) {
      if (isCurrent() && candidate.candidate != null) {
        _iceCandidateController.add(IceCandidateEvent(contactId, candidate));
      }
    };

    pc.onIceConnectionState = (state) {
      if (!isCurrent()) return;
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          // ICE recovered; usable again only if the channel is still open.
          if (_dataChannels[contactId]?.state ==
              RTCDataChannelState.RTCDataChannelOpen) {
            _setConnectionState(contactId, P2PConnectionState.connected);
          }
          break;
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          // May recover on its own; stop routing messages here meanwhile.
          _setConnectionState(contactId, P2PConnectionState.disconnected);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _setConnectionState(contactId, P2PConnectionState.failed);
          unawaited(_closeConnection(contactId));
          break;
        default:
          break;
      }
    };

    // The answerer receives the data channel via this callback.
    pc.onDataChannel = (channel) {
      if (isCurrent()) _registerDataChannel(contactId, pc, channel);
    };

    _peerConnections[contactId] = pc;
    _remoteDescriptionSet.remove(contactId);
    _pendingRemoteCandidates.remove(contactId);
    _connectionStates[contactId] = P2PConnectionState.idle;
    return pc;
  }

  void _registerDataChannel(
      String contactId, RTCPeerConnection pc, RTCDataChannel dc) {
    _dataChannels[contactId] = dc;
    bool isCurrent() =>
        identical(_peerConnections[contactId], pc) &&
        identical(_dataChannels[contactId], dc);

    dc.onMessage = (msg) {
      if (!isCurrent()) return;
      final data = msg.isBinary
          ? msg.binary
          : Uint8List.fromList(utf8.encode(msg.text));
      _dataMessageController.add(DataChannelMessageEvent(contactId, data));
    };

    dc.onDataChannelState = (state) {
      if (!isCurrent()) return;
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _setConnectionState(contactId, P2PConnectionState.connected);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _setConnectionState(contactId, P2PConnectionState.disconnected);
        unawaited(_closeConnection(contactId));
      }
    };
  }

  void _setConnectionState(String contactId, P2PConnectionState state) {
    final previous = _connectionStates[contactId];
    if (previous == state) return;
    _connectionStates[contactId] = state;
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(ConnectionStateEvent(contactId, state));
    }
  }

  Future<void> _closeConnection(String contactId) async {
    final dc = _dataChannels.remove(contactId);
    final pc = _peerConnections.remove(contactId);
    _remoteDescriptionSet.remove(contactId);
    _pendingRemoteCandidates.remove(contactId);
    // Closing the peer connection closes its data channel. The channel is
    // deliberately not closed on its own first: flutter_webrtc tears down
    // the channel's Dart streams in close() while the native side can still
    // deliver a final state event, which surfaces as an unhandled
    // "Cannot add new events after calling close".
    dc?.onMessage = null;
    dc?.onDataChannelState = null;
    try {
      await pc?.close();
    } catch (_) {}
  }
}
