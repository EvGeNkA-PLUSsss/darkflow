import 'dart:convert';
import 'dart:typed_data';

import 'package:darkflow/src/crypto/crypto_engine.dart';
import 'package:darkflow/src/crypto/dart_crypto_engine.dart';
import 'package:darkflow/src/data/models/message.dart';
import 'package:darkflow/src/mesh/file_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Moving an attachment's bytes from one peer to the other.
///
/// This is the mechanism that makes a received voice note playable. Before it
/// existed a message carried only metadata, so the recipient could list a note,
/// draw its waveform and never open it — `materialise` threw because the device
/// held no ciphertext.
void main() {
  late DartCryptoEngine engine;
  late Uint8List sharedKey;

  setUp(() async {
    engine = DartCryptoEngine();
    sharedKey = Uint8List.fromList(List<int>.generate(32, (int i) => i * 7 % 256));
  });

  Attachment attachmentFor(List<int> body) {
    final digestOf = FileTransfer.verifyDigest(Uint8List.fromList(body), '');
    expect(digestOf, isNull, reason: 'an empty expected digest cannot mismatch');
    return Attachment(
      id: 'voice-1',
      messageId: 'message-1',
      fileName: 'voice.m4a',
      mimeType: 'audio/mp4',
      sizeBytes: body.length,
      // The digest the sender records, so the recipient has something to check
      // the reassembled bytes against.
      sha256Hex: _sha256(engine, body),
      createdAt: DateTime.utc(2026),
      durationMs: 3000,
    );
  }

  group('a transfer round-trips', () {
    test('small payload', () {
      final body = utf8.encode('a short voice note');
      final attachment = attachmentFor(body);

      final chunks = FileTransfer.sealAll(
        engine: engine,
        sharedKey: sharedKey,
        attachmentId: attachment.id,
        bytes: body,
      );
      expect(chunks, hasLength(1));

      final opened = FileTransfer.openChunk(
        engine: engine,
        sharedKey: sharedKey,
        attachmentId: attachment.id,
        index: 0,
        total: 1,
        sealed: chunks.single,
      );
      expect(opened, body);
      expect(
        FileTransfer.verifyDigest(Uint8List.fromList(opened), attachment.sha256Hex),
        isNull,
      );
    });

    test('a payload spanning several chunks, received out of order', () {
      final body = List<int>.generate(200 * 1024, (int i) => i % 251);
      final attachment = attachmentFor(body);

      final chunks = FileTransfer.sealAll(
        engine: engine,
        sharedKey: sharedKey,
        attachmentId: attachment.id,
        bytes: body,
      );
      expect(chunks.length, greaterThan(1), reason: 'the payload must be split');

      // Deliberately shuffled: a mesh delivers envelopes in whatever order the
      // relays manage, so assembly has to be by index rather than by arrival.
      final order = <int>[for (var i = 0; i < chunks.length; i++) i]..shuffle();
      final assembled = <int>[];
      final parts = <int, List<int>>{};
      for (final index in order) {
        parts[index] = FileTransfer.openChunk(
          engine: engine,
          sharedKey: sharedKey,
          attachmentId: attachment.id,
          index: index,
          total: chunks.length,
          sealed: chunks[index],
        );
      }
      for (var i = 0; i < chunks.length; i++) {
        assembled.addAll(parts[i]!);
      }

      expect(assembled, body);
      expect(
        FileTransfer.verifyDigest(Uint8List.fromList(assembled), attachment.sha256Hex),
        isNull,
        reason: 'reassembly in index order must reproduce the sender\'s bytes',
      );
    });

    test('an empty payload still produces one chunk', () {
      // Otherwise the recipient waits for a chunk that will never come.
      final chunks = FileTransfer.sealAll(
        engine: engine,
        sharedKey: sharedKey,
        attachmentId: 'empty',
        bytes: const <int>[],
      );
      expect(chunks, hasLength(1));
      expect(
        FileTransfer.openChunk(
          engine: engine,
          sharedKey: sharedKey,
          attachmentId: 'empty',
          index: 0,
          total: 1,
          sealed: chunks.single,
        ),
        isEmpty,
      );
    });
  });

  group('a transfer cannot be tampered with', () {
    test('a chunk from a different attachment is refused', () {
      final chunks = FileTransfer.sealAll(
        engine: engine,
        sharedKey: sharedKey,
        attachmentId: 'voice-1',
        bytes: utf8.encode('hello'),
      );
      // The AAD binds the attachment, so a chunk cannot be replayed into another
      // file's transfer.
      expect(
        () => FileTransfer.openChunk(
          engine: engine,
          sharedKey: sharedKey,
          attachmentId: 'voice-2',
          index: 0,
          total: 1,
          sealed: chunks.single,
        ),
        throwsA(isA<CryptoFailure>()),
      );
    });

    test('a chunk moved to another position is refused', () {
      final chunks = FileTransfer.sealAll(
        engine: engine,
        sharedKey: sharedKey,
        attachmentId: 'voice-1',
        bytes: List<int>.generate(120 * 1024, (int i) => i % 97),
      );
      expect(chunks.length, greaterThan(1));
      // The AAD binds the index, so reordering is detected rather than silently
      // producing a corrupt file.
      expect(
        () => FileTransfer.openChunk(
          engine: engine,
          sharedKey: sharedKey,
          attachmentId: 'voice-1',
          index: 1,
          total: chunks.length,
          sealed: chunks[0],
        ),
        throwsA(isA<CryptoFailure>()),
      );
    });

    test('a modified chunk is refused', () {
      final chunks = FileTransfer.sealAll(
        engine: engine,
        sharedKey: sharedKey,
        attachmentId: 'voice-1',
        bytes: utf8.encode('the original bytes'),
      );
      final tampered = Uint8List.fromList(chunks.single);
      tampered[tampered.length - 1] ^= 0xFF;
      expect(
        () => FileTransfer.openChunk(
          engine: engine,
          sharedKey: sharedKey,
          attachmentId: 'voice-1',
          index: 0,
          total: 1,
          sealed: tampered,
        ),
        throwsA(isA<CryptoFailure>()),
      );
    });

    test('a wrong key is refused', () {
      final chunks = FileTransfer.sealAll(
        engine: engine,
        sharedKey: sharedKey,
        attachmentId: 'voice-1',
        bytes: utf8.encode('secret'),
      );
      final wrongKey = Uint8List(32);
      expect(
        () => FileTransfer.openChunk(
          engine: engine,
          sharedKey: wrongKey,
          attachmentId: 'voice-1',
          index: 0,
          total: 1,
          sealed: chunks.single,
        ),
        throwsA(isA<CryptoFailure>()),
      );
    });

    test('bytes that do not match the sender\'s digest are reported', () {
      // The check that matters for a transfer through relays: a relay can forward
      // the chunks but cannot produce content that hashes to what the sender
      // recorded.
      final original = utf8.encode('the real file');
      final attachment = attachmentFor(original);
      final substituted = utf8.encode('a different file');

      final mismatch = FileTransfer.verifyDigest(
        Uint8List.fromList(substituted),
        attachment.sha256Hex,
      );
      expect(mismatch, isNotNull);
      expect(mismatch, contains('does not match'));
    });
  });

  group('the wire form', () {
    test('carries everything the recipient needs to file the bytes', () {
      final attachment = Attachment(
        id: 'a1',
        messageId: 'm1',
        fileName: 'note.m4a',
        mimeType: 'audio/mp4',
        sizeBytes: 10,
        sha256Hex: 'ab' * 32,
        createdAt: DateTime.utc(2026),
      );
      final wire = FileTransfer.toWire(
        attachment: attachment,
        index: 0,
        total: 1,
        sealed: Uint8List.fromList(<int>[1, 2, 3]),
      );
      // Round-tripped through JSON, because that is how it actually travels.
      final decoded = FileTransfer.fromWire(
        jsonDecode(jsonEncode(wire)) as Map<String, dynamic>,
      );
      expect(decoded, isNotNull);
      expect(decoded!.attachmentId, 'a1');
      expect(decoded.messageId, 'm1');
      expect(decoded.fileName, 'note.m4a');
      expect(decoded.mimeType, 'audio/mp4');
      expect(decoded.sha256Hex, 'ab' * 32);
      expect(decoded.index, 0);
      expect(decoded.total, 1);
      expect(decoded.plaintext, <int>[1, 2, 3]);
    });

    test('a malformed payload is refused rather than half-read', () {
      expect(FileTransfer.fromWire(const <String, dynamic>{}), isNull);
      expect(
        FileTransfer.fromWire(const <String, dynamic>{'attachmentId': 'a'}),
        isNull,
        reason: 'no bytes',
      );
      expect(
        FileTransfer.fromWire(const <String, dynamic>{'d': 'AAAA'}),
        isNull,
        reason: 'no attachment to file them under',
      );
    });
  });
}

String _sha256(DartCryptoEngine engine, List<int> data) => engine
    .sha256(data)
    .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();
