import 'dart:async';
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

/// Payload emitted when a remote ICE candidate is gathered.
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

/// Manages one [RTCPeerConnection] + [RTCDataChannel] per remote contact.
///
/// The class exposes three broadcast [Stream]s for ICE candidates,
/// connection-state changes, and incoming data-channel messages so that the
/// higher-level [ChatService] can react without tight coupling.
class P2PConnectionManager {
  // ---- ICE server configuration ------------------------------------------
  static const Map<String, dynamic> _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
  };



  // ---- Per-contact state -------------------------------------------------
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, RTCDataChannel> _dataChannels = {};
  final Map<String, P2PConnectionState> _connectionStates = {};
  final Map<String, StreamController<Uint8List>> _messageControllers = {};

  // Queues messages that arrive before the data channel is open.
  final Map<String, List<Uint8List>> _pendingMessages = {};

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

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Performs any one-time initialization (currently a no-op placeholder for
  /// future TURN credential fetching, etc.).
  Future<void> init() async {
    // Reserved for runtime setup such as fetching TURN credentials.
  }

  // ---------------------------------------------------------------------------
  // Offer / Answer
  // ---------------------------------------------------------------------------

  /// Creates a new [RTCPeerConnection] for [contactId], opens a data channel
  /// named `"chat"`, generates an SDP offer, and returns it as a JSON-
  /// encodable string.
  Future<String> createOffer(String contactId) async {
    final pc = await _createPeerConnection(contactId);

    // Create the data channel before creating the offer so it's included in
    // the SDP.
    final dc = await pc.createDataChannel('chat', RTCDataChannelInit()
      ..ordered = true);
    _registerDataChannel(contactId, dc);

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _setConnectionState(contactId, P2PConnectionState.connecting);

    return offer.sdp!;
  }

  /// Handles an incoming SDP offer from [contactId]: creates the peer
  /// connection, sets the remote description, generates an answer, and returns
  /// the SDP answer string.
  Future<String> handleOffer(String contactId, String sdpOffer) async {
    final pc = await _createPeerConnection(contactId);

    await pc.setRemoteDescription(
      RTCSessionDescription(sdpOffer, 'offer'),
    );

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
    await pc.setRemoteDescription(
      RTCSessionDescription(sdpAnswer, 'answer'),
    );
  }

  /// Adds a trickled ICE candidate from [contactId].
  Future<void> addIceCandidate(
    String contactId,
    Map<String, dynamic> candidate,
  ) async {
    final pc = _peerConnections[contactId];
    if (pc == null) {
      throw StateError('No peer connection exists for contact $contactId');
    }
    await pc.addCandidate(
      RTCIceCandidate(
        candidate['candidate'] as String?,
        candidate['sdpMid'] as String?,
        candidate['sdpMLineIndex'] as int?,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Messaging
  // ---------------------------------------------------------------------------

  /// Sends [encryptedData] over the open data channel to [contactId].
  ///
  /// If the channel is not yet open the data is queued and will be flushed
  /// automatically once the channel transitions to `open`.
  void sendMessage(String contactId, Uint8List encryptedData) {
    final dc = _dataChannels[contactId];
    if (dc != null && dc.state == RTCDataChannelState.RTCDataChannelOpen) {
      dc.send(RTCDataChannelMessage.fromBinary(encryptedData));
    } else {
      _pendingMessages.putIfAbsent(contactId, () => []).add(encryptedData);
    }
  }

  /// Returns a stream of incoming binary messages for [contactId].
  ///
  /// A new [StreamController] is lazily created per contact so multiple
  /// listeners can subscribe.
  Stream<Uint8List> onMessage(String contactId) {
    return _messageControllers
        .putIfAbsent(contactId, () => StreamController<Uint8List>.broadcast())
        .stream;
  }

  /// Returns the current connection state for [contactId].
  P2PConnectionState getConnectionState(String contactId) {
    return _connectionStates[contactId] ?? P2PConnectionState.idle;
  }

  /// Returns `true` if a data channel to [contactId] is open and usable.
  bool isConnected(String contactId) {
    return getConnectionState(contactId) == P2PConnectionState.connected;
  }

  // ---------------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------------

  /// Tears down **all** peer connections, data channels, and stream
  /// controllers.
  void dispose() {
    for (final contactId in _peerConnections.keys.toList()) {
      _closeConnection(contactId);
    }
    _iceCandidateController.close();
    _connectionStateController.close();
    _dataMessageController.close();
  }

  /// Tears down only the connection for [contactId].
  Future<void> closeConnection(String contactId) async {
    _closeConnection(contactId);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Future<RTCPeerConnection> _createPeerConnection(String contactId) async {
    // If a connection already exists, close it first.
    if (_peerConnections.containsKey(contactId)) {
      _closeConnection(contactId);
    }

    final pc = await createPeerConnection(_iceServers, {});

    pc.onIceCandidate = (candidate) {
      _iceCandidateController.add(IceCandidateEvent(contactId, candidate));
    };

    pc.onIceConnectionState = (state) {
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          _setConnectionState(contactId, P2PConnectionState.connected);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          _setConnectionState(contactId, P2PConnectionState.disconnected);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _setConnectionState(contactId, P2PConnectionState.failed);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateClosed:
          _setConnectionState(contactId, P2PConnectionState.disconnected);
          break;
        default:
          break;
      }
    };

    // The answerer receives the data channel via this callback.
    pc.onDataChannel = (channel) {
      _registerDataChannel(contactId, channel);
    };

    _peerConnections[contactId] = pc;
    _connectionStates[contactId] = P2PConnectionState.idle;
    return pc;
  }

  void _registerDataChannel(String contactId, RTCDataChannel dc) {
    _dataChannels[contactId] = dc;

    dc.onMessage = (msg) {
      final data = msg.binary;
      // Push to the per-contact stream.
      _messageControllers
          .putIfAbsent(
              contactId, () => StreamController<Uint8List>.broadcast())
          .add(data);
      // Push to the global broadcast stream.
      _dataMessageController.add(DataChannelMessageEvent(contactId, data));
    };

    dc.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _setConnectionState(contactId, P2PConnectionState.connected);
        _flushPendingMessages(contactId);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _setConnectionState(contactId, P2PConnectionState.disconnected);
      }
    };
  }

  void _flushPendingMessages(String contactId) {
    final pending = _pendingMessages.remove(contactId);
    if (pending == null) return;

    final dc = _dataChannels[contactId];
    if (dc == null || dc.state != RTCDataChannelState.RTCDataChannelOpen) {
      // Re-enqueue — the channel closed before we could flush.
      _pendingMessages[contactId] = pending;
      return;
    }
    for (final data in pending) {
      dc.send(RTCDataChannelMessage.fromBinary(data));
    }
  }

  void _setConnectionState(String contactId, P2PConnectionState state) {
    final previous = _connectionStates[contactId];
    if (previous == state) return;
    _connectionStates[contactId] = state;
    _connectionStateController.add(ConnectionStateEvent(contactId, state));
  }

  void _closeConnection(String contactId) {
    _dataChannels[contactId]?.close();
    _dataChannels.remove(contactId);

    _peerConnections[contactId]?.close();
    _peerConnections.remove(contactId);

    _messageControllers[contactId]?.close();
    _messageControllers.remove(contactId);

    _pendingMessages.remove(contactId);
    _connectionStates.remove(contactId);
  }
}
