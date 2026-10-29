import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:openlv/openlv.dart';
import 'package:web3dart/web3dart.dart';

final _exampleKey = EthPrivateKey.fromHex(
  '0000000000000000000000000000000000000000000000000000000000000004',
);
final _exampleAddress = _exampleKey.address.eip55With0x;

Map<String, Object?> _rpcError(Object? id, int code, String message) => {
  'jsonrpc': '2.0',
  'id': id,
  'error': {'code': code, 'message': message},
};

Map<String, Object?> exampleRpcResponse(Object? message) {
  final request = message is Map ? message : const {};
  final id = request['id'];
  final method = request['method'];
  if (request['jsonrpc'] != '2.0' || method is! String) {
    return _rpcError(id, -32600, 'Invalid request');
  }
  return switch (method) {
    'eth_chainId' => {'jsonrpc': '2.0', 'id': id, 'result': '0x1'},
    'eth_accounts' || 'eth_requestAccounts' => {
      'jsonrpc': '2.0',
      'id': id,
      'result': [_exampleAddress],
    },
    'personal_sign' => _personalSign(id, request['params']),
    _ => _rpcError(id, -32601, 'Method not found'),
  };
}

Map<String, Object?> _personalSign(Object? id, Object? params) {
  if (params is! List ||
      params.length != 2 ||
      params[0] is! String ||
      params[1] is! String) {
    return _rpcError(id, -32602, 'Expected message and account parameters');
  }
  final message = params[0] as String;
  final account = params[1] as String;
  if (account.toLowerCase() != _exampleAddress.toLowerCase()) {
    return _rpcError(id, 4100, 'Requested account is not available');
  }
  if (!RegExp(r'^0x(?:[0-9a-fA-F]{2})*$').hasMatch(message)) {
    return _rpcError(id, -32602, 'Message must be 0x-prefixed hex bytes');
  }
  final signature = _exampleKey.signPersonalMessageToUint8List(
    hexToBytes(message),
  );
  return {
    'jsonrpc': '2.0',
    'id': id,
    'result': bytesToHex(signature, include0x: true),
  };
}

void main() {
  runApp(const OpenLvExampleApp());
}

class OpenLvExampleApp extends StatelessWidget {
  const OpenLvExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'openlv example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('openlv'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'dApp (host)'),
              Tab(text: 'Wallet (client)'),
            ],
          ),
        ),
        body: const TabBarView(children: [DappPage(), WalletPage()]),
      ),
    );
  }
}

class DappPage extends StatefulWidget {
  const DappPage({super.key});

  @override
  State<DappPage> createState() => _DappPageState();
}

class _DappPageState extends State<DappPage> {
  OpenLvSession? _session;
  String? _status;
  final _log = <String>[];

  Future<void> _createSession() async {
    final session = await OpenLv.dapp(
      info: const PeerInfo(
        identity: 'com.example.openlv.dapp',
        name: 'openlv example dApp',
      ),
      onRequest: (message) async {
        _addLog('request: $message');
        return exampleRpcResponse(message);
      },
    );
    if (!mounted) {
      await session.close();
      return;
    }

    session.states.listen((state) {
      if (!mounted) return;
      setState(
        () => _status =
            '${state.status.name}'
            '${state.error == null ? '' : ' (${state.error})'}',
      );
    });

    setState(() => _session = session);
    await session.connect();
    _addLog('session created');
  }

  Future<void> _sendTestRequest() async {
    final session = _session;
    if (session == null) return;
    try {
      final response = await session.send({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'eth_chainId',
        'params': <Object?>[],
      });
      _addLog('response: $response');
    } on OpenLvException catch (error) {
      _addLog('send failed: $error');
    }
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() => _log.insert(0, message));
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (session == null)
          FilledButton(
            onPressed: _createSession,
            child: const Text('Create dApp session'),
          )
        else ...[
          ListTile(
            title: const Text('Connection URL'),
            subtitle: SelectableText(session.uri),
            trailing: IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy URL',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: session.uri));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Connection URL copied')),
                  );
                }
              },
            ),
          ),
          ListTile(
            title: const Text('Status'),
            subtitle: Text(_status ?? 'created'),
            trailing: session.isHost
                ? const Chip(label: Text('host'))
                : const Chip(label: Text('client')),
          ),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: _sendTestRequest,
                child: const Text('Send test request'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () async {
                  await session.close();
                  if (!mounted) return;
                  setState(() => _session = null);
                  _addLog('session closed');
                },
                child: const Text('Close'),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        const Text('Log', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final line in _log) Text(line),
      ],
    );
  }

  @override
  void dispose() {
    unawaited(
      _session?.close().catchError((Object error) {
        debugPrint('Session close failed: $error');
      }),
    );
    super.dispose();
  }
}

class WalletPage extends StatefulWidget {
  const WalletPage({super.key});

  @override
  State<WalletPage> createState() => _WalletPageState();
}

class _WalletPageState extends State<WalletPage> {
  final _urlController = TextEditingController();
  OpenLvSession? _session;
  String? _status;
  final _log = <String>[];

  Future<void> _connect() async {
    try {
      final session = await OpenLv.wallet(
        _urlController.text.trim(),
        info: const PeerInfo(
          identity: 'com.example.openlv.wallet',
          name: 'openlv example wallet',
        ),
        onRequest: (message) async {
          _addLog('request: $message');
          return exampleRpcResponse(message);
        },
      );
      if (!mounted) {
        await session.close();
        return;
      }

      session.states.listen((state) {
        if (!mounted) return;
        setState(
          () => _status =
              '${state.status.name}'
              '${state.error == null ? '' : ' (${state.error})'}',
        );
      });

      setState(() => _session = session);
      await session.connect();
      _addLog('connecting…');

      await session.waitForLink();
      _addLog('peer-to-peer link established');
    } on OpenLvException catch (error) {
      _addLog('connect failed: $error');
    }
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() => _log.insert(0, message));
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SelectableText('Account: $_exampleAddress'),
        SelectableText(
          'Public key: ${bytesToHex(_exampleKey.encodedPublicKey, include0x: true)}',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _urlController,
          decoration: const InputDecoration(
            labelText: 'openlv:// connection URL',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton(
              onPressed: session == null ? _connect : null,
              child: const Text('Connect'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: session == null
                  ? null
                  : () async {
                      await session.close();
                      if (!mounted) return;
                      setState(() => _session = null);
                      _addLog('session closed');
                    },
              child: const Text('Close'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ListTile(
          title: const Text('Status'),
          subtitle: Text(_status ?? 'idle'),
        ),
        const SizedBox(height: 16),
        const Text('Log', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final line in _log) Text(line),
      ],
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    unawaited(
      _session?.close().catchError((Object error) {
        debugPrint('Session close failed: $error');
      }),
    );
    super.dispose();
  }
}
