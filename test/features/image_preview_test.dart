import 'dart:io';

import 'package:darkflow/src/app/app_controller.dart';
import 'package:darkflow/src/data/models/message.dart';
import 'package:darkflow/src/data/vault_store.dart';
import 'package:darkflow/src/design/design.dart';
import 'package:darkflow/src/features/chats/widgets/attachment_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The image preview path: from a sealed file in the vault to a drawn picture.
///
/// Reported as "image previews do not load", and the interesting failures are all
/// in the wiring rather than the drawing: an attachment that is never decrypted, a
/// cache keyed by the wrong thing, a placeholder drawn over a picture that was
/// available all along.
void main() {
  late Directory sandbox;
  late AppController controller;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('df-preview-');
    final paths = VaultPaths(sandbox);
    await paths.ensureCreated();
    controller = AppController(paths: paths);
    await controller.bootstrap();
    await controller.createAccount(
      displayName: 'T',
      about: '',
      password: 'a test passphrase',
    );
  });

  tearDown(() async {
    await controller.lock();
    controller.dispose();
    if (sandbox.existsSync()) await sandbox.delete(recursive: true);
  });

  /// A real PNG, so anything decoding it has to actually decode it.
  ///
  /// The smallest valid PNG: 1x1, one pixel, written by hand because the test must
  /// not depend on an image library the app does not ship.
  List<int> tinyPng() => <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, // bit depth, CRC
        0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, // IDAT length + type
        0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, // data
        0x0D, 0x0A, 0x2D, 0xB4, // CRC
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
      ];

  group('an image in the vault can be drawn', () {
    test('the encrypted copy is produced, and can be read back', () async {
      // The precondition for any preview: the bytes have to be in the vault and
      // recoverable. If this fails, nothing downstream can work and the fault is
      // in storage rather than in the interface.
      final source = File('${sandbox.path}${Platform.pathSeparator}photo.png');
      await source.writeAsBytes(tinyPng());

      final vault = controller.fileVault!;
      final digest = await vault.import(attachmentId: 'photo-1', source: source);
      expect(digest, isNotEmpty);

      final ciphertext = vault.ciphertextFile('photo-1');
      expect(ciphertext.existsSync(), isTrue);
      expect(await ciphertext.length(), greaterThan(0));

      final restored = await vault.readPlaintext('photo-1');
      expect(restored, tinyPng(), reason: 'the bytes must survive the round trip');
    });

    test('materialise produces a file the image widget can open', () async {
      final source = File('${sandbox.path}${Platform.pathSeparator}photo.png');
      await source.writeAsBytes(tinyPng());
      final vault = controller.fileVault!;
      await vault.import(attachmentId: 'photo-2', source: source);

      final materialised = await vault.materialise(
        attachmentId: 'photo-2',
        fileName: 'photo.png',
      );
      expect(materialised.existsSync(), isTrue);

      // Decoding is the step `Image.file` performs, and the one a placeholder is
      // drawn over when it fails. Doing it here is what proves a preview is
      // actually possible rather than merely present.
      final decoded = await decodeImageFromList(await materialised.readAsBytes());
      expect(decoded.width, 1);
      expect(decoded.height, 1);
    });

    test('an image attachment is recognised as one', () {
      final attachment = Attachment(
        id: 'a',
        fileName: 'photo.png',
        mimeType: 'image/png',
        sizeBytes: 100,
        sha256Hex: 'x',
        createdAt: DateTime.utc(2026),
        transferComplete: true,
      );
      expect(attachment.isImage, isTrue);
      expect(attachment.isVoice, isFalse);
    });
  });

  group('the bubble draws a preview when it has one', () {
    /// The 40 pt glyph that stands in for a picture that is not available.
    ///
    /// Told apart from the 20 pt file-type badge in the card's header row, which
    /// uses the same icon: a finder for the icon alone matches both, which is how
    /// this test first read as a failure of the code rather than of the assertion.
    Finder placeholderGlyph() => find.byWidgetPredicate(
          (Widget widget) =>
              widget is Icon && widget.size == 40 && widget.icon == Icons.image_outlined,
          description: 'the 40 pt image placeholder',
        );

    Attachment image() => Attachment(
          id: 'a',
          fileName: 'photo.png',
          mimeType: 'image/png',
          sizeBytes: 100,
          sha256Hex: 'x',
          createdAt: DateTime.utc(2026),
          transferComplete: true,
        );

    testWidgets('a supplied preview replaces the placeholder glyph',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.build(),
        home: Scaffold(
          body: AttachmentBubble(
            attachment: image(),
            outgoing: true,
            preview: const ColoredBox(
              key: Key('real-preview'),
              color: Color(0xFF00FF00),
            ),
          ),
        ),
      ));

      expect(find.byKey(const Key('real-preview')), findsOneWidget,
          reason: 'a preview that was supplied must be drawn');
      expect(placeholderGlyph(), findsNothing,
          reason: 'the placeholder must not be drawn over a real preview');
    });

    testWidgets('no preview means the placeholder, not a blank area',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.build(),
        home: Scaffold(
          body: AttachmentBubble(attachment: image(), outgoing: false),
        ),
      ));

      expect(placeholderGlyph(), findsOneWidget);
    });
  });
}
