import 'dart:typed_data';

import 'package:darkflow/src/net/framing.dart';
import 'package:flutter_test/flutter_test.dart';

/// TCP preserves nothing about message boundaries, and Tor re-chunks traffic
/// however it likes, so the decoder has to survive frames arriving split,
/// coalesced, or both. These tests exercise exactly those shapes.
void main() {
  Frame frame(int id, FrameKind kind, List<int> payload) =>
      Frame(kind: kind, requestId: id, payload: Uint8List.fromList(payload));

  group('encoding', () {
    test('a frame is a length prefix, a kind, an id and a payload', () {
      final encoded = frame(7, FrameKind.request, <int>[1, 2, 3]).encode();
      expect(encoded.length, kFrameHeaderLength + 3);
      expect(ByteData.sublistView(encoded, 0, 4).getUint32(0, Endian.big), 8);
      expect(encoded[4], FrameKind.request.code);
      expect(ByteData.sublistView(encoded, 5, 9).getUint32(0, Endian.big), 7);
      expect(encoded.sublist(9), <int>[1, 2, 3]);
    });
  });

  group('decoding', () {
    test('one frame in one chunk', () {
      final decoder = FrameDecoder();
      final frames = decoder.add(frame(1, FrameKind.request, <int>[9, 9]).encode());
      expect(frames, hasLength(1));
      expect(frames.single.kind, FrameKind.request);
      expect(frames.single.requestId, 1);
      expect(frames.single.payload, <int>[9, 9]);
    });

    test('one frame split across many chunks', () {
      final decoder = FrameDecoder();
      final encoded = frame(42, FrameKind.response, List<int>.generate(500, (i) => i & 0xff)).encode();

      // Feed it one byte at a time; only the final byte may complete a frame.
      for (var i = 0; i < encoded.length - 1; i++) {
        expect(decoder.add(<int>[encoded[i]]), isEmpty, reason: 'after byte $i');
      }
      final frames = decoder.add(<int>[encoded.last]);
      expect(frames, hasLength(1));
      expect(frames.single.requestId, 42);
      expect(frames.single.payload, List<int>.generate(500, (i) => i & 0xff));
    });

    test('several frames coalesced into one chunk', () {
      final decoder = FrameDecoder();
      final buffer = BytesBuilder();
      for (var i = 0; i < 5; i++) {
        buffer.add(frame(i, FrameKind.request, <int>[i]).encode());
      }
      final frames = decoder.add(buffer.takeBytes());
      expect(frames, hasLength(5));
      expect(frames.map((f) => f.requestId), <int>[0, 1, 2, 3, 4]);
      expect(frames.map((f) => f.payload.single), <int>[0, 1, 2, 3, 4]);
    });

    test('a chunk that ends mid-frame leaves the remainder buffered', () {
      final decoder = FrameDecoder();
      final first = frame(1, FrameKind.request, <int>[1, 2, 3]).encode();
      final second = frame(2, FrameKind.request, <int>[4, 5, 6]).encode();

      final combined = <int>[...first, ...second.sublist(0, 5)];
      expect(decoder.add(combined), hasLength(1));

      final rest = decoder.add(second.sublist(5));
      expect(rest, hasLength(1));
      expect(rest.single.requestId, 2);
      expect(rest.single.payload, <int>[4, 5, 6]);
    });

    test('an empty payload is legal', () {
      final decoder = FrameDecoder();
      final frames = decoder.add(frame(3, FrameKind.keepAlive, const <int>[]).encode());
      expect(frames, hasLength(1));
      expect(frames.single.payload, isEmpty);
    });
  });

  group('hostile input', () {
    test('an oversized length is rejected before allocating', () {
      final decoder = FrameDecoder(maxPayload: 1024);
      final header = ByteData(9)
        ..setUint32(0, 1024 + 5 + 1, Endian.big)
        ..setUint8(4, FrameKind.request.code)
        ..setUint32(5, 1, Endian.big);
      expect(
        () => decoder.add(header.buffer.asUint8List()),
        throwsA(isA<FramingException>()),
      );
    });

    test('an unknown kind is rejected', () {
      final decoder = FrameDecoder();
      final bytes = frame(1, FrameKind.request, <int>[1]).encode();
      bytes[4] = 0x7f;
      expect(() => decoder.add(bytes), throwsA(isA<FramingException>()));
    });

    test('a length below the minimum is rejected', () {
      final decoder = FrameDecoder();
      final bytes = Uint8List(9);
      ByteData.sublistView(bytes).setUint32(0, 2, Endian.big);
      bytes[4] = FrameKind.request.code;
      expect(() => decoder.add(bytes), throwsA(isA<FramingException>()));
    });

    test('reset discards a partial frame', () {
      final decoder = FrameDecoder();
      final encoded = frame(1, FrameKind.request, <int>[1, 2, 3]).encode();
      expect(decoder.add(encoded.sublist(0, 5)), isEmpty);
      decoder.reset();
      expect(decoder.add(encoded), hasLength(1));
    });
  });
}
