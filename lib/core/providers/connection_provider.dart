import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:securelyhello/core/chat/chat_service.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';

/// Exposes per-contact P2P connection states to the UI. A contact counts as
/// "direct" when a data channel is open with at least one of their devices
/// (peers are keyed `userId:deviceId`).
class ConnectionProvider extends ChangeNotifier {
  final P2PConnectionManager _connectionManager;
  final ChatService _chatService;

  final Map<String, P2PConnectionState> _connectionStates = {};
  StreamSubscription<ConnectionStateEvent>? _stateSubscription;

  ConnectionProvider({
    required P2PConnectionManager connectionManager,
    required ChatService chatService,
  })  : _connectionManager = connectionManager,
        _chatService = chatService;

  // -- Getters --

  /// Get connection state for a specific contact.
  P2PConnectionState getConnectionState(String contactId) =>
      _connectionManager.bestStateWithPrefix('$contactId:');

  /// Whether a contact is currently connected via P2P.
  bool isConnected(String contactId) =>
      getConnectionState(contactId) == P2PConnectionState.connected;

  /// Whether a contact connection is in progress.
  bool isConnecting(String contactId) =>
      getConnectionState(contactId) == P2PConnectionState.connecting;

  /// Number of active P2P connections.
  int get activeConnectionCount => _connectionStates.values
      .where((s) => s == P2PConnectionState.connected)
      .length;

  /// Initialize — set up state listeners.
  void init() {
    _stateSubscription ??=
        _connectionManager.onConnectionStateChange.listen((event) {
      _connectionStates[event.contactId] = event.state;
      notifyListeners();
    });
  }

  /// Manually trigger a (re)connection attempt through signaling.
  Future<void> reconnect(String contactId) => _chatService.connect(contactId);

  /// Disconnect from every device of a contact.
  Future<void> disconnect(String contactId) =>
      _connectionManager.closeConnectionsWithPrefix('$contactId:');

  /// Forget all states (sign-out).
  void reset() {
    _connectionStates.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    super.dispose();
  }
}
