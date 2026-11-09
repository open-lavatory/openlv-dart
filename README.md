<p align="center">
  <a href="https://openlv.sh">
    <picture>
      <source srcset="https://raw.githubusercontent.com/v3xlabs/open-lavatory/refs/heads/master/docs/public/openlv_logo_dark.svg" media="(prefers-color-scheme: dark)">
      <img src="https://raw.githubusercontent.com/v3xlabs/open-lavatory/refs/heads/master/docs/public/openlv_logo_light.svg" alt="Open Lavatory" width="auto" height="60">
    </picture>
  </a>
</p>

<p align="center">
  Secure peer-to-peer connectivity between dApps and wallets
</p>

<p align="center">
    <a href="https://openlv.sh"><img src="https://img.shields.io/badge/Documentation-openlv.sh-orange?style=flat" alt="Documentation: openlv.sh"></a>
    <a href="#"><img src="https://img.shields.io/badge/Status-In%20Development-blue?style=flat" alt="Status: In Development"></a>
    <a href="#"><img src="https://img.shields.io/badge/Tests-Passing-lime?style=flat&color=63ba83" alt="Tests: Passing"></a>
    <a href="#"><img src="https://img.shields.io/badge/License-LGPL--3.0-hotpink?style=flat" alt="License: LGPL-3.0"></a>
</p>

---

## Features

- Privacy-first, end-to-end encrypted, no metrics, no tracking
- No central dependency, rather a variety of [signaling layers](https://openlv.sh/api/signaling)
- Peer-to-peer transport via WebRTC (or other [transport layers](https://openlv.sh/api/transport))
- Reuse of existing infrastructure and p2p standards
- User control over connection & configuration

## Quickstart

### dApp (host)

```dart
import 'package:openlv/openlv.dart';

final dapp = await OpenLv.dapp(
  protocol: OpenLvProtocol.ntfy,
  server: 'https://ntfy.sh/',
  info: PeerInfo(identity: 'com.example.dapp', name: 'Example dApp'),
  onRequest: (message) async {
    final request = message as Map<String, dynamic>;
    return {
      'jsonrpc': '2.0',
      'id': request['id'],
      'error': {'code': -32601, 'message': 'Method not found'},
    };
  },
);

await dapp.connect();
print('Connection URL: ${dapp.uri}'); // share with the wallet

await dapp.waitForLink();
final response = await dapp.send({
  'jsonrpc': '2.0',
  'id': 1,
  'method': 'eth_chainId',
  'params': [],
});
print('Response: $response');

await dapp.close();
```

### Wallet (client)

```dart
final wallet = await OpenLv.wallet(
  'openlv://...', // connection URL from the dApp
  info: PeerInfo(identity: 'com.example.wallet', name: 'Example Wallet'),
  onRequest: (message) async {
    final request = message as Map<String, dynamic>;
    return {
      'jsonrpc': '2.0',
      'id': request['id'],
      'error': {'code': -32601, 'message': 'Method not found'},
    };
  },
);

await wallet.connect();
await wallet.waitForLink();
print('Connected!');

await wallet.close();
```

See [`example/`](example/) for a small Flutter app exercising both roles.

## Native builds & platform setup

`openlv` supports Android, iOS, Linux, macOS, and Windows.
Make sure you have a rust toolchain setup.
And for cross-compilation you'll also need Android NDK or Xcode.

You can also adjust the `hooks.user_defines.openlv.profile` in your application's `pubspec.yaml` to `debug` for development.

Consumer Flutter apps need network access:

- **Android:** add `<uses-permission android:name="android.permission.INTERNET" />` to `android/app/src/main/AndroidManifest.xml`.
- **macOS:** enable `com.apple.security.network.client` in both `DebugProfile.entitlements` and `Release.entitlements` when using App Sandbox.
