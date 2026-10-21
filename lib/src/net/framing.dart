import 'dart:typed_data';

/// The fixed part of every frame: a 4-byte length, a kind byte and a 4-byte
/// request id.
const int kFrameHeaderLength = 9;

/// The largest payload DarkFlow will assemble from a single frame.
///
/// A peer that announces a huge length must not be able to make this process
/// allocate it. Real frames are a few kilobytes; the ceiling exists so that a
/// hostile or broken node cannot exhaust memory by sending four bytes.
const int kMaxFramePayload = 4 * 1024 * 1024;

/// What a frame carries. The kind lets a connection multiplex requests with
/// responses and with the binary chunks of a file transfer without any of them
/// being able to masquerade as another.
enum FrameKind {
  /// A request; the payload is a JSON object.
  request(0),

  /// A response to the request with the same id.
  response(1),

  /// A single-byte payload used as a keep-alive.
  keepAlive(2),

  /// The connection is being closed; the payload may carry a reason string.
  goodbye(3);

  const FrameKind(this.code);

  final int code;

  static FrameKind? fromCode(int code) => switch (code) {
        0 => FrameKind.request,
        1 => FrameKind.response,
        2 => FrameKind.keepAlive,
        3 => FrameKind.goodbye,
        _ => null,
      };
}

/// One decoded frame.
class Frame {
  const Frame({required this.kind, required this.requestId, required this.payload});

  final FrameKind kind;

  /// Correlates a response with its request. Generated per connection, so it
  /// never leaks anything about the conversation.
  final int requestId;

  final Uint8List payload;

  /// Serialises the frame with its length prefix.
  Uint8List encode() {
    final out = Uint8List(kFrameHeaderLength + payload.length);
    final view = ByteData.sublistView(out);
    view.setUint32(0, 5 + payload.length, Endian.big);
    out[4] = kind.code;
    view.setUint32(5, requestId, Endian.big);
    out.setRange(kFrameHeaderLength, out.length, payload);
    return out;
  }

  @override
  String toString() => 'Frame(${kind.name}, id=$requestId, ${payload.length} bytes)';
}

/// Thrown when the peer sends something that is not a valid frame.
class FramingException implements Exception {
  const FramingException(this.message);

  final String message;

  @override
  String toString() => 'FramingException: $message';
}

/// Turns a stream of socket chunks into a stream of frames and back.
///
/// TCP does not preserve message boundaries, and Tor relays chunks however it
/// likes, so a frame can be split across several events and several frames can
/// arrive in one. This class is the only place that has to care.
class FrameDecoder {
  FrameDecoder({this.maxPayload = kMaxFramePayload});

  final int maxPayload;
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  /// Feeds [data] in and returns every frame that is now complete.
  List<Frame> add(List<int> data) {
    _buffer.add(data);
    final frames = <Frame>[];

    // Peeking means rebuilding the buffer each round, which is fine because
    // frames are small and the loop usually runs once. A ring buffer would be
    // faster and considerably harder to get right.
    var bytes = _buffer.toBytes();
    var offset = 0;

    while (bytes.length - offset >= 4) {
      final length = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.big);
      if (length < 5) {
        throw FramingException('a frame length of $length is below the minimum');
      }
      if (length - 5 > maxPayload) {
        throw FramingException(
          'a frame of ${length - 5} bytes exceeds the $maxPayload-byte ceiling',
        );
      }
      if (bytes.length - offset < 4 + length) break;

      final kindCode = bytes[offset + 4];
      final kind = FrameKind.fromCode(kindCode);
      if (kind == null) {
        throw FramingException('unknown frame kind $kindCode');
      }
      final requestId = ByteData.sublistView(bytes, offset + 5, offset + 9).getUint32(0, Endian.big);
      final payload = Uint8List.fromList(
        Uint8List.sublistView(bytes, offset + 9, offset + 4 + length),
      );
      frames.add(Frame(kind: kind, requestId: requestId, payload: payload));
      offset += 4 + length;
    }

    if (offset > 0) {
      _buffer.clear();
      if (offset < bytes.length) {
        _buffer.add(Uint8List.sublistView(bytes, offset));
      }
    }
    return frames;
  }

  /// Discards buffered bytes, used when a connection is torn down mid-frame.
  void reset() => _buffer.clear();
}
