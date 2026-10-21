import 'dart:io';

import 'package:darkflow/src/app/app_controller.dart';
import 'package:darkflow/src/app/darkflow_app.dart';
import 'package:darkflow/src/app/diagnostics.dart';
import 'package:darkflow/src/crypto/dart_crypto_engine.dart';
import 'package:darkflow/src/crypto/onion_address.dart';
import 'package:darkflow/src/data/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The diagnostic report, and above all what it must not contain.
///
/// DarkFlow has no telemetry, so this file is the only channel from a broken
/// installation to a developer. That makes it valuable, and it also makes it the
/// single place where a careless addition could hand a user's contacts to whoever
/// they paste the report to. These tests are therefore mostly negative: they name
/// what must never appear.
void main() {
  const password = 'a test passphrase';

  late Directory sandbox;
  late AppController controller;
  late String peer;

  setUp(() async {
    final key = await DartCryptoEngine().generateEd25519();
    peer = OnionAddress.fromPublicKey(key.publicKey);

    sandbox = await Directory.systemTemp.createTemp('darkflow-diag-');
    final paths = VaultPaths(sandbox);
    await paths.ensureCreated();
    controller = AppController(paths: paths);
    await controller.bootstrap();
    await controller.createAccount(
      displayName: 'Test Owner',
      about: '',
      password: password,
    );
  });

  tearDown(() async {
    await controller.lock();
    controller.dispose();
    try {
      if (sandbox.existsSync()) await sandbox.delete(recursive: true);
    } on FileSystemException {
      // A temporary directory the platform still holds open is not worth failing
      // an assertion over.
    }
  });

  group('the report describes the build', () {
    test('names the version and whether it is a release', () {
      final report = DiagnosticsReport.build(controller);
      expect(report, contains(kAppVersion));
      expect(report, contains('release build:'));
      // The crypto backend matters for any bug about keys or performance.
      expect(report, contains('crypto engine:'));
    });

    test('describes the platform', () {
      final report = DiagnosticsReport.build(controller);
      expect(report, contains('Platform'));
      expect(report, contains(Platform.operatingSystem));
    });

    test('reports the account state without the account', () {
      final report = DiagnosticsReport.build(controller);
      expect(report, contains('unlocked:      true'));
      expect(report, contains('has onion:'));
      expect(report, contains('contacts:'));
    });

    test('says so plainly when a subsystem has not started', () {
      // A report that silently omits a section reads as "that part is fine".
      final report = DiagnosticsReport.build(controller);
      expect(report, contains('Tor'));
      expect(report, contains('Mesh'));
    });
  });

  group('the report never carries private data', () {
    test('a contact\'s onion address is not in it', () async {
      await controller.addContact(onionAddress: peer, displayName: 'Someone');
      await controller.sendText(peer, 'a secret message body');
      await controller.loadMessages(peer);

      final report = DiagnosticsReport.build(controller);

      // The address is a person. A diagnostic file gets pasted into a chat window.
      expect(report, isNot(contains(peer)));
      expect(report, isNot(contains(peer.substring(0, 16))),
          reason: 'not even shortened');
    });

    test('a message body is not in it', () async {
      await controller.addContact(onionAddress: peer);
      await controller.sendText(peer, 'the wifi password is hunter2');
      await controller.loadMessages(peer);

      final report = DiagnosticsReport.build(controller);
      expect(report, isNot(contains('hunter2')));
      expect(report, isNot(contains('the wifi password')));
    });

    test('a contact name is not in it', () async {
      await controller.addContact(onionAddress: peer, displayName: 'Alice Example');
      await controller.loadMessages(peer);

      final report = DiagnosticsReport.build(controller);
      expect(report, isNot(contains('Alice Example')));
    });

    test('bridge lines are counted, never quoted', () async {
      // A bridge line is the relay somebody chose while evading a censor. It is
      // the most sensitive string in the application.
      const bridge = 'obfs4 192.0.2.10:443 9F4B2E1A0C3D5E7F8A9B0C1D2E3F4A5B6C7D8E9F cert=abc123 iat-mode=0';
      await controller.applyTorSettings(
        controller.settings.torSettings.copyWith(customBridges: bridge),
      );
      // The text is stored as one blob and split into lines, which is the shape
      // the bridge screen edits.
      expect(controller.settings.torSettings.bridgeLines, hasLength(1));

      final report = DiagnosticsReport.build(controller);
      expect(report, isNot(contains('192.0.2.10')));
      expect(report, isNot(contains('cert=abc123')));
      expect(report, isNot(contains('9F4B2E1A')));
      // Reported whether or not the Tor manager exists yet. It used to sit inside
      // the manager's branch, so a report taken while Tor was failing to start —
      // the state a bug report is actually written in — said nothing about the
      // bridges at all.
      expect(report, contains('bridge lines:  1'));
      expect(report, contains('bridge mode:   obfs4'));
    });

    test('the transport is reported even with no Tor manager', () {
      // The regression this covers: the settings were read from the daemon's
      // branch, and the daemon does not exist until networking has started.
      expect(controller.tor, isNull, reason: 'this test needs the pre-start state');
      final report = DiagnosticsReport.build(controller);
      expect(report, contains('Configured transport'));
      expect(report, contains('bridge lines:'));
    });

    test('the account display name is described, not printed', () {
      final report = DiagnosticsReport.build(controller);
      expect(report, isNot(contains('Test Owner')));
      expect(report, contains('display name:  set'));
    });

    test('it says what it leaves out, so the reader can check', () {
      // The person attaching the file is the one who has to be able to judge it.
      final report = DiagnosticsReport.build(controller);
      expect(report, contains('no messages'));
      expect(report, contains('onion addresses'));
    });
  });

  group('the exported file', () {
    test('encodes as UTF-8 text', () {
      final bytes = DiagnosticsReport.encode(controller);
      expect(bytes, isNotEmpty);
      // Plain text on purpose: a user can read it before sending it.
      final text = String.fromCharCodes(bytes);
      expect(text, contains('DarkFlow diagnostic report'));
    });

    test('has a file name that identifies the day and nothing else', () {
      final name = DiagnosticsReport.suggestedFileName();
      expect(name, startsWith('darkflow-diagnostics-'));
      expect(name, endsWith('.txt'));
      // No onion address, no account name, no machine name.
      expect(name, isNot(contains(peer)));
    });
  });

  group('the connection report', () {
    test('says what the mesh is doing about handshakes', () {
      // "The handshake does not complete" is not diagnosable from a report that does not
      // say which contacts the pump is still dialling, which ones it has a key for, and
      // why the last attempt failed. This section is what makes a support request
      // answerable.
      final report = DiagnosticsReport.build(controller);
      expect(report, contains('Connection attempts'));
      expect(report, contains('awaiting:'));
      expect(report, contains('established:'));
    });

    test('a contact address appears only as a short prefix', () async {
      // The report is written to be sent to somebody else. A full onion address is a
      // reachable identifier, so only enough of it to match an entry against the bubble the
      // user is looking at is included.
      final identity = await controller.engine.generateEd25519();
      final onion = OnionAddress.fromPublicKey(identity.publicKey);
      await controller.addContact(onionAddress: onion, displayName: 'Someone');

      final report = DiagnosticsReport.build(controller);
      expect(report, isNot(contains(onion)),
          reason: 'a full address is a way to reach the account');
      expect(report, contains(onion.substring(0, 8)),
          reason: 'the prefix is how an entry is matched to a conversation');
    });

    test('a recorded failure is reported without the address', () async {
      final identity = await controller.engine.generateEd25519();
      final onion = OnionAddress.fromPublicKey(identity.publicKey);
      await controller.addContact(onionAddress: onion, displayName: 'Someone');
      controller.debugRecordHandshakeFailure(onion, 'the proxy refused the connection');

      final report = DiagnosticsReport.build(controller);
      expect(report, contains('refused'));
      expect(report, isNot(contains(onion)));
    });
  });
}
