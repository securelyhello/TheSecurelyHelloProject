import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:securelyhello/core/networking/p2p_connection_manager.dart';

/// Manages P2P connection states for all contacts.
class ConnectionProvider extends ChangeNotifier {
  final P2PConnectionManager _connectionManager;

  final Map<String, P2PConnectionState> _connectionStates = {};
  StreamSubscription? _stateSubscription;

  ConnectionProvider({
    required P2PConnectionManager connectionManager,
  }) : _connectionManager = connectionManager;

  // -- Getters --

  /// Get connection state for a specific contact.
  P2PConnectionState getConnectionState(String contactId) {
    return _connectionStates[contactId] ?? P2PConnectionState.idle;
  }

  /// Whether a contact is currently connected via P2P.
  bool isConnected(String contactId) {
    return _connectionStates[contactId] == P2PConnectionState.connected;
  }

  /// Whether a contact connection is in progress.
  bool isConnecting(String contactId) {
    return _connectionStates[contactId] == P2PConnectionState.connecting;
  }

  /// Number of active P2P connections.
  int get activeConnectionCount =>
      _connectionStates.values.where((s) => s == P2PConnectionState.connected).length;

  /// All contacts with active connections.
  List<String> get connectedContacts =>
      _connectionStates.entries
          .where((e) => e.value == P2PConnectionState.connected)
          .map((e) => e.key)
          .toList();

  /// Initialize — set up state listeners.
  void init() {
    _stateSubscription = _connectionManager.onConnectionStateChange.listen(
      (event) {
        final contactId = event.contactId;
        final state = event.state;

        _connectionStates[contactId] = state;
        notifyListeners();
      },
    );
  }

  /// Manually trigger a reconnection attempt for a contact.
  Future<void> reconnect(String contactId) async {
    _connectionStates[contactId] = P2PConnectionState.connecting;
    notifyListeners();

    try {
      await _connectionManager.createOffer(contactId);
    } catch (e) {
      _connectionStates[contactId] = P2PConnectionState.failed;
      notifyListeners();
    }
  }

  /// Disconnect from a specific contact.
  void disconnect(String contactId) {
    _connectionManager.closeConnection(contactId);
    _connectionStates[contactId] = P2PConnectionState.disconnected;
    notifyListeners();
  }

  /// Disconnect from all contacts.
  void disconnectAll() {
    _connectionManager.dispose();
    _connectionStates.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    super.dispose();
  }
}
