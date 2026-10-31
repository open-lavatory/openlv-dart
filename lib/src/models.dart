import 'dart:convert';

/// Machine-readable category of an openlv failure.
enum OpenLvErrorKind {
  invalidUri,
  signaling,
  transport,
  session,
  encryption,
  wireFrame,
  protocolViolation,
  unsupportedProtocol,
  noConnection,
  requestTimeout,
  other,
}

/// Identity of a peer shared with the remote side during the handshake.
class PeerInfo {
  final String identity;
  final String name;
  final String? icon;

  const PeerInfo({required this.identity, required this.name, this.icon});

  @override
  int get hashCode => identity.hashCode ^ name.hashCode ^ icon.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeerInfo &&
          runtimeType == other.runtimeType &&
          identity == other.identity &&
          name == other.name &&
          icon == other.icon;
}

/// Lifecycle status of a session.
enum SessionStatus {
  created,
  signaling,
  ready,
  linking,
  connected,
  disconnected,
}

/// State of the signaling/handshake layer.
enum SignalState {
  standby,
  connecting,
  ready,
  handshake,
  handshakePartial,
  encrypted,
  error,
}

/// Snapshot of the full session state.
class SessionState {
  final SessionStatus status;
  final SignalState? signaling;
  final PeerInfo? peer;
  final String? error;

  const SessionState({
    required this.status,
    this.signaling,
    this.peer,
    this.error,
  });

  @override
  int get hashCode =>
      status.hashCode ^ signaling.hashCode ^ peer.hashCode ^ error.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionState &&
          runtimeType == other.runtimeType &&
          status == other.status &&
          signaling == other.signaling &&
          peer == other.peer &&
          error == other.error;
}

/// The parsed contents of an `openlv://` connection URL.
class SessionUriInfo {
  final String sessionId;
  final String keyHash;
  final String handshakeKey;
  final String protocol;
  final String server;

  const SessionUriInfo({
    required this.sessionId,
    required this.keyHash,
    required this.handshakeKey,
    required this.protocol,
    required this.server,
  });

  @override
  int get hashCode =>
      sessionId.hashCode ^
      keyHash.hashCode ^
      handshakeKey.hashCode ^
      protocol.hashCode ^
      server.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionUriInfo &&
          runtimeType == other.runtimeType &&
          sessionId == other.sessionId &&
          keyHash == other.keyHash &&
          handshakeKey == other.handshakeKey &&
          protocol == other.protocol &&
          server == other.server;
}

/// The signaling protocol used to discover the remote peer.
enum OpenLvProtocol {
  ntfy('ntfy'),
  mqtt('mqtt');

  const OpenLvProtocol(this.wireName);

  /// The protocol identifier as used on the wire and in `openlv://` URLs.
  final String wireName;
}

/// Decode [source] as JSON, returning the source unchanged if parsing fails.
Object? tryDecode(String source) {
  try {
    return jsonDecode(source);
  } on FormatException {
    return source;
  }
}
