// End-to-end test over real signaling infrastructure (ntfy.sh) and the
// WebRTC transport. Opt-in because it requires network access:
//
//   OPENLV_LIVE_TESTS=1 dart test test/live_roundtrip_test.dart
// Optional: OPENLV_TEST_MQTT_SERVER=ws://127.0.0.1:17887/mqtt uses a local broker.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:openlv/openlv.dart';
import 'package:test/test.dart';

void main() {
  final enabled = Platform.environment['OPENLV_LIVE_TESTS'] == '1';
  final mqttServer = Platform.environment['OPENLV_TEST_MQTT_SERVER'];
  final protocol = mqttServer == null
      ? OpenLvProtocol.ntfy
      : OpenLvProtocol.mqtt;

  test(
    'dapp and wallet exchange requests end-to-end',
    () async {
      final dappRequests = <Object?>[];
      final walletRequests = <Object?>[];

      final dapp = await OpenLv.dapp(
        protocol: protocol,
        server: mqttServer,
        info: const PeerInfo(
          identity: 'com.example.openlv.dapp',
          name: 'openlv live dapp',
        ),
        onRequest: (message) async {
          dappRequests.add(message);
          return {'result': 'dapp-echo', 'echo': message};
        },
      );
      addTearDown(dapp.close);

      await dapp.connect();
      expect(dapp.uri, startsWith('openlv://'));

      final wallet = await OpenLv.wallet(
        dapp.uri,
        info: const PeerInfo(
          identity: 'com.example.openlv.wallet',
          name: 'openlv live wallet',
        ),
        onRequest: (message) async {
          walletRequests.add(message);
          return {'result': 'wallet-echo', 'echo': message};
        },
      );
      addTearDown(wallet.close);

      await wallet.connect();

      await Future.wait([dapp.waitForLink(), wallet.waitForLink()]);

      expect((await dapp.state()).status, SessionStatus.connected);
      expect((await wallet.state()).status, SessionStatus.connected);

      final dappResponse = await wallet.send({
        'method': 'echo',
        'params': {'from': 'wallet'},
      });
      expect(dappResponse, {
        'result': 'dapp-echo',
        'echo': {
          'method': 'echo',
          'params': {'from': 'wallet'},
        },
      });

      final walletResponse = await dapp.send({
        'method': 'ping',
        'params': {'from': 'dapp'},
      });
      expect(walletResponse, {
        'result': 'wallet-echo',
        'echo': {
          'method': 'ping',
          'params': {'from': 'dapp'},
        },
      });

      expect(dappRequests, hasLength(1));
      expect(walletRequests, hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: enabled ? false : 'set OPENLV_LIVE_TESTS=1 to run',
  );

  test(
    'close cancels an acknowledged send instead of waiting for its timeout',
    () async {
      final received = Completer<void>();
      final response = Completer<Object?>();
      final dapp = await OpenLv.dapp(
        protocol: protocol,
        server: mqttServer,
        onRequest: (message) {
          received.complete();
          return response.future;
        },
      );
      addTearDown(dapp.close);
      addTearDown(() {
        if (!response.isCompleted) response.complete(null);
      });
      await dapp.connect();
      final wallet = await OpenLv.wallet(
        dapp.uri,
        onRequest: (message) => message,
      );
      addTearDown(wallet.close);
      await wallet.connect();
      await Future.wait([dapp.waitForLink(), wallet.waitForLink()]);

      final pending = expectLater(
        wallet.sendWithTimeouts(
          'hold this response',
          ackTimeout: const Duration(seconds: 10),
          responseTimeout: const Duration(minutes: 1),
        ),
        throwsA(
          isA<OpenLvException>().having(
            (error) => error.kind,
            'kind',
            OpenLvErrorKind.session,
          ),
        ),
      );
      await received.future.timeout(const Duration(seconds: 10));
      await wallet.close();
      await pending.timeout(const Duration(seconds: 2));
      expect((await wallet.state()).status, SessionStatus.disconnected);
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: enabled ? false : 'set OPENLV_LIVE_TESTS=1 to run',
  );

  test(
    'concurrent async callbacks preserve replies and handler failures time out',
    () async {
      const requestCount = 8;
      final allEntered = Completer<void>();
      var entered = 0;
      final dapp = await OpenLv.dapp(
        protocol: protocol,
        server: mqttServer,
        onRequest: (message) {
          final request = message! as Map<String, dynamic>;
          switch (request['method']) {
            case 'throw':
              return Future<Object?>.error(StateError('handler failed'));
            case 'encodingFailure':
              return Object();
            case 'concurrent':
              if (++entered == requestCount) allEntered.complete();
              return allEntered.future.then(
                (_) => {'index': request['index'], 'handled': true},
              );
            default:
              return {'echo': message};
          }
        },
      );
      addTearDown(dapp.close);
      await dapp.connect();
      final wallet = await OpenLv.wallet(
        dapp.uri,
        onRequest: (message) => message,
      );
      addTearDown(wallet.close);
      await wallet.connect();
      await Future.wait([dapp.waitForLink(), wallet.waitForLink()]);

      await Future.wait(
        List.generate(requestCount, (index) async {
          final response = await wallet.sendWithTimeouts({
            'method': 'concurrent',
            'index': index,
          }, responseTimeout: const Duration(seconds: 5));
          expect(response, {'index': index, 'handled': true});
        }),
      );

      for (final method in ['throw', 'encodingFailure']) {
        await expectLater(
          wallet.sendWithTimeouts({
            'method': method,
          }, responseTimeout: const Duration(milliseconds: 250)),
          throwsA(
            isA<OpenLvException>().having(
              (error) => error.kind,
              'kind',
              OpenLvErrorKind.requestTimeout,
            ),
          ),
        );
      }

      expect(await wallet.send({'method': 'recovery'}), {
        'echo': {'method': 'recovery'},
      });
      expect(await dapp.send('sync handler'), 'sync handler');
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: enabled ? false : 'set OPENLV_LIVE_TESTS=1 to run',
  );

  test(
    'close cancels a running handler without sending its late result',
    () async {
      final received = Completer<void>();
      final response = Completer<Object?>();
      final dapp = await OpenLv.dapp(
        protocol: protocol,
        server: mqttServer,
        onRequest: (message) {
          received.complete();
          return response.future;
        },
      );
      addTearDown(dapp.close);
      addTearDown(() {
        if (!response.isCompleted) response.complete(null);
      });
      await dapp.connect();
      final wallet = await OpenLv.wallet(
        dapp.uri,
        onRequest: (message) => message,
      );
      addTearDown(wallet.close);
      await wallet.connect();
      await Future.wait([dapp.waitForLink(), wallet.waitForLink()]);

      final pending = expectLater(
        wallet.sendWithTimeouts(
          'unfinished handler',
          responseTimeout: const Duration(seconds: 1),
        ),
        throwsA(
          isA<OpenLvException>().having(
            (error) => error.kind,
            'kind',
            OpenLvErrorKind.requestTimeout,
          ),
        ),
      );
      await received.future.timeout(const Duration(seconds: 10));
      await dapp.close().timeout(const Duration(seconds: 2));
      response.complete({'too': 'late'});
      await pending;
      expect((await dapp.state()).status, SessionStatus.disconnected);
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: enabled ? false : 'set OPENLV_LIVE_TESTS=1 to run',
  );
}
