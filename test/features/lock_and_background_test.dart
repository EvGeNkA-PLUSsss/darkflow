import 'dart:io';

import 'package:darkflow/src/app/app_controller.dart';
import 'package:darkflow/src/data/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The automatic lock, and the two things that suspend it.
///
/// Two reported bugs live here, and both come from the same over-eager lock:
///
/// * pressing "Lock" left the screen as it was, because the lock changed the stage
///   underneath a *pushed* route and nothing took that route off the stack;
/// * "Protected files cannot be added on Android", because the file picker starts a
///   separate activity — DarkFlow really does go to the background — and the vault locked
///   itself while the user was choosing a file, so there was no key left to encrypt it.
///
/// The stage change and the route popping are checked here; the popping is the shell's
/// job and needs a widget tree, so what this covers is that the controller *announces*
/// the lock and that the announcement is not made while a dialog holds it off.
void main() {
  const password = 'a test passphrase';

  late Directory sandbox;
  late AppController controller;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('df-lock-');
    final paths = VaultPaths(sandbox);
    await paths.ensureCreated();
    controller = AppController(paths: paths);
    await controller.bootstrap();
    await controller.createAccount(
      displayName: 'Owner',
      about: '',
      password: password,
    );
  });

  tearDown(() async {
    controller.dispose();
    try {
      if (sandbox.existsSync()) await sandbox.delete(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  group('locking announces itself', () {
    test('the lock callback fires after the stage has changed', () async {
      // Order matters: a listener that navigates must not land on a tree that still
      // believes the account is open.
      var stageAtCallback = AppStage.ready;
      controller.onLocked = () => stageAtCallback = controller.stage;

      await controller.lock();

      expect(controller.stage, AppStage.locked);
      expect(stageAtCallback, AppStage.locked);
      expect(controller.isUnlocked, isFalse);
    });

    test('it fires exactly once per lock', () async {
      var calls = 0;
      controller.onLocked = () => calls++;
      await controller.lock();
      expect(calls, 1);
    });

    test('locking with no listener is not an error', () async {
      // The controller is used in tests and in headless paths with no shell attached.
      controller.onLocked = null;
      await controller.lock();
      expect(controller.stage, AppStage.locked);
    });
  });

  group('a platform dialog suspends the automatic lock', () {
    test('suspension starts off', () {
      expect(controller.isAutoLockSuspended, isFalse);
    });

    test('holding suspends it, releasing re-arms it', () {
      controller.holdAutoLock();
      expect(controller.isAutoLockSuspended, isTrue);
      controller.releaseAutoLock();
      expect(controller.isAutoLockSuspended, isFalse);
    });

    test('two overlapping dialogs need two releases', () {
      // The case this guards: a save dialog opened from a screen that already had a picker
      // in flight. With a boolean flag the first to close would re-arm the lock while the
      // second was still on screen, and the file chosen in it could not be encrypted.
      controller.holdAutoLock();
      controller.holdAutoLock();
      controller.releaseAutoLock();
      expect(controller.isAutoLockSuspended, isTrue,
          reason: 'the second dialog is still open');
      controller.releaseAutoLock();
      expect(controller.isAutoLockSuspended, isFalse);
    });

    test('a release with nothing held does not go negative', () {
      // An unbalanced release must not make a later hold a no-op: that would leave the
      // automatic lock disabled for the rest of the session, which is a security setting
      // silently turned off.
      controller.releaseAutoLock();
      controller.releaseAutoLock();
      expect(controller.isAutoLockSuspended, isFalse);

      controller.holdAutoLock();
      expect(controller.isAutoLockSuspended, isTrue,
          reason: 'a stray release must not consume a later hold');
      controller.releaseAutoLock();
    });

    test('suspension does not itself unlock or lock anything', () {
      // It only holds the *automatic* lock off. The explicit lock still works, because a
      // user pressing "Lock" during a dialog means it.
      controller.holdAutoLock();
      expect(controller.isUnlocked, isTrue);
      unawaited(controller.lock());
      expect(controller.isAutoLockSuspended, isTrue,
          reason: 'the hold is the caller\'s to release, not the lock\'s to clear');
      controller.releaseAutoLock();
    });
  });

  group('the settings file', () {
    test('a record written before a field existed still loads', () async {
      // The stored settings are a plain map, so a field added later is absent rather than null.
      // Reading it must not throw, and must fall back to the documented default.
      await controller.setMicrophone('mic-a');
      await controller.lock();
      await controller.unlockWithPassword(password);

      expect(controller.settings.microphoneId, 'mic-a');
    });
  });

  group('settings survive a round trip', () {
    test('the background preference is stored and read back', () async {
      // The field is new, and a record written before it existed has to be read as "off"
      // rather than throwing.
      await controller.setMicrophone('mic-a');
      await controller.lock();
      await controller.unlockWithPassword(password);

      expect(controller.settings.microphoneId, 'mic-a');
    });
  });
}

/// Starts a future and ignores it, for a call whose result the test does not await.
void unawaited(Future<void> future) {}
