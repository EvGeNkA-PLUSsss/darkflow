/// Tor v3 onion address handling.
///
/// DarkFlow's whole identity model rests on this file: an account's `.onion`
/// address *is* its username, and it is derived deterministically from the
/// account's Ed25519 identity key. Because the derivation is a pure function of
/// the public key, the app can show a user their address before Tor has even
/// started, and two devices that restore the same seed produce the same
/// address.
///
/// Reference: <https://spec.torproject.org/rend-spec-v3.html> section 6.
library;

import 'dart:typed_data';

import 'sha3.dart';

/// The raw Ed25519 public key behind an onion address.
typedef OnionPublicKey = Uint8List;

/// Tor rend-spec-v3 address derivation.
abstract final class OnionAddress {
  /// The only address version Tor currently supports.
  static const int version = 3;

  /// Length of an Ed25519 public key in bytes.
  static const int publicKeyLength = 32;

  /// The 35 bytes that get base32-encoded: key || checksum || version.
  static const int _encodedLength = publicKeyLength + 2 + 1;

  /// Length of a v3 address without the `.onion` suffix.
  static const int addressBodyLength = 56;

  /// The domain-separation prefix Tor hashes into the checksum.
  static const List<int> _checksumPrefix = <int>[
    0x2e, 0x6f, 0x6e, 0x69, 0x6f, 0x6e, 0x20, // ".onion "
    0x63, 0x68, 0x65, 0x63, 0x6b, 0x73, 0x75, 0x6d, // "checksum"
  ];

  static const String _alphabet = 'abcdefghijklmnopqrstuvwxyz234567';

  /// Computes the two-byte checksum for [publicKey].
  static Uint8List checksum(OnionPublicKey publicKey) {
    if (publicKey.length != publicKeyLength) {
      throw ArgumentError.value(
        publicKey.length,
        'publicKey',
        'an Ed25519 public key must be $publicKeyLength bytes',
      );
    }
    return Uint8List.fromList(
      Sha3.hashAll(<List<int>>[
        _checksumPrefix,
        publicKey,
        <int>[version],
      ]).sublist(0, 2),
    );
  }

  /// Derives the full address, including the `.onion` suffix, from an Ed25519
  /// public key.
  static String fromPublicKey(OnionPublicKey publicKey) {
    // Checked here rather than only inside `checksum`, because the copy into
    // `payload` below would otherwise fail with an opaque StateError from
    // inside `setRange` before the useful message could be produced.
    if (publicKey.length != publicKeyLength) {
      throw ArgumentError.value(
        publicKey.length,
        'publicKey',
        'an Ed25519 public key must be $publicKeyLength bytes',
      );
    }
    final payload = Uint8List(_encodedLength);
    payload.setRange(0, publicKeyLength, publicKey);
    payload.setRange(publicKeyLength, publicKeyLength + 2, checksum(publicKey));
    payload[_encodedLength - 1] = version;
    return '${_base32Encode(payload)}.onion';
  }

  /// True when [address] is a syntactically valid v3 onion address.
  static bool isValid(String address) {
    final body = _body(address);
    if (body == null || body.length != addressBodyLength) return false;
    final decoded = _tryBase32Decode(body);
    if (decoded == null || decoded.length != _encodedLength) return false;
    if (decoded[_encodedLength - 1] != version) return false;
    final key = Uint8List.sublistView(decoded, 0, publicKeyLength);
    final expected = checksum(key);
    return decoded[publicKeyLength] == expected[0] && decoded[publicKeyLength + 1] == expected[1];
  }

  /// Recovers the Ed25519 public key from an address, or null when the address
  /// is malformed or its checksum does not verify.
  static OnionPublicKey? publicKeyOf(String address) {
    if (!isValid(address)) return null;
    final decoded = _tryBase32Decode(_body(address)!);
    if (decoded == null) return null;
    return Uint8List.fromList(decoded.sublist(0, publicKeyLength));
  }

  /// Normalises user input: trims whitespace, lowercases and appends the
  /// `.onion` suffix when it is missing.
  static String normalise(String input) {
    var value = input.trim().toLowerCase();
    if (value.startsWith('http://')) value = value.substring(7);
    if (value.startsWith('https://')) value = value.substring(8);
    final slash = value.indexOf('/');
    if (slash >= 0) value = value.substring(0, slash);
    if (!value.endsWith('.onion')) value = '$value.onion';
    return value;
  }

  /// A shortened, display-friendly form: the first eight characters followed by
  /// an ellipsis, e.g. `darkflow…3x2q.onion`.
  static String shorten(String address, {int keep = 8}) {
    final body = _body(address);
    if (body == null || body.length <= keep * 2) return address;
    return '${body.substring(0, keep)}…${body.substring(body.length - 4)}.onion';
  }

  static String? _body(String address) {
    final trimmed = address.trim().toLowerCase();
    if (!trimmed.endsWith('.onion')) return null;
    final body = trimmed.substring(0, trimmed.length - '.onion'.length);
    if (body.isEmpty) return null;
    for (final unit in body.codeUnits) {
      if (!_isBase32(unit)) return null;
    }
    return body;
  }

  static bool _isBase32(int codeUnit) =>
      (codeUnit >= 0x61 && codeUnit <= 0x7a) || (codeUnit >= 0x32 && codeUnit <= 0x37);

  /// RFC 4648 base32, lowercase, without padding.
  static String _base32Encode(Uint8List data) {
    final out = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final byte in data) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        out.write(_alphabet[(buffer >> bits) & 0x1f]);
      }
    }
    if (bits > 0) {
      out.write(_alphabet[(buffer << (5 - bits)) & 0x1f]);
    }
    return out.toString();
  }

  static Uint8List? _tryBase32Decode(String value) {
    final out = <int>[];
    var buffer = 0;
    var bits = 0;
    for (final unit in value.codeUnits) {
      final index = _alphabet.codeUnitAt(0) <= unit && unit <= _alphabet.codeUnitAt(25)
          ? unit - 0x61
          : unit >= 0x32 && unit <= 0x37
              ? unit - 0x32 + 26
              : -1;
      if (index < 0) return null;
      buffer = (buffer << 5) | index;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xff);
      }
    }
    return Uint8List.fromList(out);
  }
}
