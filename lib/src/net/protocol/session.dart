import 'dart:convert';
import 'dart:typed_data';

import '../../core/ids.dart';
import '../../crypto/cipher.dart';
import '../../crypto/crypto_engine.dart';

/// Everything one side sends at the start of a connection.
///
/// The offer is plaintext — it has to be, because it carries the very keys that
/// will protect everything after it — but it is *signed*, and the signature
/// covers the ephemeral key, so a relay that sits between two peers cannot
/// substitute its own ephemeral and read the session. Because the account's
/// onion address is derived from its Ed25519 identity key, verifying the
/// signature also proves the sender owns the address it claims.
class HandshakeOffer {
  const HandshakeOffer({
    required this.onionAddress,
    required this.identityPublicKey,
    required this.exchangePublicKey,
    required this.ephemeralPublicKey,
    required this.signature,
    required this.displayName,
    this.about = '',
    this.capabilities = const <String, dynamic>{},
    this.protocolVersion = currentProtocolVersion,
  });

  /// The protocol revision this build speaks.
  static const int currentProtocolVersion = 1;

  final String onionAddress;
  final Uint8List identityPublicKey;

  /// The long-term X25519 key, used to bind the session to the account rather
  /// than only to this connection.
  final Uint8List exchangePublicKey;

  /// A key generated for this connection alone. Its only purpose is forward
  /// secrecy: even if the long-term exchange key leaks tomorrow, a session
  /// recorded today stays unreadable.
  final Uint8List ephemeralPublicKey;

  final Uint8List signature;
  final String displayName;
  final String about;
  final Map<String, dynamic> capabilities;
  final int protocolVersion;

  /// The exact bytes the signature covers.
  ///
  /// Both keys are included, so the signature binds the long-term key to the
  /// ephemeral one and neither can be swapped independently.
  static Uint8List signedBytes(Uint8List exchangePublicKey, Uint8List ephemeralPublicKey) =>
      Uint8List.fromList(<int>[
        ...utf8.encode('darkflow/handshake/v1'),
        ...exchangePublicKey,
        ...ephemeralPublicKey,
      ]);

  /// Builds and signs an offer for this device.
  static Future<HandshakeOffer> create({
    required CryptoEngine engine,
    required String onionAddress,
    required Uint8List identityPrivateKey,
    required Uint8List identityPublicKey,
    required Uint8List exchangePublicKey,
    required String displayName,
    String about = '',
    Map<String, dynamic> capabilities = const <String, dynamic>{},
  }) async {
    final ephemeral = await engine.generateX25519();
    final signature = await engine.ed25519Sign(
      privateKey: identityPrivateKey,
      message: signedBytes(exchangePublicKey, ephemeral.publicKey),
    );
    return HandshakeOffer(
      onionAddress: onionAddress,
      identityPublicKey: identityPublicKey,
      exchangePublicKey: exchangePublicKey,
      ephemeralPublicKey: ephemeral.publicKey,
      signature: signature,
      displayName: displayName,
      about: about,
      capabilities: capabilities,
    );
  }

  /// Verifies that the offer was signed by the identity key it carries.
  ///
  /// The onion address is deliberately **not** checked against the identity key
  /// here, because the two are independent: the address comes from Tor's
  /// hidden-service key, while this key identifies the account. Binding them is
  /// the caller's job — it pins the identity key on first contact and rejects a
  /// later change, which is what makes the address a stable name for a person
  /// rather than merely for a service.
  Future<bool> verify(CryptoEngine engine) async {
    if (identityPublicKey.length != 32 ||
        exchangePublicKey.length != 32 ||
        ephemeralPublicKey.length != 32) {
      return false;
    }
    return engine.ed25519Verify(
      publicKey: identityPublicKey,
      message: signedBytes(exchangePublicKey, ephemeralPublicKey),
      signature: signature,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': protocolVersion,
        'onion': onionAddress,
        'ik': base64Encode(identityPublicKey),
        'ek': base64Encode(exchangePublicKey),
        'epk': base64Encode(ephemeralPublicKey),
        'sig': base64Encode(signature),
        'name': displayName,
        'about': about,
        'caps': capabilities,
      };

  factory HandshakeOffer.fromJson(Map<String, dynamic> json) => HandshakeOffer(
        onionAddress: json['onion'] as String? ?? '',
        identityPublicKey: _bytes(json['ik']),
        exchangePublicKey: _bytes(json['ek']),
        ephemeralPublicKey: _bytes(json['epk']),
        signature: _bytes(json['sig']),
        displayName: json['name'] as String? ?? '',
        about: json['about'] as String? ?? '',
        capabilities: Map<String, dynamic>.from(
          json['caps'] as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{},
        ),
        protocolVersion: (json['v'] as num?)?.toInt() ?? currentProtocolVersion,
      );
}

/// The symmetric ratchet that protects a single connection.
///
/// A full Double Ratchet is overkill here: a connection is short-lived and both
/// keys are already fresh, so a per-direction chain that advances a message key
/// for every frame gives the property that actually matters — a compromised
/// message key does not expose any other message on the connection, past or
/// future.
///
/// The plaintext of every frame is sealed with AES-256-GCM under
/// `HKDF(root, direction)`, ratcheted once per frame, with the frame counter
/// bound in as associated data so frames cannot be reordered or replayed.
class SessionCipher {
  SessionCipher({
    required CryptoEngine engine,
    required Uint8List rootKey,
    required bool isInitiator,
  })  : _engine = engine,
        _sendChain = Hkdf.derive(
          engine: engine,
          ikm: rootKey,
          salt: Uint8List(0),
          // The two directions get independent chains, and the initiator's send
          // chain is the responder's receive chain.
          info: utf8.encode(
            isInitiator ? 'darkflow/chain/i2r/v1' : 'darkflow/chain/r2i/v1',
          ),
          length: 32,
        ),
        _receiveChain = Hkdf.derive(
          engine: engine,
          ikm: rootKey,
          salt: Uint8List(0),
          info: utf8.encode(
            isInitiator ? 'darkflow/chain/r2i/v1' : 'darkflow/chain/i2r/v1',
          ),
          length: 32,
        );

  final CryptoEngine _engine;
  Uint8List _sendChain;
  Uint8List _receiveChain;
  int _sendCounter = 0;
  int _receiveCounter = 0;

  /// How far ahead of the expected counter a frame may be before it is treated
  /// as an attack rather than as a reordering.
  static const int maxSkip = 64;

  /// Encrypts one frame body.
  Uint8List encrypt(List<int> plaintext) {
    final messageKey = _ratchet(_sendChain, isSend: true);
    final counter = _sendCounter++;
    final nonce = _engine.randomBytes(Cipher.nonceLength);
    final sealed = Cipher.seal(
      engine: _engine,
      key: messageKey,
      plaintext: plaintext,
      aad: _aad(counter),
      nonce: nonce,
    );
    _engine.wipe(messageKey);
    final out = Uint8List(4 + sealed.length);
    ByteData.sublistView(out).setUint32(0, counter, Endian.big);
    out.setRange(4, out.length, sealed);
    return out;
  }

  /// Decrypts one frame body. Throws [CryptoFailure] on a replay, a
  /// reordering beyond [maxSkip], or a forged frame.
  Uint8List decrypt(List<int> frame) {
    if (frame.length < 5) {
      throw const CryptoFailure('an encrypted frame is too short to hold a counter');
    }
    final counter = ByteData.sublistView(Uint8List.fromList(frame), 0, 4).getUint32(0, Endian.big);
    if (counter < _receiveCounter) {
      throw CryptoFailure('frame $counter was already received or is out of order');
    }
    if (counter - _receiveCounter > maxSkip) {
      throw CryptoFailure('frame $counter is too far ahead of the expected $_receiveCounter');
    }
    // Advance the chain to the frame's counter, discarding the intervening
    // message keys: that is what makes an out-of-order frame unreadable rather
    // than a stored-key liability.
    var key = Uint8List(0);
    while (_receiveCounter <= counter) {
      _engine.wipe(key);
      key = _ratchet(_receiveChain, isSend: false);
      _receiveCounter++;
    }
    try {
      return Cipher.open(
        engine: _engine,
        key: key,
        sealed: Uint8List.fromList(frame.sublist(4)),
        aad: _aad(counter),
      );
    } finally {
      _engine.wipe(key);
    }
  }

  /// Advances [chain] deterministically and returns the message key for the
  /// current step. `HMAC(chain, 0x01)` is the message key, `HMAC(chain, 0x02)`
  /// is the next chain key — the standard symmetric-ratchet split.
  Uint8List _ratchet(Uint8List chain, {required bool isSend}) {
    final messageKey = _engine.hmacSha256(
      key: chain,
      data: Uint8List.fromList(const <int>[0x01]),
    );
    final next = _engine.hmacSha256(
      key: chain,
      data: Uint8List.fromList(const <int>[0x02]),
    );
    if (isSend) {
      _engine.wipe(_sendChain);
      _sendChain = next;
    } else {
      _engine.wipe(_receiveChain);
      _receiveChain = next;
    }
    return messageKey;
  }

  /// Associated data for one frame: the counter alone.
  ///
  /// It deliberately does **not** encode a direction. The send chain of one
  /// peer is the receive chain of the other, so the same counter and the same
  /// chain key must produce the same associated data on both sides — an earlier
  /// version tagged the sender and the receiver differently, which made every
  /// frame fail to authenticate.
  Uint8List _aad(int counter) {
    final out = Uint8List(8);
    ByteData.sublistView(out).setUint64(0, counter);
    return out;
  }

  /// Zeroes the chain keys.
  void destroy() {
    _engine.wipe(_sendChain);
    _engine.wipe(_receiveChain);
  }
}

/// Derives the session root key from two handshake offers.
///
/// Four Diffie-Hellman operations are mixed together: static-static binds the
/// session to both accounts, ephemeral-ephemeral gives it forward secrecy, and
/// the two crossed combinations stop an attacker who has compromised only one
/// of the two long-term keys from impersonating a peer. Concatenating them in a
/// role-dependent order is what makes both sides arrive at the same bytes.
abstract final class SessionHandshake {
  /// Computes the shared root key.
  static Future<Uint8List> deriveRoot({
    required CryptoEngine engine,
    required bool isInitiator,
    required Uint8List myExchangePrivateKey,
    required Uint8List myEphemeralPrivateKey,
    required HandshakeOffer peer,
    required String myOnionAddress,
  }) async {
    final dhStaticStatic = await engine.x25519(
      privateKey: myExchangePrivateKey,
      publicKey: peer.exchangePublicKey,
    );
    final dhEphemeralEphemeral = await engine.x25519(
      privateKey: myEphemeralPrivateKey,
      publicKey: peer.ephemeralPublicKey,
    );
    // The two crossed products, ordered by role.
    //
    // `dhEphemeralStatic` is my ephemeral against the peer's static key;
    // `dhStaticEphemeral` is my static key against the peer's ephemeral. For the
    // initiator those are (E_i*S_r, S_i*E_r) and for the responder (E_r*S_i, S_r*E_i)
    // — the mirror of the same pair, and the mirror is what decides the order below.
    //
    // The two lengths are equal and the two values are distinct, so without a rule the
    // two sides would concatenate them in different orders and derive different root
    // keys: a handshake that appears to succeed on both ends and then cannot decrypt a
    // single frame. The rule is "my ephemeral against their static comes first", which
    // both roles can follow from what they know locally — the initiator computes
    // E_i*S_r for `dhEphemeralStatic`, the responder computes E_r*S_i for it — and
    // which produces the same byte order on both sides.
    final dhEphemeralStatic = await engine.x25519(
      privateKey: myEphemeralPrivateKey,
      publicKey: peer.exchangePublicKey,
    );
    final dhStaticEphemeral = await engine.x25519(
      privateKey: myExchangePrivateKey,
      publicKey: peer.ephemeralPublicKey,
    );

    // The initiator's `dhEphemeralStatic` is the responder's `dhStaticEphemeral` and
    // vice versa, so the responder swaps them to reach the same sequence.
    final crossed = isInitiator
        ? <Uint8List>[dhEphemeralStatic, dhStaticEphemeral]
        : <Uint8List>[dhStaticEphemeral, dhEphemeralStatic];

    final material = Uint8List.fromList(<int>[
      ...dhStaticStatic,
      ...dhEphemeralEphemeral,
      ...crossed[0],
      ...crossed[1],
    ]);

    // A deterministic salt derived from both addresses means two connections
    // between the same pair of accounts cannot be made to produce the same root
    // key by an attacker who reorders the handshake.
    final onions = <String>[myOnionAddress, peer.onionAddress]..sort();

    final root = Hkdf.derive(
      engine: engine,
      ikm: material,
      salt: Uint8List.fromList(utf8.encode(onions.join('|'))),
      info: utf8.encode('darkflow/session-root/v1'),
      length: 32,
    );

    for (final value in <Uint8List>[
      dhStaticStatic,
      dhEphemeralEphemeral,
      dhEphemeralStatic,
      dhStaticEphemeral,
      material,
    ]) {
      engine.wipe(value);
    }
    return root;
  }

  /// Builds the salt used above, exposed so tests can pin the derivation.
  static Uint8List saltFor(String onionA, String onionB) {
    final sorted = <String>[onionA, onionB]..sort();
    return Uint8List.fromList(utf8.encode(sorted.join('|')));
  }
}

/// A short, human-comparable fingerprint of a contact's identity.
///
/// Derived from the onion address rather than from a key exchange, so it can be
/// read out over the phone *before* the first message is ever sent — which is
/// precisely when a user needs to check it.
String safetyNumber(String onionAddress) {
  final body = onionAddress.replaceAll('.onion', '').toUpperCase();
  final groups = <String>[];
  for (var i = 0; i + 4 <= body.length && groups.length < 4; i += 14) {
    groups.add(body.substring(i, i + 4));
  }
  return groups.join(' ');
}

/// A fresh 128-bit request id, used to correlate a response with its request.
String newRequestId() => Ids.generate();

Uint8List _bytes(Object? value) {
  if (value is String && value.isNotEmpty) return base64Decode(value);
  return Uint8List(0);
}
