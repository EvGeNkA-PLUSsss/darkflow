import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as c;
import 'package:cryptography/dart.dart' as d;

import 'crypto_engine.dart';

/// The cryptography backend DarkFlow ships.
///
/// It is pure Dart — `package:cryptography`'s `Dart*` implementations — for a
/// specific, measured reason. The faster option would be libsodium through the
/// `sodium` package, but its Dart build hook decodes MSBuild's output as UTF-8,
/// and a Russian Windows has MSBuild answering in CP1251, so the hook throws
/// `FormatException: Unexpected extension byte` and `flutter build windows`
/// fails before CMake is ever reached. Since a messenger that cannot be built
/// is worth nothing, correctness of the build wins over raw speed.
///
/// The cost was measured on the target machine by `tool/bench_crypto.dart`:
///
/// | operation                    | result          |
/// |------------------------------|-----------------|
/// | Argon2id 64 MiB, t=3, p=2    | ~200 ms         |
/// | AES-256-GCM                  | ~14 MiB/s       |
/// | Ed25519 sign / verify        | 2.8 / 1.6 ms    |
///
/// Argon2id is the number that mattered, and 200 ms is comfortably interactive.
/// AES-GCM is the weak spot: fine for chat and for files of a few megabytes,
/// and the transfer progress indicator exists partly because of it. The
/// attached-MB scale is why attachment transfers are chunked and streamed
/// rather than buffered whole.
class DartCryptoEngine implements CryptoEngine {
  DartCryptoEngine();

  final Random _random = Random.secure();
  bool _initialised = false;

  /// AES-GCM's tag is appended to the ciphertext, matching the sealed-blob
  /// layout in `cipher.dart`.
  static const int _gcmTagLength = 16;

  @override
  String get backendName => 'cryptography 2.9.0 · pure Dart';

  @override
  bool get isNative => false;

  /// Pure-Dart AES is table driven and cannot claim hardware acceleration.
  /// Reporting this honestly matters: the security screen shows it, and a user
  /// on a slow device deserves to know why sending a large file takes a while.
  @override
  bool get hasAesHardware => false;

  @override
  Future<void> initialise() async {
    // Nothing to load; the flag exists so callers have one uniform lifecycle.
    _initialised = true;
  }

  @override
  Future<void> dispose() async {
    _initialised = false;
  }

  // ------------------------------------------------------------- primitives

  @override
  Uint8List randomBytes(int count) {
    final out = Uint8List(count);
    for (var i = 0; i < count; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  @override
  void wipe(Uint8List bytes) {
    // Best effort. The Dart VM may have moved or copied the buffer, so this
    // reduces the window in which a key sits in memory rather than closing it.
    bytes.fillRange(0, bytes.length, 0);
  }

  @override
  bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  @override
  Uint8List sha256(List<int> data) =>
      Uint8List.fromList(const d.DartSha256().hashSync(data).bytes);

  @override
  Uint8List blake2b(List<int> data, {int length = 32}) =>
      Uint8List.fromList(d.DartBlake2b(hashLengthInBytes: length).hashSync(data).bytes);

  @override
  Uint8List hmacSha256({required Uint8List key, required Uint8List data}) {
    // HMAC is written out here rather than taken from the cryptography package
    // because that package's synchronous MAC entry point requires a nonce,
    // which HMAC does not have and the signature only carries for AEAD MACs.
    // The construction is four lines of SHA-256, and having it inline keeps the
    // engine honest about which primitive is doing the work.
    const blockSize = 64;
    final effectiveKey = key.length > blockSize ? sha256(key) : key;

    final inner = Uint8List(blockSize + data.length);
    final outer = Uint8List(blockSize + 32);
    for (var i = 0; i < blockSize; i++) {
      final byte = i < effectiveKey.length ? effectiveKey[i] : 0;
      inner[i] = byte ^ 0x36;
      outer[i] = byte ^ 0x5c;
    }
    inner.setRange(blockSize, inner.length, data);
    outer.setRange(blockSize, outer.length, sha256(inner));
    return sha256(outer);
  }

  // ------------------------------------------------------------------- AEAD

  @override
  Uint8List aesGcmEncrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List plaintext,
    required Uint8List aad,
  }) {
    try {
      final box = d.DartAesGcm.with256bits().encryptSync(
        plaintext,
        secretKeyData: c.SecretKeyData(key),
        nonce: nonce,
        aad: aad,
      );
      final out = Uint8List(box.cipherText.length + box.mac.bytes.length);
      out.setRange(0, box.cipherText.length, box.cipherText);
      out.setRange(box.cipherText.length, out.length, box.mac.bytes);
      return out;
    } on Object catch (error) {
      throw CryptoFailure('AES-256-GCM encryption failed', cause: error);
    }
  }

  @override
  Uint8List aesGcmDecrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List aad,
  }) {
    if (ciphertext.length < _gcmTagLength) {
      throw const CryptoFailure('ciphertext is shorter than the GCM tag');
    }
    final body = Uint8List.sublistView(ciphertext, 0, ciphertext.length - _gcmTagLength);
    final tag = Uint8List.sublistView(ciphertext, ciphertext.length - _gcmTagLength);
    try {
      final clear = d.DartAesGcm.with256bits().decryptSync(
        c.SecretBox(body, nonce: nonce, mac: c.Mac(tag)),
        secretKeyData: c.SecretKeyData(key),
        aad: aad,
      );
      return Uint8List.fromList(clear);
    } on Object catch (error) {
      // A wrong key and a tampered message are indistinguishable here, and
      // deliberately so: the caller must not learn which one happened.
      throw CryptoFailure('AES-256-GCM authentication failed', cause: error);
    }
  }

  // ---------------------------------------------------------------- hashing

  @override
  Future<Uint8List> argon2id({
    required Uint8List password,
    required Uint8List salt,
    required Argon2Params params,
  }) async {
    if (params.parallelism < 1) {
      throw ArgumentError.value(params.parallelism, 'parallelism', 'must be at least 1');
    }
    if (params.memoryKib < 8 * params.parallelism) {
      throw ArgumentError.value(
        params.memoryKib,
        'memoryKib',
        'Argon2 requires at least 8 KiB per lane',
      );
    }

    final memory = params.memoryKib;
    final iterations = params.iterations;
    final parallelism = params.parallelism;
    final tagLength = params.tagLength;

    // Run off the main isolate: even 200 ms of solid CPU would drop frames, and
    // on a low-end phone this is several times slower.
    return Isolate.run(() async {
      final algorithm = d.DartArgon2id(
        memory: memory,
        iterations: iterations,
        parallelism: parallelism,
        hashLength: tagLength,
      );
      final secret = await algorithm.deriveKey(
        secretKey: c.SecretKeyData(password),
        nonce: salt,
      );
      return Uint8List.fromList(await secret.extractBytes());
    });
  }

  // ------------------------------------------------------------ signatures

  @override
  Future<CryptoKeyPair> generateEd25519() => ed25519KeyPairFromSeed(randomBytes(32));

  @override
  Future<CryptoKeyPair> ed25519KeyPairFromSeed(Uint8List seed) async {
    if (seed.length != 32) {
      throw ArgumentError.value(seed.length, 'seed', 'an Ed25519 seed is 32 bytes');
    }
    final pair = await d.DartEd25519().newKeyPairFromSeed(seed);
    final publicKey = await pair.extractPublicKey();
    // The seed, not the expanded key, is what gets stored: it is the smallest
    // representation, and Tor's hidden-service file format is the seed
    // followed by the public key, which the caller can build from these two.
    return CryptoKeyPair(
      publicKey: Uint8List.fromList(publicKey.bytes),
      privateKey: Uint8List.fromList(seed),
    );
  }

  @override
  Future<Uint8List> ed25519PublicFromPrivate(Uint8List privateKey) async {
    final pair = await ed25519KeyPairFromSeed(privateKey);
    return pair.publicKey;
  }

  @override
  Future<Uint8List> ed25519Sign({
    required Uint8List privateKey,
    required Uint8List message,
  }) async {
    final algorithm = d.DartEd25519();
    final keyPair = await algorithm.newKeyPairFromSeed(privateKey);
    final signature = await algorithm.sign(message, keyPair: keyPair);
    return Uint8List.fromList(signature.bytes);
  }

  @override
  Future<bool> ed25519Verify({
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) async {
    if (signature.length != 64 || publicKey.length != 32) return false;
    try {
      return await d.DartEd25519().verify(
        message,
        signature: c.Signature(
          signature,
          publicKey: c.SimplePublicKey(publicKey, type: c.KeyPairType.ed25519),
        ),
      );
    } on Object {
      // A malformed point or an out-of-range scalar is not an exception the
      // caller cares about — it simply is not a valid signature.
      return false;
    }
  }

  // ---------------------------------------------------------- key agreement

  @override
  Future<CryptoKeyPair> generateX25519() => x25519KeyPairFromSeed(randomBytes(32));

  @override
  Future<CryptoKeyPair> x25519KeyPairFromSeed(Uint8List seed) async {
    if (seed.length != 32) {
      throw ArgumentError.value(seed.length, 'seed', 'an X25519 seed is 32 bytes');
    }
    final pair = await d.DartX25519().newKeyPairFromSeed(seed);
    final publicKey = await pair.extractPublicKey();
    // The raw seed is returned rather than the library's clamped copy, so a key
    // means the same thing on every backend; clamping happens on use.
    return CryptoKeyPair(
      publicKey: Uint8List.fromList(publicKey.bytes),
      privateKey: Uint8List.fromList(seed),
    );
  }

  @override
  Future<Uint8List> x25519PublicFromPrivate(Uint8List privateKey) async {
    final pair = await x25519KeyPairFromSeed(privateKey);
    return pair.publicKey;
  }

  @override
  Future<Uint8List> x25519({
    required Uint8List privateKey,
    required Uint8List publicKey,
  }) async {
    if (publicKey.length != 32) {
      throw ArgumentError.value(publicKey.length, 'publicKey', 'an X25519 key is 32 bytes');
    }
    final algorithm = d.DartX25519();
    final keyPair = await algorithm.newKeyPairFromSeed(privateKey);
    final shared = await algorithm.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: c.SimplePublicKey(publicKey, type: c.KeyPairType.x25519),
    );
    final bytes = await shared.extractBytes();
    if (bytes.every((byte) => byte == 0)) {
      // An all-zero shared secret means the peer sent a low-order point, which
      // would let anyone decrypt the session. RFC 7748 requires rejecting it.
      throw const CryptoFailure('X25519 produced an all-zero shared secret');
    }
    return Uint8List.fromList(bytes);
  }

  /// True once [initialise] has run. Exposed for assertions in tests.
  bool get isInitialised => _initialised;
}
