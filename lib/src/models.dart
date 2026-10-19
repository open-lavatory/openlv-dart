import 'dart:convert';

export 'rust/api.dart'
    show
        OpenLvErrorKind,
        PeerInfo,
        SessionState,
        SessionStatus,
        SessionUriInfo,
        SignalState;

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
