/// A dependency-free SHA3-256 (FIPS 202) implementation.
///
/// DarkFlow needs exactly one hash that the standard Dart ecosystem does not
/// ship: SHA3-256, which Tor uses for the `.onion` address checksum. Pulling in
/// a whole bignum-backed Keccak package for two bytes of checksum would be
/// wasteful, and this implementation is verified against the official NIST test
/// vectors in `test/crypto/sha3_test.dart`.
///
/// The permutation follows the Keccak reference specification; lane indices are
/// `x + 5 * y`, matching the reference pseudocode.
library;

import 'dart:typed_data';

/// SHA3-256 as specified by FIPS 202.
abstract final class Sha3 {
  /// The digest length in bytes.
  static const int digestLength = 32;

  /// The sponge rate for SHA3-256: 1088 bits.
  static const int _rateBytes = 136;

  /// Returns the 32-byte SHA3-256 digest of [input].
  static Uint8List hash(List<int> input) => Sha3Digest().update(input).digest();

  /// Returns the SHA3-256 digest of the concatenation of [parts].
  static Uint8List hashAll(List<List<int>> parts) {
    final digest = Sha3Digest();
    for (final part in parts) {
      digest.update(part);
    }
    return digest.digest();
  }

  // ------------------------------------------------------------------ core

  /// Round constants for the iota step.
  static const List<int> _roundConstants = <int>[
    0x0000000000000001,
    0x0000000000008082,
    0x800000000000808a,
    0x8000000080008000,
    0x000000000000808b,
    0x0000000080000001,
    0x8000000080008081,
    0x8000000000008009,
    0x000000000000008a,
    0x0000000000000088,
    0x0000000080008009,
    0x000000008000000a,
    0x000000008000808b,
    0x800000000000008b,
    0x8000000000008089,
    0x8000000000008003,
    0x8000000000008002,
    0x8000000000000080,
    0x000000000000800a,
    0x800000008000000a,
    0x8000000080008081,
    0x8000000000008080,
    0x0000000080000001,
    0x8000000080008008,
  ];

  /// Rotation offsets for the rho step, indexed by lane `x + 5 * y`.
  static const List<int> _rotationOffsets = <int>[
    0, 1, 62, 28, 27, //
    36, 44, 6, 55, 20, //
    3, 10, 43, 25, 39, //
    41, 45, 15, 21, 8, //
    18, 2, 61, 56, 14, //
  ];

  /// Applies Keccak-f[1600] to the 25-lane state held in [lanes].
  static void _permute(Int64List lanes) {
    final c = Int64List(5);
    final d = Int64List(5);
    final b = Int64List(25);

    for (var round = 0; round < 24; round++) {
      // Theta
      for (var x = 0; x < 5; x++) {
        c[x] = lanes[x] ^ lanes[x + 5] ^ lanes[x + 10] ^ lanes[x + 15] ^ lanes[x + 20];
      }
      for (var x = 0; x < 5; x++) {
        d[x] = c[(x + 4) % 5] ^ _rotl(c[(x + 1) % 5], 1);
      }
      for (var y = 0; y < 5; y++) {
        for (var x = 0; x < 5; x++) {
          lanes[x + 5 * y] ^= d[x];
        }
      }

      // Rho and pi
      for (var y = 0; y < 5; y++) {
        for (var x = 0; x < 5; x++) {
          final target = y + 5 * ((2 * x + 3 * y) % 5);
          b[target] = _rotl(lanes[x + 5 * y], _rotationOffsets[x + 5 * y]);
        }
      }

      // Chi
      for (var y = 0; y < 5; y++) {
        for (var x = 0; x < 5; x++) {
          lanes[x + 5 * y] =
              b[x + 5 * y] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y]);
        }
      }

      // Iota
      lanes[0] ^= _roundConstants[round];
    }
  }

  /// Rotates a 64-bit lane left by [n] bits, wrapping within 64 bits.
  static int _rotl(int value, int n) {
    if (n == 0) return value;
    return (value << n) | (value >>> (64 - n));
  }
}

/// An incremental SHA3-256 sponge.
class Sha3Digest {
  Sha3Digest();

  final Int64List _lanes = Int64List(25);
  final Uint8List _buffer = Uint8List(Sha3._rateBytes);
  int _bufferLength = 0;
  bool _finished = false;

  /// Absorbs [data] into the sponge.
  Sha3Digest update(List<int> data) {
    if (_finished) {
      throw StateError('Sha3Digest.update() called after digest()');
    }
    var offset = 0;
    while (offset < data.length) {
      final take = (Sha3._rateBytes - _bufferLength).clamp(0, data.length - offset);
      _buffer.setRange(_bufferLength, _bufferLength + take, data, offset);
      _bufferLength += take;
      offset += take;
      if (_bufferLength == Sha3._rateBytes) {
        _absorbBlock(_buffer);
        _bufferLength = 0;
      }
    }
    return this;
  }

  /// Finalises the sponge and returns the 32-byte digest.
  ///
  /// A digest instance cannot be reused; construct a new one instead.
  Uint8List digest() {
    if (_finished) {
      throw StateError('Sha3Digest.digest() called twice');
    }
    _finished = true;

    // SHA3 padding: 0x06 … 0x80 (domain separation bits 01 followed by 10*1).
    final padded = Uint8List(Sha3._rateBytes);
    padded.setRange(0, _bufferLength, _buffer);
    padded[_bufferLength] = 0x06;
    padded[Sha3._rateBytes - 1] |= 0x80;
    _absorbBlock(padded);

    final out = Uint8List(Sha3.digestLength);
    for (var i = 0; i < Sha3.digestLength; i++) {
      out[i] = (_lanes[i >> 3] >>> (8 * (i & 7))) & 0xff;
    }
    return out;
  }

  void _absorbBlock(Uint8List block) {
    for (var i = 0; i < Sha3._rateBytes ~/ 8; i++) {
      var lane = 0;
      for (var byte = 7; byte >= 0; byte--) {
        lane = (lane << 8) | block[i * 8 + byte];
      }
      _lanes[i] ^= lane;
    }
    Sha3._permute(_lanes);
  }
}
