# Dart bindings for Open Lavatory

Requires a Rust toolchain (`cargo`) on the machine that builds your Flutter/Dart app, since
the native library is compiled automatically by a build hook.

## Quickstart

### dApp (host)

```dart
import 'package:openlv/openlv.dart';

final dapp = await OpenLv.dapp(
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

## Native builds and platform setup

The build hook supports Android, iOS, Linux, macOS, and Windows. Install Cargo
and the Rust target for the architecture you are building. Cross-compilation
also requires the platform toolchain, such as the Android NDK or Xcode.

Builds use Cargo's configured target directory and default to the `release`
profile. Set `hooks.user_defines.openlv.profile` in the consuming application's
`pubspec.yaml` to `debug` for development; `OPENLV_CARGO_PROFILE` takes precedence.

Native assets load automatically. For a manually built library, call
`OpenLv.init(libraryPath: '/path/to/library')` before creating a session, or set
`OPENLV_LIBRARY_PATH`. The explicit path takes precedence over the environment
variable and the process-image fallback.

Consumer Flutter apps also need network access:

- **Android:** add `<uses-permission android:name="android.permission.INTERNET" />`
  to `android/app/src/main/AndroidManifest.xml`.
- **macOS:** enable `com.apple.security.network.client` in both
  `DebugProfile.entitlements` and `Release.entitlements` when using App Sandbox.

## License

The Dart bindings and FFI glue use [LGPLv3](LICENSE).
