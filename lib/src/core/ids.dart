import 'dart:math';
import 'dart:typed_data';

/// Identifier generation.
///
/// DarkFlow identifiers are 128-bit random values rendered as 32 lowercase hex
/// characters. They are deliberately *not* derived from anything secret or
/// from wall-clock time, so an identifier leaks nothing and stays stable when
/// data is exported and re-imported.
abstract final class Ids {
  static final Random _random = Random.secure();

  /// Generates a new 32-character hex identifier.
  static String generate() {
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return encodeHex(bytes);
  }

  /// Generates [count] cryptographically random bytes.
  static Uint8List randomBytes(int count) {
    final bytes = Uint8List(count);
    for (var i = 0; i < count; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes;
  }

  /// Lowercase hex encoding.
  static String encodeHex(List<int> bytes) {
    final out = StringBuffer();
    for (final byte in bytes) {
      out.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  /// Decodes a lowercase or uppercase hex string, or null when malformed.
  static Uint8List? decodeHex(String value) {
    if (value.length.isOdd) return null;
    final out = Uint8List(value.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final pair = value.substring(i * 2, i * 2 + 2);
      // `int.tryParse` accepts a sign, so `'-1'` parsed as -1 and wrapped into
      // `0xFF`, and `'+f'` parsed as 15 — both of which the doc above promises to
      // reject. A caller comparing a fingerprint would then be comparing bytes the
      // input never named.
      if (!_twoHexDigits.hasMatch(pair)) return null;
      out[i] = int.parse(pair, radix: 16);
    }
    return out;
  }

  static final RegExp _twoHexDigits = RegExp(r'^[0-9a-fA-F]{2}$');

  /// A short, human-comparable grouping of a hex string, e.g. `a3f1 09bc 7d2e`.
  static String group(String hex, {int groupSize = 4, int groups = 3}) {
    final buffer = StringBuffer();
    for (var i = 0; i < groups; i++) {
      final start = i * groupSize;
      if (start >= hex.length) break;
      if (i > 0) buffer.write(' ');
      buffer.write(hex.substring(start, (start + groupSize).clamp(0, hex.length)));
    }
    return buffer.toString();
  }
}
