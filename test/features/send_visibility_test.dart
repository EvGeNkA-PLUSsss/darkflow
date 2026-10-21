import 'dart:io';

import 'package:darkflow/src/app/app_controller.dart';
import 'package:darkflow/src/crypto/dart_crypto_engine.dart';
import 'package:darkflow/src/crypto/onion_address.dart';
import 'package:darkflow/src/data/models/message.dart';
import 'package:darkflow/src/data/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The send path against the real controller, with no widget tree in the way.
void main() {
  late Directory sandbox;
  late AppController controller;
  late String peer;

  setUp(() async {
    final key = await DartCryptoEngine().generateEd25519();
    peer = OnionAddress.fromPublicKey(key.publicKey);
    sandbox = await Directory.systemTemp.createTemp('df-send-');
    final paths = VaultPaths(sandbox);
    await paths.ensureCreated();
    controller = AppController(paths: paths);
    await controller.bootstrap();
    await controller.createAccount(
      displayName: 'T',
      about: '',
      password: 'a test passphrase',
    );
    await controller.addContact(onionAddress: peer, displayName: 'Bob');
    await controller.loadMessages(peer);
  });

  tearDown(() async {
    await controller.lock();
    controller.dispose();
    if (sandbox.existsSync()) await sandbox.delete(recursive: true);
  });

  test('a message is kept and reported as accepted with no network', () async {
    final accepted = await controller.sendText(peer, 'hello');
    expect(accepted, isTrue);
    expect(controller.messagesFor(peer).single.body, 'hello');
    expect(controller.messagesFor(peer).single.status, MessageStatus.queued);
  });

  test('sending notifies listeners', () async {
    var notifications = 0;
    controller.addListener(() => notifications++);
    await controller.sendText(peer, 'notify');
    expect(notifications, greaterThan(0));
  });

  test('messages stay in order', () async {
    await controller.sendText(peer, 'one');
    await controller.sendText(peer, 'two');
    expect(
      controller.messagesFor(peer).map((Message m) => m.body),
      <String>['one', 'two'],
    );
  });

  test('blank text is refused', () async {
    expect(await controller.sendText(peer, '   '), isFalse);
    expect(controller.messagesFor(peer), isEmpty);
  });

  test('the thread survives a reload', () async {
    await controller.sendText(peer, 'persisted');
    await controller.loadMessages(peer);
    expect(controller.messagesFor(peer).single.body, 'persisted');
  });
}
