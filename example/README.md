# openlv example

Demonstrates the [openlv](../) Flutter SDK in both roles:

* **dApp (host)** — creates a session, shows the `openlv://` connection URL to
  scan/paste into a wallet, answers incoming requests and sends requests to the
  connected wallet.
* **Wallet (client)** — pastes a connection URL, connects and answers incoming
  requests.

Run it on a desktop target (or any Flutter target with native assets support):

```sh
flutter run -d linux   # or -d macos / -d windows / a device
```

To exercise the full loop, run the app twice side by side: create a session on
the *dApp* tab of one instance, paste its connection URL into the *Wallet* tab
of the other, and connect.
