import 'dart:async';
import 'dart:convert';

import 'errors.dart';
import 'loader.dart';
import 'models.dart';
import 'uniffi/openlv_uniffi.dart' as native;

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

  /// Create a host (dApp) session. Call [OpenLvSession.connect] to start signaling.
  static Future<OpenLvSession> dapp({
    String? sessionId,
    OpenLvProtocol protocol = OpenLvProtocol.ntfy,
    String? server,
    String? handshakeKey,
    PeerInfo? info,
    required OnRequest onRequest,
  }) async {
    await initOpenLv();
    return _guard(() async {
      final inner = await native.createDapp(
        jsonEncode({
          'session_id': sessionId,
          'protocol': protocol.wireName,
          'server': server,
          'handshake_key': handshakeKey,
          'peer_info': _peerJson(info),
        }),
      );
      return OpenLvSession._create(inner, onRequest);
    });
  }

  /// Create a client (wallet) session from an `openlv://` connection URL.
  /// The returned session is not connected yet; call [OpenLvSession.connect].
  static Future<OpenLvSession> wallet(
    String url, {
    PeerInfo? info,
    required OnRequest onRequest,
  }) async {
    await initOpenLv();
    return _guard(
      () async => OpenLvSession._create(
        await native.createWallet(url, jsonEncode(_peerJson(info))),
        onRequest,
      ),
    );
  }

  /// Parse an `openlv://` connection URL into its individual parameters.
  static Future<SessionUriInfo> parseUri(String url) async {
    await initOpenLv();
    return _guard(() async {
      final value =
          jsonDecode(await native.parseSessionUri(url)) as Map<String, dynamic>;
      return SessionUriInfo(
        sessionId: value['session_id'] as String,
        keyHash: value['key_hash'] as String,
        handshakeKey: value['handshake_key'] as String,
        protocol: value['protocol'] as String,
        server: value['server'] as String,
      );
    });
  }

  /// Generate a random 16-character URL-safe session id.
  static Future<String> generateSessionId() async {
    await initOpenLv();
    return _guard(native.generateSessionId);
  }
}

/// A peer-to-peer session.
class OpenLvSession {
  /// Default timeout for the remote peer to acknowledge a request.
  static const Duration defaultAckTimeout = Duration(seconds: 10);

  /// Default timeout to receive a response after acknowledgement.
  static const Duration defaultResponseTimeout = Duration(hours: 1);

  final native.Session _inner;
  final OnRequest _onRequest;
  final StreamController<SessionState> _statesController =
      StreamController<SessionState>.broadcast();
  late final native.StateSubscription _subscription;
  late final Future<void> _requestLoop;
  late final Future<void> _stateLoop;
  Future<void>? _closeFuture;
  bool _closing = false;

  /// The `openlv://` connection URL of this session.
  late final String uri;

  /// The 16-character session id.
  late final String sessionId;

  /// Whether this side is the host (dApp) of the session.
  late final bool isHost;

  OpenLvSession._(this._inner, this._onRequest);

  static Future<OpenLvSession> _create(
    native.Session inner,
    OnRequest onRequest,
  ) async {
    final session = OpenLvSession._(inner, onRequest);
    session.uri = await inner.uri();
    session.sessionId = await inner.sessionId();
    session.isHost = await inner.isHost();
    session._subscription = await inner.subscribeStates();
    session._requestLoop = session._serveRequests();
    session._stateLoop = session._serveStates();
    return session;
  }

  Future<void> _serveRequests() async {
    try {
      while (!_closing) {
        final request = await _inner.nextRequest();
        if (request == null || _closing) break;
        final envelope = jsonDecode(request) as Map<String, dynamic>;
        unawaited(
          _handleRequest(envelope['id'] as int, envelope['message'] as String),
        );
      }
    } catch (error, stack) {
      if (!_closing) {
        _statesController.addError(openLvExceptionFrom(error), stack);
      }
    }
  }

  Future<void> _handleRequest(int id, String message) async {
    try {
      final response = _encodeJson(await _onRequest(jsonDecode(message)));
      if (!_closing) _inner.respond(id, response);
    } catch (_) {
      // A failed handler intentionally leaves the request unanswered.
    }
  }

  Future<void> _serveStates() async {
    try {
      while (!_closing) {
        final state = await _subscription.nextState();
        if (state == null || _closing) break;
        _statesController.add(_stateFromJson(state));
      }
    } catch (error, stack) {
      if (!_closing) {
        _statesController.addError(openLvExceptionFrom(error), stack);
      }
    }
  }

  /// Session state updates. The current state is available from [state].
  Stream<SessionState> get states => _statesController.stream;

  /// The current session state.
  Future<SessionState> state() =>
      _guard(() async => _stateFromJson(await _inner.state()));

  /// Connect the signaling layer and start the handshake.
  Future<void> connect() => _guard(_inner.connect);

  /// Wait until the peer-to-peer transport reports connected.
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
  /// The response timeout is an absolute deadline after acknowledgement;
  /// unrelated requests do not extend it. Closing the session cancels the send.
  Future<Object?> sendWithTimeouts(
    Object? message, {
    Duration ackTimeout = defaultAckTimeout,
    Duration responseTimeout = defaultResponseTimeout,
  }) async {
    final messageJson = _encodeJson(message);
    final response = await _guard(
      () => _inner.sendWithTimeouts(
        messageJson,
        ackTimeout.inMilliseconds,
        responseTimeout.inMilliseconds,
      ),
    );
    return tryDecode(response);
  }

  /// Cancel pending operations and close the session. Repeated calls share one
  /// future; results from Dart handlers that finish later are discarded.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    try {
      await _guard(_inner.shutdown);
    } finally {
      await Future.wait([_requestLoop, _stateLoop]);
      _subscription.close();
      await _statesController.close();
    }
  }
}

Map<String, Object?>? _peerJson(PeerInfo? peer) => peer == null
    ? null
    : {'identity': peer.identity, 'name': peer.name, 'icon': peer.icon};

SessionState _stateFromJson(String source) {
  final value = jsonDecode(source) as Map<String, dynamic>;
  final peer = value['peer'] as Map<String, dynamic>?;
  final signaling = value['signaling'] as String?;
  return SessionState(
    status: SessionStatus.values.byName(_camelCase(value['status'] as String)),
    signaling: signaling == null
        ? null
        : SignalState.values.byName(_camelCase(signaling)),
    peer: peer == null
        ? null
        : PeerInfo(
            identity: peer['identity'] as String,
            name: peer['name'] as String,
            icon: peer['icon'] as String?,
          ),
    error: value['error'] as String?,
  );
}

String _camelCase(String value) => value.replaceAllMapped(
  RegExp(r'_([a-z])'),
  (match) => match[1]!.toUpperCase(),
);

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
