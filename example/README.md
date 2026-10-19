# openlv example

Demonstrates the [openlv](../) Flutter SDK in both roles:

* **dApp (host)** — creates a session, shows the `openlv://` connection URL to
  scan/paste into a wallet, answers incoming requests and sends requests to the
  connected wallet.
* **Wallet (client)** — pastes a connection URL, connects and answers incoming
  requests.

Platform runners are generated locally rather than checked in. From this
directory, generate the target you need and run the app:

```sh
dart tool/setup.dart linux
flutter run -d linux
```

To exercise the full loop, run the app twice side by side: create a session on
the *dApp* tab of one instance, paste its connection URL into the *Wallet* tab
of the other, and connect.
