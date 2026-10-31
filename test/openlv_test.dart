import 'package:openlv/openlv.dart';
import 'package:test/test.dart';

Object? echo(Object? message) => message;

void main() {
  setUpAll(() async {
    await OpenLv.init();
  });

  const info = PeerInfo(
    identity: 'com.example.openlv.test',
    name: 'openlv test peer',
  );

  test('generateSessionId returns 16 URL-safe characters', () async {
    final id = await OpenLv.generateSessionId();
    expect(id, hasLength(16));
    expect(RegExp(r'^[A-Za-z0-9_-]{16}$').hasMatch(id), isTrue);
  });

  group('dapp session', () {
    test('is created with a connection URL', () async {
      final dapp = await OpenLv.dapp(info: info, onRequest: echo);
      addTearDown(dapp.close);

      expect(dapp.isHost, isTrue);
      expect(dapp.sessionId, hasLength(16));
      expect(dapp.uri, startsWith('openlv://'));

      final state = await dapp.state();
      expect(state.status, SessionStatus.created);
    });

    test('round-trips its parameters through the connection URL', () async {
      final dapp = await OpenLv.dapp(
        onRequest: echo,
        protocol: OpenLvProtocol.mqtt,
        server: 'wss://test.mosquitto.org:8081/mqtt',
        info: info,
      );
      addTearDown(dapp.close);

      final parsed = await OpenLv.parseUri(dapp.uri);
      expect(parsed.sessionId, dapp.sessionId);
      expect(parsed.protocol, 'mqtt');
      expect(parsed.server, 'wss://test.mosquitto.org:8081/mqtt');
      expect(parsed.handshakeKey, hasLength(32));
      expect(parsed.keyHash, hasLength(16));
    });

    test('honors a fixed session id and handshake key', () async {
      const sessionId = 'k7n8m9x2w5q1p3r6';
      const handshakeKey = '0123456789abcdef0123456789abcdef';

      final dapp = await OpenLv.dapp(
        onRequest: echo,
        sessionId: sessionId,
        handshakeKey: handshakeKey,
        info: info,
      );
      addTearDown(dapp.close);

      expect(dapp.sessionId, sessionId);

      final parsed = await OpenLv.parseUri(dapp.uri);
      expect(parsed.handshakeKey, handshakeKey);
    });

    test('rejects invalid peer info', () async {
      expect(
        () => OpenLv.dapp(
          onRequest: echo,
          info: const PeerInfo(identity: '', name: 'missing identity'),
        ),
        throwsA(isA<OpenLvException>()),
      );
    });

    test('rejects an invalid handshake key', () async {
      expect(
        () => OpenLv.dapp(handshakeKey: 'not-hex', onRequest: echo),
        throwsA(
          isA<OpenLvException>().having(
            (error) => error.kind,
            'kind',
            OpenLvErrorKind.encryption,
          ),
        ),
      );
    });

    test('send fails before the session is ready', () async {
      final dapp = await OpenLv.dapp(info: info, onRequest: echo);
      addTearDown(dapp.close);

      expect(
        () => dapp.send({'method': 'eth_chainId', 'params': []}),
        throwsA(
          isA<OpenLvException>().having(
            (error) => error.kind,
            'kind',
            OpenLvErrorKind.session,
          ),
        ),
      );
    });

    test('close cancels link waits and prevents new operations', () async {
      final dapp = await OpenLv.dapp(info: info, onRequest: echo);
      addTearDown(dapp.close);
      final closedError = throwsA(
        isA<OpenLvException>().having(
          (error) => error.kind,
          'kind',
          OpenLvErrorKind.session,
        ),
      );
      final waiting = expectLater(dapp.waitForLink(), closedError);

      await dapp.close();
      await waiting.timeout(const Duration(seconds: 2));
      expect((await dapp.state()).status, SessionStatus.disconnected);
      await expectLater(dapp.waitForLink(), closedError);
      await expectLater(dapp.connect(), closedError);
      await expectLater(dapp.send('after close'), closedError);
    });

    test('concurrent close completes the state stream', () async {
      final dapp = await OpenLv.dapp(info: info, onRequest: echo);
      addTearDown(dapp.close);
      final statesDone = dapp.states.drain<void>();

      await Future.wait([dapp.close(), dapp.close()]);
      await statesDone.timeout(const Duration(seconds: 2));
      expect((await dapp.state()).status, SessionStatus.disconnected);
    });

    test('rejects non-JSON-encodable messages', () async {
      final dapp = await OpenLv.dapp(info: info, onRequest: echo);
      addTearDown(dapp.close);

      expect(
        () => dapp.send(Object()),
        throwsA(
          isA<OpenLvException>().having(
            (error) => error.kind,
            'kind',
            OpenLvErrorKind.other,
          ),
        ),
      );
    });
  });

  group('wallet session', () {
    test('connects to a dapp connection URL', () async {
      final dapp = await OpenLv.dapp(info: info, onRequest: echo);
      addTearDown(dapp.close);

      final wallet = await OpenLv.wallet(dapp.uri, info: info, onRequest: echo);
      addTearDown(wallet.close);

      expect(wallet.isHost, isFalse);
      expect(wallet.sessionId, dapp.sessionId);
    });

    test('rejects an invalid connection URL', () async {
      expect(
        () => OpenLv.wallet('not-a-uri', onRequest: echo),
        throwsA(
          isA<OpenLvException>().having(
            (error) => error.kind,
            'kind',
            OpenLvErrorKind.invalidUri,
          ),
        ),
      );
    });
  });

  group('parseUri', () {
    test('decodes a known connection URL', () async {
      final parsed = await OpenLv.parseUri(
        'openlv://k7n8m9x2w5q1p3r6@1'
        '?h=a1b2c3d4e5f60708&k=0123456789abcdef0123456789abcdef'
        '&p=mqtt&s=wss%3A%2F%2Ftest.mosquitto.org%3A8081%2Fmqtt',
      );

      expect(parsed.sessionId, 'k7n8m9x2w5q1p3r6');
      expect(parsed.keyHash, 'a1b2c3d4e5f60708');
      expect(parsed.handshakeKey, '0123456789abcdef0123456789abcdef');
      expect(parsed.protocol, 'mqtt');
      expect(parsed.server, 'wss://test.mosquitto.org:8081/mqtt');
    });
  });
}
