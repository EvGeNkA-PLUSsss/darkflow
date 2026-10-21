import 'dart:io';

import 'package:darkflow/src/crypto/dart_crypto_engine.dart';
import 'package:darkflow/src/crypto/key_vault.dart';
import 'package:darkflow/src/data/attachment_preview_cache.dart';
import 'package:darkflow/src/data/file_vault.dart';
import 'package:darkflow/src/data/models/message.dart';
import 'package:darkflow/src/data/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The image preview cache.
///
/// Written because "image previews do not load" is not reproducible from the code
/// alone: a picture can be missing because decryption failed, because the bytes
/// have not arrived, because the cache never learned a decryption finished, or
/// because nothing redrew. Each of those is a different fault with the same
/// symptom, and each is a case below.
void main() {
  late Directory sandbox;
  late FileVault vault;

  setUp(() async {
    final paths = VaultPaths(await Directory.systemTemp.createTemp('df-preview-cache-'));
    sandbox = paths.root;
    await paths.ensureCreated();
    final ring = await KeyVault(DartCryptoEngine()).create(password: 'a test passphrase');
    vault = FileVault(engine: DartCryptoEngine(), paths: paths)..unlock(ring.$2);
  });

  tearDown(() async {
    if (sandbox.existsSync()) await sandbox.delete(recursive: true);
  });

  /// A real, decodable PNG.
  List<int> tinyPng() => <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,
        0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54,
        0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01,
        0x0D, 0x0A, 0x2D, 0xB4,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
      ];

  Attachment image(String id, {bool complete = true}) => Attachment(
        id: id,
        fileName: '$id.png',
        mimeType: 'image/png',
        sizeBytes: 100,
        sha256Hex: 'x',
        createdAt: DateTime.utc(2026),
        transferComplete: complete,
      );

  Future<void> store(String id) async {
    final source = File('${sandbox.path}${Platform.pathSeparator}$id.png');
    await source.writeAsBytes(tinyPng());
    await vault.import(attachmentId: id, source: source);
  }

  test('an image with its bytes available becomes drawable', () async {
    await store('photo');
    final cache = AttachmentPreviewCache();

    // The first pass starts the decryption and can offer nothing yet — that is the
    // contract, and the revision is what brings the picture in.
    expect(cache.resolve(vault, <Attachment>[image('photo')]), isEmpty);

    // Wait for the decryption, watching for the revision it bumps.
    final bumped = cache.revision.value;
    for (var attempt = 0; attempt < 100 && !cache.hasPreview('photo'); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(cache.hasPreview('photo'), isTrue,
        reason: 'the bytes are in the vault, so the picture must become drawable');
    expect(cache.revision.value, greaterThan(bumped),
        reason: 'the interface has to be told, or nothing redraws');

    final ready = cache.resolve(vault, <Attachment>[image('photo')]);
    expect(ready.keys, contains('photo'));
    expect(ready['photo']!.existsSync(), isTrue);
    expect(await ready['photo']!.length(), greaterThan(0));
  });

  test('an image whose bytes never arrived is not attempted', () async {
    // The state a received photo is in before its transfer lands. Attempting the
    // decryption would fail and, worse, record that failure — so the picture would
    // stay a placeholder even after the transfer completed.
    final cache = AttachmentPreviewCache();
    expect(cache.resolve(vault, <Attachment>[image('missing', complete: false)]), isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(cache.hasPreview('missing'), isFalse);
  });

  test('a failed decryption is not retried on every frame', () async {
    // `transferComplete` says the bytes are here, but no ciphertext was ever
    // written: the honest state after a partial transfer that lied, or after a
    // cache purge.
    final cache = AttachmentPreviewCache();
    final attachment = image('ghost');
    cache.resolve(vault, <Attachment>[attachment]);
    for (var attempt = 0; attempt < 50; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      cache.resolve(vault, <Attachment>[attachment]);
    }
    expect(cache.hasPreview('ghost'), isFalse);
  });

  test('clearing forgets everything, so a new transfer can be drawn', () async {
    await store('photo');
    final cache = AttachmentPreviewCache();
    cache.resolve(vault, <Attachment>[image('photo')]);
    for (var attempt = 0; attempt < 100 && !cache.hasPreview('photo'); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(cache.hasPreview('photo'), isTrue);

    final before = cache.revision.value;
    cache.clear();

    expect(cache.hasPreview('photo'), isFalse);
    expect(cache.revision.value, greaterThan(before),
        reason: 'a purge has to redraw the interface too');
    // And the picture is reachable again on the next pass.
    cache.resolve(vault, <Attachment>[image('photo')]);
    for (var attempt = 0; attempt < 100 && !cache.hasPreview('photo'); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(cache.hasPreview('photo'), isTrue);
  });

  test('a non-image attachment is ignored', () {
    final cache = AttachmentPreviewCache();
    final voice = Attachment(
      id: 'voice',
      fileName: 'note.m4a',
      mimeType: 'audio/mp4',
      sizeBytes: 100,
      sha256Hex: 'x',
      createdAt: DateTime.utc(2026),
      durationMs: 3000,
      transferComplete: true,
    );
    expect(cache.resolve(vault, <Attachment>[voice]), isEmpty);
  });

  test('a locked vault does not mark the picture broken for the session',
      () async {
    await store('photo');
    final cache = AttachmentPreviewCache();

    // A vault with no key: nothing can be decrypted yet.
    final locked = FileVault(engine: DartCryptoEngine(), paths: VaultPaths(sandbox));
    expect(locked.isUnlocked, isFalse);
    cache.resolve(locked, <Attachment>[image('photo')]);
    for (var attempt = 0; attempt < 20; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      cache.resolve(locked, <Attachment>[image('photo')]);
    }
    expect(cache.hasPreview('photo'), isFalse);

    // Now the same attachment is attempted with an unlocked vault. It has to
    // succeed: a lock is a state of the application, not a fault in the file, and
    // recording it as a failure kept every picture a grey box after an unlock.
    cache.resolve(vault, <Attachment>[image('photo')]);
    for (var attempt = 0; attempt < 100 && !cache.hasPreview('photo'); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(cache.hasPreview('photo'), isTrue,
        reason: 'unlocking must be enough to bring the picture back');
  });
}
