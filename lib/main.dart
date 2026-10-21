import 'package:flutter/material.dart';

import 'src/app/darkflow_app.dart';

/// DarkFlow — a messenger with no server.
///
/// Every account is its own Tor onion service, so there is nothing to take
/// down, nothing to subpoena and no directory to enumerate. The price is paid
/// by the mesh layer: when a peer is offline, a mutual contact carries the
/// message, and never sees anything but ciphertext.
void main() {
  // The vault, the keystore and the Tor binaries are all touched before the
  // first frame, so the binding has to exist first.
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DarkFlowApp());
}
