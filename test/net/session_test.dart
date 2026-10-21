import 'dart:convert';
import 'dart:typed_data';

import 'package:darkflow/src/crypto/crypto_engine.dart';
import 'package:darkflow/src/crypto/dart_crypto_engine.dart';
import 'package:darkflow/src/crypto/onion_address.dart';
import 'package:darkflow/src/net/protocol/session.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two peers derive their session keys from entirely different private
/// material, so the only way to know the protocol is right is to run both
/// sides. These tests do that, and then check that the things an attacker would
/// try — replaying a frame, swapping a handshake, dropping a message — fail.
class _Peer {
  _Peer(this.engine, this.identity, this.exchange);

  final CryptoEngine engine;
  final CryptoKeyPair identity;
  final CryptoKeyPair exchange;

  String get onion => OnionAddress.fromPublicKey(identity.publicKey);

  static Future<_Peer> create(CryptoEngine engine) async => _Peer(
        engine,
        await engine.generateEd25519(),
        await engine.generateX25519(),
      );

  Future<HandshakeOffer> offer({String name = 'peer'}) => HandshakeOffer.create(
        engine: engine,
        onionAddress: onion,
        identityPrivateKey: identity.privateKey,
        identityPublicKey: identity.publicKey,
        exchangePublicKey: exchange.publicKey,
        displayName: name,
      );
}

void main() {
  final engine = DartCryptoEngine();

  group('handshake offers', () {
    test('a well-formed offer verifies', () async {
      final peer = await _Peer.create(engine);
      final offer = await peer.offer();
      expect(await offer.verify(engine), isTrue);
    });

    test('the offer survives a JSON round trip', () async {
      final peer = await _Peer.create(engine);
      final offer = await peer.offer(name: 'Alice');
      final decoded = HandshakeOffer.fromJson(
        jsonDecode(jsonEncode(offer.toJson())) as Map<String, dynamic>,
      );
      expect(await decoded.verify(engine), isTrue);
      expect(decoded.displayName, 'Alice');
      expect(decoded.onionAddress, peer.onion);
    });

    test('claiming somebody else\'s onion address is rejected', () async {
      final alice = await _Peer.create(engine);
      final mallory = await _Peer.create(engine);
      final stolen = HandshakeOffer(
        onionAddress: alice.onion,
        identityPublicKey: mallory.identity.publicKey,
        exchangePublicKey: mallory.exchange.publicKey,
        ephemeralPublicKey: (await mallory.offer()).ephemeralPublicKey,
        signature: (await mallory.offer()).signature,
        displayName: 'Mallory',
      );
      // The address is derived from the key, so a mismatch is caught before the
      // signature is even considered.
      expect(await stolen.verify(engine), isFalse);
    });

    test('tampering with the ephemeral key invalidates the signature', () async {
      final peer = await _Peer.create(engine);
      final offer = await peer.offer();
      final tampered = HandshakeOffer(
        onionAddress: offer.onionAddress,
        identityPublicKey: offer.identityPublicKey,
        exchangePublicKey: offer.exchangePublicKey,
        ephemeralPublicKey: Uint8List.fromList(offer.ephemeralPublicKey)..[0] ^= 0x01,
        signature: offer.signature,
        displayName: offer.displayName,
      );
      expect(await tampered.verify(engine), isFalse);
    });

    test('tampering with the long-term exchange key invalidates the signature', () async {
      final peer = await _Peer.create(engine);
      final offer = await peer.offer();
      final tampered = HandshakeOffer(
        onionAddress: offer.onionAddress,
        identityPublicKey: offer.identityPublicKey,
        exchangePublicKey: Uint8List.fromList(offer.exchangePublicKey)..[0] ^= 0x01,
        ephemeralPublicKey: offer.ephemeralPublicKey,
        signature: offer.signature,
        displayName: offer.displayName,
      );
      expect(await tampered.verify(engine), isFalse);
    });
  });

  group('root key derivation', () {
    test('both sides arrive at the same root key', () async {
      final alice = await _Peer.create(engine);
      final bob = await _Peer.create(engine);

      final aliceEphemeral = await engine.generateX25519();
      final bobEphemeral = await engine.generateX25519();

      final aliceOffer = HandshakeOffer(
        onionAddress: alice.onion,
        identityPublicKey: alice.identity.publicKey,
        exchangePublicKey: alice.exchange.publicKey,
        ephemeralPublicKey: aliceEphemeral.publicKey,
        signature: Uint8List(64),
        displayName: 'Alice',
      );
      final bobOffer = HandshakeOffer(
        onionAddress: bob.onion,
        identityPublicKey: bob.identity.publicKey,
        exchangePublicKey: bob.exchange.publicKey,
        ephemeralPublicKey: bobEphemeral.publicKey,
        signature: Uint8List(64),
        displayName: 'Bob',
      );

      final aliceRoot = await SessionHandshake.deriveRoot(
        engine: engine,
        isInitiator: true,
        myExchangePrivateKey: alice.exchange.privateKey,
        myEphemeralPrivateKey: aliceEphemeral.privateKey,
        peer: bobOffer,
        myOnionAddress: alice.onion,
      );
      final bobRoot = await SessionHandshake.deriveRoot(
        engine: engine,
        isInitiator: false,
        myExchangePrivateKey: bob.exchange.privateKey,
        myEphemeralPrivateKey: bobEphemeral.privateKey,
        peer: aliceOffer,
        myOnionAddress: bob.onion,
      );

      expect(aliceRoot, equals(bobRoot));
    });

    test('a third party with the long-term keys but no ephemeral cannot derive it', () async {
      final alice = await _Peer.create(engine);
      final bob = await _Peer.create(engine);
      final aliceEphemeral = await engine.generateX25519();
      final bobEphemeral = await engine.generateX25519();

      final bobOffer = HandshakeOffer(
        onionAddress: bob.onion,
        identityPublicKey: bob.identity.publicKey,
        exchangePublicKey: bob.exchange.publicKey,
        ephemeralPublicKey: bobEphemeral.publicKey,
        signature: Uint8List(64),
        displayName: 'Bob',
      );

      final real = await SessionHandshake.deriveRoot(
        engine: engine,
        isInitiator: true,
        myExchangePrivateKey: alice.exchange.privateKey,
        myEphemeralPrivateKey: aliceEphemeral.privateKey,
        peer: bobOffer,
        myOnionAddress: alice.onion,
      );
      final guessed = await SessionHandshake.deriveRoot(
        engine: engine,
        isInitiator: true,
        myExchangePrivateKey: alice.exchange.privateKey,
        myEphemeralPrivateKey: (await engine.generateX25519()).privateKey,
        peer: bobOffer,
        myOnionAddress: alice.onion,
      );
      expect(guessed, isNot(equals(real)));
    });
  });

  group('session cipher', () {
    Future<(SessionCipher, SessionCipher)> pair() async {
      final root = engine.randomBytes(32);
      return (
        SessionCipher(engine: engine, rootKey: root, isInitiator: true),
        SessionCipher(engine: engine, rootKey: root, isInitiator: false),
      );
    }

    test('the initiator can talk to the responder', () async {
      final (alice, bob) = await pair();
      expect(bob.decrypt(alice.encrypt(utf8.encode('hello'))), utf8.encode('hello'));
    });

    test('the responder can talk to the initiator', () async {
      final (alice, bob) = await pair();
      expect(alice.decrypt(bob.encrypt(utf8.encode('hi back'))), utf8.encode('hi back'));
    });

    test('many messages in both directions', () async {
      final (alice, bob) = await pair();
      for (var i = 0; i < 40; i++) {
        expect(bob.decrypt(alice.encrypt(utf8.encode('a$i'))), utf8.encode('a$i'));
        expect(alice.decrypt(bob.encrypt(utf8.encode('b$i'))), utf8.encode('b$i'));
      }
    });

    test('replaying a frame is refused', () async {
      final (alice, bob) = await pair();
      final sealed = alice.encrypt(utf8.encode('once'));
      expect(bob.decrypt(sealed), utf8.encode('once'));
      expect(() => bob.decrypt(sealed), throwsA(isA<CryptoFailure>()));
    });

    test('a frame beyond the skip window is refused', () async {
      final (alice, bob) = await pair();
      for (var i = 0; i < SessionCipher.maxSkip + 5; i++) {
        alice.encrypt(utf8.encode('filler $i'));
      }
      expect(
        () => bob.decrypt(alice.encrypt(utf8.encode('too far'))),
        throwsA(isA<CryptoFailure>()),
      );
    });

    test('a tampered frame is refused', () async {
      final (alice, bob) = await pair();
      final sealed = Uint8List.fromList(alice.encrypt(utf8.encode('hello')));
      sealed[sealed.length - 1] ^= 0x01;
      expect(() => bob.decrypt(sealed), throwsA(isA<CryptoFailure>()));
    });

    test('the two directions use independent chains', () async {
      final (alice, bob) = await pair();
      // Alice's first frame and Bob's first frame are sealed under different
      // chains, so their nonces and ciphertexts cannot collide.
      final fromAlice = alice.encrypt(utf8.encode('same text'));
      final fromBob = bob.encrypt(utf8.encode('same text'));
      expect(fromAlice, isNot(equals(fromBob)));
    });

    test('a truncated frame is refused', () async {
      final (alice, bob) = await pair();
      final sealed = alice.encrypt(utf8.encode('hello'));
      expect(
        () => bob.decrypt(sealed.sublist(0, 3)),
        throwsA(isA<CryptoFailure>()),
      );
    });
  });

  group('safety number', () {
    test('is stable and grouped', () {
      const address = 'duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion';
      final number = safetyNumber(address);
      expect(safetyNumber(address), number);
      expect(number.split(' '), hasLength(4));
      expect(number, matches(RegExp(r'^[A-Z2-7]{4} [A-Z2-7]{4} [A-Z2-7]{4} [A-Z2-7]{4}$')));
    });

    test('differs between addresses', () {
      expect(
        safetyNumber('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion'),
        isNot(equals(
          safetyNumber('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.onion'),
        )),
      );
    });
  });
}
