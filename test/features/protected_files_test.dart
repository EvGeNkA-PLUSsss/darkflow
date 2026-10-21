import 'dart:io';

import 'package:darkflow/src/app/app_controller.dart';
import 'package:darkflow/src/data/models/protected_file.dart';
import 'package:darkflow/src/data/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// True when [needle] appears in [haystack] as a contiguous run.
///
/// Written out rather than using a string search, because the haystack is
/// ciphertext: it is not text at all, and decoding it to look for a substring
/// throws before it can answer anything.
bool _containsSubsequence(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    var matched = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (haystack[start + offset] != needle[offset]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}

/// The protected-files vault, which did not work at all.
///
/// The screen was handed an empty list and three callbacks that were literal
/// no-ops, so adding a file sealed it and then showed nothing, opening did
/// nothing, and removing did nothing. Everything below drives the real account
/// layer, so the assertions are about what is actually in the vault rather than
/// about what a screen was told.
void main() {
  const password = 'a test passphrase';

  late Directory sandbox;
  late AppController controller;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('df-protected-');
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

  Future<File> sourceFile(String name, {String body = 'a secret document'}) async {
    final file = File('${sandbox.path}${Platform.pathSeparator}$name');
    await file.writeAsString(body);
    return file;
  }

  group('protecting a file', () {
    test('it appears in the vault and its bytes are sealed', () async {
      final file = await sourceFile('passport.pdf');
      final protected = await controller.protectFile(file);

      expect(protected, isNotNull);
      expect(protected!.fileName, 'passport.pdf');
      expect(protected.mimeType, 'application/pdf');
      expect(protected.sizeBytes, await file.length());

      // The list the screen reads has to contain it — this is the part that was
      // broken: the file was sealed and then never shown.
      expect(controller.protectedFiles.map((ProtectedFile f) => f.fileName),
          contains('passport.pdf'));

      // And the ciphertext is on disk, addressed by the record's id.
      final ciphertext = controller.fileVault!.ciphertextFile(protected.id);
      expect(ciphertext.existsSync(), isTrue);

      // The plaintext is not lying next to it. Read as bytes rather than decoded:
      // the file is ciphertext, and decoding it as UTF-8 is itself an error.
      final raw = await ciphertext.readAsBytes();
      expect(
        _containsSubsequence(raw, 'a secret document'.codeUnits),
        isFalse,
        reason: 'the sealed file must not contain its own plaintext',
      );
    });

    test('the same name twice is two records, keyed by id', () async {
      // Two files may share a name; the vault must address them by identifier, or
      // adding the second would overwrite the first.
      final first = await controller.protectFile(await sourceFile('notes.txt', body: 'first'));
      final second = await controller.protectFile(await sourceFile('notes.txt', body: 'second'));

      expect(first!.id, isNot(second!.id));
      expect(controller.protectedFiles, hasLength(2));
      expect(
        await controller.fileVault!.readPlaintext(first.id),
        'first'.codeUnits,
      );
      expect(
        await controller.fileVault!.readPlaintext(second.id),
        'second'.codeUnits,
      );
    });

    test('a file that is not there is refused rather than recorded', () async {
      final missing = File('${sandbox.path}${Platform.pathSeparator}nope.bin');
      expect(await controller.protectFile(missing), isNull);
      expect(controller.protectedFiles, isEmpty);
    });

    test('an image is recognised for the preview path', () async {
      final file = await sourceFile('photo.png', body: 'not really a png');
      final protected = await controller.protectFile(file);
      expect(protected!.mimeType, 'image/png');
    });
  });

  group('reading a protected file back', () {
    test('materialise decrypts it into the cache', () async {
      final protected = await controller.protectFile(
        await sourceFile('letter.txt', body: 'dear someone'),
      );
      final materialised = await controller.materialiseProtected(protected!.id);

      expect(materialised, isNotNull);
      expect(await materialised!.readAsString(), 'dear someone');
    });

    test('saving a copy writes it where the user chose, and records it', () async {
      final protected = await controller.protectFile(
        await sourceFile('letter.txt', body: 'keep me'),
      );
      final target = File('${sandbox.path}${Platform.pathSeparator}kept.txt');

      final saved = await controller.exportProtectedFile(protected!.id, target);
      expect(saved, isNotNull);
      expect(await target.readAsString(), 'keep me');

      // Recorded so the screen can say the file exists outside the vault too.
      final record = controller.protectedFiles
          .firstWhere((ProtectedFile f) => f.id == protected.id);
      expect(record.savedTo, target.path);
      expect(record.hasSavedCopy, isTrue);
    });

    test('the saved copy survives locking, the cached one does not', () async {
      // This is the whole point of "save forever": the cache is purged on lock,
      // and the copy the user chose is not.
      final protected = await controller.protectFile(
        await sourceFile('letter.txt', body: 'outlive me'),
      );
      final target = File('${sandbox.path}${Platform.pathSeparator}kept.txt');
      await controller.exportProtectedFile(protected!.id, target);

      await controller.lock();
      expect(target.existsSync(), isTrue, reason: 'the saved copy is the user\'s');

      await controller.unlockWithPassword(password);
      final record = controller.protectedFiles
          .firstWhere((ProtectedFile f) => f.id == protected.id);
      expect(record.fileName, 'letter.txt');
      // And it can still be decrypted from the vault after a relock.
      final materialised = await controller.materialiseProtected(protected.id);
      expect(await materialised!.readAsString(), 'outlive me');
    });
  });

  group('removing a protected file', () {
    test('drops the record and the ciphertext', () async {
      final protected = await controller.protectFile(
        await sourceFile('gone.txt', body: 'delete me'),
      );
      final ciphertext = controller.fileVault!.ciphertextFile(protected!.id);
      expect(ciphertext.existsSync(), isTrue);

      expect(await controller.unprotectFile(protected.id), isTrue);

      expect(ciphertext.existsSync(), isFalse,
          reason: 'the encrypted copy must go too, or a delete would not delete');
      expect(controller.protectedFiles, isEmpty);
    });

    test('removing something that is not there reports false', () async {
      expect(await controller.unprotectFile('never-existed'), isFalse);
    });

    test('a copy the user saved elsewhere is untouched', () async {
      // Deleting from the vault is not deleting the user's own copy, and the
      // screen says so before asking.
      final protected = await controller.protectFile(
        await sourceFile('doc.txt', body: 'body'),
      );
      final target = File('${sandbox.path}${Platform.pathSeparator}saved.txt');
      await controller.exportProtectedFile(protected!.id, target);

      await controller.unprotectFile(protected.id);

      expect(target.existsSync(), isTrue);
      expect(await target.readAsString(), 'body');
    });
  });

  group('the list survives a restart', () {
    test('records are reloaded from the encrypted store', () async {
      await controller.protectFile(await sourceFile('one.txt', body: 'one'));
      await controller.protectFile(await sourceFile('two.txt', body: 'two'));

      await controller.lock();
      await controller.unlockWithPassword(password);

      expect(
        controller.protectedFiles.map((ProtectedFile f) => f.fileName).toSet(),
        <String>{'one.txt', 'two.txt'},
      );
      expect(controller.protectedBytes, greaterThan(0));
    });

    test('a protected file is not an attachment', () async {
      // They share the blob store but not the records: filing a protected file as
      // an attachment made it appear in whichever conversation shared its id, and
      // made the vault list every attachment in the account.
      final protected = await controller.protectFile(
        await sourceFile('doc.txt', body: 'x'),
      );
      expect(controller.attachmentFor(protected!.id), isNull);
      final rows = await controller.store!.readAll('attachments');
      expect(rows.any((Map<String, dynamic> row) => row['id'] == protected.id), isFalse);
    });
  });
}
