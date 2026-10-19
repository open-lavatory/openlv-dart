import 'dart:async';
import 'dart:convert';

import 'errors.dart';
import 'loader.dart';
import 'models.dart';
import 'rust/api.dart' as w;

/// Handles a remote request and returns a JSON-encodable response.
///
/// Throwing or returning a non-encodable value leaves the request unanswered.
/// Handlers may run concurrently and finish after the session closes.
typedef OnRequest = FutureOr<Object?> Function(Object? message);

/// Entry point of the openlv SDK.
abstract final class OpenLv {
  /// Load the native library and initialize the bindings. Optional: the
  /// session factories call this automatically.
  static Future<void> init({String? libraryPath}) =>
      initOpenLv(libraryPath: libraryPath);

  /// Create a host (dApp) session.
  ///
  /// Call [OpenLvSession.connect] to start signaling.
  static Future<OpenLvSession> dapp({
    String? sessionId,
    OpenLvProtocol protocol = OpenLvProtocol.ntfy,
    String? server,
    String? handshakeKey,
    PeerInfo? info,
    required OnRequest onRequest,
  }) async {
    await initOpenLv();

    final inner = await _guard(
      () => w.createDapp(
        options: w.SessionOptions(
          sessionId: sessionId,
          protocol: protocol.wireName,
          server: server,
          handshakeKey: handshakeKey,
          peerInfo: info,
        ),
        onRequest: (message) async =>
            _encodeJson(await onRequest(jsonDecode(message))),
      ),
    );

    return OpenLvSession._create(inner);
  }

  /// Create a client (wallet) session from an `openlv://` connection URL.
  ///
  /// The returned session is not connected yet; call [OpenLvSession.connect].
  static Future<OpenLvSession> wallet(
    String url, {
    PeerInfo? info,
    required OnRequest onRequest,
  }) async {
    await initOpenLv();

    final inner = await _guard(
      () => w.connectWallet(
        url: url,
        peerInfo: info,
        onRequest: (message) async =>
            _encodeJson(await onRequest(jsonDecode(message))),
      ),
    );

    return OpenLvSession._create(inner);
  }

  /// Parse an `openlv://` connection URL into its individual parameters.
  static Future<SessionUriInfo> parseUri(String url) async {
    await initOpenLv();
    return _guard(() => w.parseSessionUri(url: url));
  }

  /// Generate a random 16-character URL-safe session id.
  static Future<String> generateSessionId() async {
    await initOpenLv();
    return _guard(() => w.generateSessionId());
  }
}

/// A peer-to-peer session.
class OpenLvSession {
  /// Default timeout for the remote peer to acknowledge a request.
  static const Duration defaultAckTimeout = Duration(seconds: 10);

  /// Default timeout to receive a response after acknowledgement.
  static const Duration defaultResponseTimeout = Duration(hours: 1);

  final w.OpenLvSession _inner;
  final StreamController<SessionState> _statesController =
      StreamController<SessionState>.broadcast();

  StreamSubscription<w.SessionState>? _stateSub;
  Future<void>? _closeFuture;

  /// The `openlv://` connection URL of this session.
  late final String uri;

  /// The 16-character session id.
  late final String sessionId;

  /// Whether this side is the host (dApp) of the session.
  late final bool isHost;

  OpenLvSession._(this._inner);

  static Future<OpenLvSession> _create(w.OpenLvSession inner) async {
    final session = OpenLvSession._(inner);

    session.uri = await inner.uri();
    session.sessionId = await inner.sessionId();
    session.isHost = await inner.isHost();

    session._stateSub = inner.subscribeStates().listen(
      session._statesController.add,
    );

    return session;
  }

  /// Session state updates. The current state is available from [state].
  Stream<SessionState> get states => _statesController.stream;

  /// The current session state.
  Future<SessionState> state() => _guard(_inner.state);

  /// Connect the signaling layer and start the handshake.
  Future<void> connect() => _guard(_inner.connect);

  /// Wait until the peer-to-peer transport reports connected.
  ///
  /// Fails with [OpenLvErrorKind.session] if this session is closed.
  Future<void> waitForLink() => _guard(_inner.waitForLink);

  /// Send a JSON-encodable [message] and await the JSON-decoded response,
  /// using [defaultAckTimeout] and [defaultResponseTimeout].
  Future<Object?> send(Object? message) => sendWithTimeouts(
    message,
    ackTimeout: defaultAckTimeout,
    responseTimeout: defaultResponseTimeout,
  );

  /// Send a JSON-encodable [message] with explicit timeouts.
  ///
  /// The response timeout is an absolute deadline after acknowledgement;
  /// unrelated requests do not extend it. Closing the session cancels the send.
  Future<Object?> sendWithTimeouts(
    Object? message, {
    Duration ackTimeout = defaultAckTimeout,
    Duration responseTimeout = defaultResponseTimeout,
  }) async {
    final messageJson = _encodeJson(message);

    final responseJson = await _guard(
      () => _inner.sendWithTimeouts(
        messageJson: messageJson,
        ackTimeoutMs: BigInt.from(ackTimeout.inMilliseconds),
        responseTimeoutMs: BigInt.from(responseTimeout.inMilliseconds),
      ),
    );

    return tryDecode(responseJson);
  }

  /// Cancel pending operations and close the session. Repeated calls share one
  /// future; results from Dart handlers that finish later are discarded.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    try {
      await _guard(_inner.close);
    } finally {
      await _stateSub?.cancel();
      await _statesController.close();
    }
  }
}

String _encodeJson(Object? value) {
  try {
    return jsonEncode(value);
  } catch (error) {
    throw OpenLvException(
      OpenLvErrorKind.other,
      'value is not JSON-encodable: $error',
    );
  }
}

Future<T> _guard<T>(Future<T> Function() action) async {
  try {
    return await action();
  } catch (error) {
    throw openLvExceptionFrom(error);
  }
}
