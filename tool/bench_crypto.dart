// Measures the primitives DarkFlow depends on, on the pure-Dart backend.
//
// Argon2id is the decisive one: it runs once per unlock, so anything above a
// couple of seconds is a user-visible stall, while AES-GCM throughput sets how
// long sending a file takes.
//
// Run:  dart run tool/bench_crypto.dart

// ignore_for_file: avoid_print

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

Uint8List randomBytes(int n) {
  final random = Random.secure();
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = random.nextInt(256);
  }
  return out;
}

Future<void> benchArgon2({required int memoryKib, required int iterations, required int parallelism}) async {
  final algorithm = DartArgon2id(
    memory: memoryKib,
    iterations: iterations,
    parallelism: parallelism,
    hashLength: 32,
  );
  final stopwatch = Stopwatch()..start();
  await algorithm.deriveKey(
    secretKey: SecretKeyData(randomBytes(16)),
    nonce: randomBytes(16),
  );
  stopwatch.stop();
  print(
    'Argon2id  m=${(memoryKib / 1024).toStringAsFixed(0)} MiB  t=$iterations  p=$parallelism'
    '  ->  ${stopwatch.elapsedMilliseconds} ms',
  );
}

Future<void> benchAesGcm({required int megabytes}) async {
  final algorithm = DartAesGcm.with256bits();
  final key = SecretKeyData(randomBytes(32));
  final data = randomBytes(megabytes * 1024 * 1024);
  final nonce = randomBytes(12);

  final stopwatch = Stopwatch()..start();
  final box = await algorithm.encrypt(data, secretKey: key, nonce: nonce);
  final cipherText = Uint8List.fromList(box.cipherText);
  stopwatch.stop();
  final encryptMs = stopwatch.elapsedMicroseconds / 1000;

  final openWatch = Stopwatch()..start();
  await algorithm.decrypt(
    SecretBox(cipherText, nonce: nonce, mac: box.mac),
    secretKey: key,
  );
  openWatch.stop();
  final decryptMs = openWatch.elapsedMicroseconds / 1000;

  print(
    'AES-256-GCM  $megabytes MiB  ->  encrypt ${encryptMs.toStringAsFixed(0)} ms '
    '(${(megabytes * 1000 / encryptMs).toStringAsFixed(1)} MiB/s), '
    'decrypt ${decryptMs.toStringAsFixed(0)} ms '
    '(${(megabytes * 1000 / decryptMs).toStringAsFixed(1)} MiB/s)',
  );
}

Future<void> benchCurves() async {
  final ed = DartEd25519();
  final pair = await ed.newKeyPairFromSeed(randomBytes(32));
  final message = randomBytes(1024);

  var stopwatch = Stopwatch()..start();
  for (var i = 0; i < 20; i++) {
    await ed.sign(message + Uint8List.fromList([i]), keyPair: pair);
  }
  stopwatch.stop();
  print('Ed25519 sign      ->  ${(stopwatch.elapsedMicroseconds / 20 / 1000).toStringAsFixed(2)} ms/op');

  final signature = await ed.sign(message, keyPair: pair);
  stopwatch = Stopwatch()..start();
  for (var i = 0; i < 20; i++) {
    await ed.verify(message, signature: signature);
  }
  stopwatch.stop();
  print('Ed25519 verify    ->  ${(stopwatch.elapsedMicroseconds / 20 / 1000).toStringAsFixed(2)} ms/op');

  final pairA = await ed.newKeyPairFromSeed(randomBytes(32));
  final publicA = await pairA.extractPublicKey();
  final x = DartX25519();
  final pairB = await x.newKeyPairFromSeed(randomBytes(32));
  final publicB = await pairB.extractPublicKey();
  final keyPairA = await pairA.extract();

  stopwatch = Stopwatch()..start();
  for (var i = 0; i < 20; i++) {
    await x.sharedSecretKey(keyPair: pairA, remotePublicKey: publicB);
  }
  stopwatch.stop();
  print('X25519 DH         ->  ${(stopwatch.elapsedMicroseconds / 20 / 1000).toStringAsFixed(2)} ms/op');
  // Keep the analyzer honest about the values used above.
  if (publicA.bytes.isEmpty || keyPairA.bytes.isEmpty) {
    print('unreachable');
  }
}

Future<void> main() async {
  print('--- DarkFlow pure-Dart crypto benchmark ---');
  await benchArgon2(memoryKib: 19 * 1024, iterations: 2, parallelism: 1);
  await benchArgon2(memoryKib: 32 * 1024, iterations: 3, parallelism: 2);
  await benchArgon2(memoryKib: 64 * 1024, iterations: 3, parallelism: 2);
  await benchAesGcm(megabytes: 16);
  await benchCurves();
}
