import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../app/log_book.dart';
import '../crypto/cipher.dart';
import '../crypto/crypto_engine.dart';
import '../data/models/message.dart';
import '../data/models/relay.dart';
import '../net/peer_connection.dart';
import '../net/peer_stream.dart';
import '../net/protocol/frames.dart' as payload;
import 'file_transfer.dart';

/// The account material the mesh needs in order to encrypt and sign.
class MeshIdentity {
  const MeshIdentity({
    required this.onionAddress,
    required this.identityPrivateKey,
    required this.identityPublicKey,
    required this.exchangePrivateKey,
    required this.exchangePublicKey,
    required this.displayName,
    this.about = '',
  });

  final String onionAddress;
  final Uint8List identityPrivateKey;
  final Uint8List identityPublicKey;
  final Uint8List exchangePrivateKey;
  final Uint8List exchangePublicKey;
  final String displayName;
  final String about;
}

/// End-to-end encryption for messages that travel through relays.
///
/// This is deliberately separate from the connection's session cipher. A
/// session key only exists while two peers are connected; an envelope may sit
/// on a third party's disk for days. So envelopes are sealed to the
/// *destination's long-term key* instead, which is what lets a relay store and
/// forward a message it can never read.
abstract final class EnvelopeCipher {
  /// Derives the shared key for the pair (me, peer).
  ///
  /// The salt is the two onion addresses in sorted order, so both sides derive
  /// the same key without having to agree on who speaks first, and a message
  /// cannot be replayed into a different conversation.
  static Future<Uint8List> sharedKey({
    required CryptoEngine engine,
    required Uint8List myExchangePrivateKey,
    required Uint8List peerExchangePublicKey,
    required String myOnion,
    required String peerOnion,
  }) async {
    final secret = await engine.x25519(
      privateKey: myExchangePrivateKey,
      publicKey: peerExchangePublicKey,
    );
    final onions = <String>[myOnion, peerOnion]..sort();
    final key = Hkdf.derive(
      engine: engine,
      ikm: secret,
      salt: Uint8List.fromList(utf8.encode(onions.join('|'))),
      info: utf8.encode('darkflow/envelope/v1'),
      length: 32,
    );
    engine.wipe(secret);
    return key;
  }

  /// Seals [frame] for [peerOnion].
  static Future<Uint8List> seal({
    required CryptoEngine engine,
    required Uint8List myExchangePrivateKey,
    required Uint8List peerExchangePublicKey,
    required String myOnion,
    required String peerOnion,
    required payload.Frame frame,
  }) async {
    final key = await sharedKey(
      engine: engine,
      myExchangePrivateKey: myExchangePrivateKey,
      peerExchangePublicKey: peerExchangePublicKey,
      myOnion: myOnion,
      peerOnion: peerOnion,
    );
    try {
      return Cipher.seal(
        engine: engine,
        key: key,
        plaintext: utf8.encode(frame.encode()),
        aad: Cipher.recordAad('envelope', peerOnion),
      );
    } finally {
      engine.wipe(key);
    }
  }

  /// Opens an envelope that arrived from [fromOnion].
  static Future<payload.Frame> open({
    required CryptoEngine engine,
    required Uint8List myExchangePrivateKey,
    required Uint8List fromExchangePublicKey,
    required String myOnion,
    required String fromOnion,
    required Uint8List sealed,
  }) async {
    final key = await sharedKey(
      engine: engine,
      myExchangePrivateKey: myExchangePrivateKey,
      peerExchangePublicKey: fromExchangePublicKey,
      myOnion: myOnion,
      peerOnion: fromOnion,
    );
    try {
      final clear = Cipher.open(
        engine: engine,
        key: key,
        sealed: sealed,
        aad: Cipher.recordAad('envelope', myOnion),
      );
      // The sender's address is the one thing the payload cannot carry and the
      // receiver cannot guess, so it is handed to the decoder from the envelope
      // that was opened. See `MessageFrame.fromPayload`.
      return payload.Frame.decode(clear, peerOnion: fromOnion);
    } finally {
      engine.wipe(key);
    }
  }
}

/// Something the mesh produced that the UI should react to.
sealed class MeshEvent {
  const MeshEvent();
}

/// A message was received and decrypted.
class MeshMessageReceived extends MeshEvent {
  const MeshMessageReceived({
    required this.message,
    this.attachment,
    this.viaRelay = false,
    this.peerOnion = '',
  });

  final Message message;
  final Attachment? attachment;
  final bool viaRelay;

  /// The address the envelope came from, which is who wrote the message.
  ///
  /// Carried separately from [Message.peerOnion] rather than only on it, because
  /// the address is a property of the *envelope* and the account layer should not
  /// have to reconstruct it from whichever field happened to survive. It is
  /// normally the same value.
  final String peerOnion;
}

/// A receipt arrived for one of our messages.
class MeshReceiptReceived extends MeshEvent {
  const MeshReceiptReceived({required this.messageIds, required this.read, required this.at});

  final List<String> messageIds;
  final bool read;
  final DateTime at;
}

/// A handshake attempt with a peer failed.
///
/// Emitted so the account layer can tell the user why a message is still waiting, and
/// so the peer's own screen can show that the connection was tried rather than that
/// nothing has happened. Without it, `warmUp` swallowed everything: a message could sit
/// at "waiting for the first handshake" for ever with no evidence that an attempt had
/// been made, which is indistinguishable from a bug in the send path.
class MeshHandshakeFailed extends MeshEvent {
  const MeshHandshakeFailed({required this.onionAddress, required this.reason});

  final String onionAddress;
  final String reason;
}

/// A dial to a contact has begun.
///
/// ## Why a start event exists at all
///
/// Because a dial in progress and a pump that never ran looked identical. Both leave the
/// key map empty, both leave the failure map empty, and both leave the contact showing
/// "waiting for the first handshake" — so a report saying "no attempt has failed yet" could
/// not distinguish "we are trying right now" from "nothing will ever try". That ambiguity is
/// exactly what "after adding a contact nothing happens" ran into.
///
/// A Tor circuit through a peer that is not answering takes up to ninety seconds, which is
/// long enough for a user to conclude the app is broken. This event is what lets the
/// interface say that a dial is under way instead of showing them an empty conversation.
class MeshHandshakeStarted extends MeshEvent {
  const MeshHandshakeStarted({required this.onionAddress});

  final String onionAddress;
}

/// A call signal arrived from a peer.
///


///
/// Its own event rather than a field on [MeshMessageReceived]: the bytes and the
/// message that announces them travel as separate envelopes, in either order, and
/// the account layer has to be able to file a chunk whose message it has not seen.
class MeshAttachmentChunk extends MeshEvent {
  const MeshAttachmentChunk({required this.fromOnion, required this.payload});

  final String fromOnion;
  final ChunkPayload payload;
}

/// A peer's keys were learned, or its capabilities changed.
class MeshPeerLearned extends MeshEvent {
  const MeshPeerLearned({
    required this.onionAddress,
    required this.identityPublicKey,
    required this.exchangePublicKey,
    required this.displayName,
    required this.capabilities,
  });

  final String onionAddress;

  /// The key that signs this peer's handshakes. The account layer pins it on
  /// first contact and rejects a later change.
  final Uint8List identityPublicKey;

  final Uint8List exchangePublicKey;
  final String displayName;
  final Map<String, dynamic> capabilities;
}

/// Delivery state changed for an outbound envelope.
class MeshDeliveryChanged extends MeshEvent {
  const MeshDeliveryChanged({
    required this.envelopeId,
    required this.messageId,
    required this.status,
    this.failureReason,
    this.viaRelay,
  });

  final String envelopeId;
  final String messageId;
  final MessageStatus status;
  final String? failureReason;
  final bool? viaRelay;
}

/// The mesh: it decides whether a message goes straight to a peer or is handed
/// to a contact to carry, and it carries other people's messages in return.
///
/// The design goal from the architecture note is a network with no server. That
/// has a price: a peer that is offline cannot receive anything, so the sender
/// must find somebody who *is* reachable. The rule used here is deliberately
/// conservative — a message is only handed to contacts the user already knows,
/// and only when the direct attempt failed — because a mesh that forwards to
/// strangers is a mesh that leaks social graphs.
class MeshService {
  MeshService({
    required this._engine,
    required this._storageDirectory,
  });

  final CryptoEngine _engine;
  final Directory _storageDirectory;

  final StreamController<MeshEvent> _events = StreamController<MeshEvent>.broadcast();
  final Map<String, PeerConnection> _live = <String, PeerConnection>{};
  final Map<String, RelayEnvelope> _outbox = <String, RelayEnvelope>{};
  final Map<String, RelayEnvelope> _mailbox = <String, RelayEnvelope>{};
  final Map<String, PeerRecord> _peers = <String, PeerRecord>{};

  MeshIdentity? _identity;
  RelayPolicy _policy = const RelayPolicy();
  String _socksHost = '127.0.0.1';
  int _socksPort = 9050;
  int _remotePort = 80;
  Timer? _pump;

  /// Everything the mesh emits: received messages, receipts, learned keys.
  Stream<MeshEvent> get events => _events.stream;

  /// Contacts the mesh knows enough about to encrypt to.
  Map<String, PeerRecord> get peers => Map<String, PeerRecord>.unmodifiable(_peers);

  /// How many envelopes are waiting to be delivered.
  int get outboxSize => _outbox.length;

  /// How many envelopes are being held for other people.
  int get mailboxSize => _mailbox.length;

  /// Total bytes held for other people, for the storage quota display.
  int get mailboxBytes =>
      _mailbox.values.fold<int>(0, (sum, envelope) => sum + envelope.sizeBytes);

  bool get isConfigured => _identity != null && _socksPort > 0;

  /// The local identity, or null when the mesh has not been configured yet.
  ///
  /// Public because the account layer has to be able to send something that is
  /// merely *nice* — a reaction — without an exception when the network is not up.
  /// The throwing accessor stays for the paths where a missing identity really is a
  /// programming error.
  MeshIdentity? get identityOrNull => _identity;

  /// Supplies the account keys. Must be called before anything can be sent.
  ///
  /// ## A changed SOCKS port invalidates every live connection
  ///
  /// This is called on **every** Tor status change, which during a restart means several times
  /// with different ports. The previous version simply overwrote the fields, and that is wrong
  /// in a way that produces exactly the reported symptom: a connection opened through the old
  /// port stays in `_live`, `_connectionTo` hands it back because it is not closed, and every
  /// request written into it goes to a proxy that is no longer there. The peer looks
  /// "connected" and answers nothing, which is what "sometimes it works and usually there is no
  /// connection" looks like.
  ///
  /// So when the port or the host actually changes, the live connections are closed — not
  /// reused, not kept "just in case". They are dialled through a socket that no longer leads
  /// anywhere.
  void configure({
    required MeshIdentity identity,
    required String socksHost,
    required int socksPort,
    required int remotePort,
    RelayPolicy policy = const RelayPolicy(),
  }) {
    final transportChanged = _identity != null &&
        (socksHost != _socksHost || socksPort != _socksPort || remotePort != _remotePort);

    _identity = identity;
    _socksHost = socksHost;
    _socksPort = socksPort;
    _remotePort = remotePort;
    _policy = policy;

    if (transportChanged) {
      logMesh(
        'transport changed; closing live connections',
        detail: 'now $_socksHost:$_socksPort remote $_remotePort · '
            'closing ${_live.length} connection(s)',
      );
      // Not awaited: `configure` is called from a status listener, and awaiting a socket close
      // there would hold up the status the user is watching. The map is cleared synchronously so
      // nothing can hand a dying connection back in the meantime.
      final doomed = _live.values.toList(growable: false);
      _live.clear();
      for (final connection in doomed) {
        unawaited(connection.close());
      }
    }
  }

  /// How many connections are open right now.
  ///
  /// Reported beside the reachable count because the two together describe the state: peers
  /// reachable with no open link is a mesh that believes it can send and cannot.
  int get liveConnectionCount => _live.length;

  /// Replaces the relay policy.
  void setPolicy(RelayPolicy policy) => _policy = policy;

  /// Starts the background pump that retries the outbox and collects mail.
  void start() {
    _pump ??= Timer.periodic(const Duration(seconds: 20), (_) => unawaited(tick()));
  }

  /// Stops the pump and closes every live connection.
  Future<void> stop() async {
    _pump?.cancel();
    _pump = null;
    for (final connection in _live.values.toList(growable: false)) {
      await connection.close();
    }
    _live.clear();
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  /// Registers what we know about a contact so the mesh can encrypt to it.
  ///
  /// [keyAccepted] is the account layer's verdict on [exchangePublicKey]. The
  /// mesh on its own cannot reach one: a handshake proves that *whoever is
  /// answering* owns the exchange key it presents, not that the answerer is the
  /// contact. Only the account layer holds the pinned identity key that can tell
  /// those apart, so it passes the answer in and this refuses the key when the
  /// answer is no.
  ///
  /// Without that, a peer presenting a *different* identity key for a known
  /// address still had its exchange key stored here, and the next message was
  /// sealed to it — the impersonation was flagged on the contact record and then
  /// ignored at the one moment it mattered. A key already held is sticky by
  /// default for the same reason: an unexplained replacement is never an
  /// improvement.
  void rememberPeer({
    required String onionAddress,
    Uint8List? exchangePublicKey,
    String? displayName,
    PeerCapabilities? capabilities,
    bool keyAccepted = true,
  }) {
    final existing = _peers[onionAddress];
    _peers[onionAddress] = (existing ??
            PeerRecord(
              onionAddress: onionAddress,
              firstSeenAt: DateTime.now().toUtc(),
            ))
        .copyWith(
      lastSeenAt: DateTime.now().toUtc(),
      isReachable: true,
      capabilities: capabilities,
    );
    if (exchangePublicKey != null && keyAccepted) {
      final held = _keys[onionAddress];
      if (held == null || _sameKey(held, exchangePublicKey)) {
        _keys[onionAddress] = exchangePublicKey;
      }
    }
    if (displayName != null && displayName.isNotEmpty) {
      _displayNames[onionAddress] = displayName;
    }
  }

  static bool _sameKey(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  final Map<String, Uint8List> _keys = <String, Uint8List>{};
  final Map<String, String> _displayNames = <String, String>{};

  /// Forgets everything remembered about [onionAddress].
  ///
  /// Called when a contact is deleted. Without it the peer would stay a delivery
  /// candidate, keep its exchange key so a message could still be encrypted to it,
  /// and keep counting as a known contact under a contacts-only relay policy —
  /// three ways for a "deleted" contact to stay reachable.
  void removePeer(String onionAddress) {
    _peers.remove(onionAddress);
    _keys.remove(onionAddress);
    _displayNames.remove(onionAddress);
  }

  /// The exchange key known for [onionAddress], if any.
  Uint8List? exchangeKeyOf(String onionAddress) => _keys[onionAddress];

  /// True when this peer answered recently enough to be worth dialling.
  ///
  /// Deliberately not the same question as "do we hold their key". A key
  /// survives for ever once a handshake has completed, so keying presence off it
  /// made every contact look online permanently — and a message sent to someone
  /// who was not there then went nowhere, with nothing on screen saying so. This
  /// reports the last observed outcome instead.
  /// True when the peer answered recently.
  ///
  /// This is the note of the last successful exchange, and it is what the "online" badge reads.
  /// It survives a dropped circuit on purpose: a peer that answered a minute ago and whose
  /// connection has since gone is still a peer worth trying, and forgetting that would send the
  /// next message down the relay path for no reason.
  ///
  /// Use [hasLiveConnection] when the question is whether anything can be written *right now*.
  bool isReachable(String onionAddress) =>
      _peers[onionAddress]?.isReachable ?? false;

  /// True when there is an open connection to [onionAddress].
  ///
  /// Separate from [isReachable] because they answer different questions, and conflating them
  /// broke both. A connection can be open with no successful exchange yet — the handshake is in
  /// flight — and a peer can have answered recently with nothing open.
  bool hasLiveConnection(String onionAddress) => _live[onionAddress]?.isClosed == false;

  /// The display name a peer announced, if any.
  String? displayNameOf(String onionAddress) => _displayNames[onionAddress];

  // ------------------------------------------------------------ outbound

  /// Sends a message, directly if possible and through relays if not.
  ///
  /// Returns the envelope id so the caller can track delivery.
  Future<RelayEnvelope> sendMessage({
    required Message message,
    Attachment? attachment,
  }) async {
    final identity = _requireIdentity();
    final peerKey = _keys[message.peerOnion];
    if (peerKey == null) {
      throw StateError(
        'No exchange key for ${message.peerOnion}. Connect once so the handshake '
        'can establish one before sending.',
      );
    }

    final frame = payload.MessageFrame(message: message, attachment: attachment);
    final sealed = await EnvelopeCipher.seal(
      engine: _engine,
      myExchangePrivateKey: identity.exchangePrivateKey,
      peerExchangePublicKey: peerKey,
      myOnion: identity.onionAddress,
      peerOnion: message.peerOnion,
      frame: frame,
    );

    final envelope = RelayEnvelope(
      id: message.id,
      originOnion: identity.onionAddress,
      destinationOnion: message.peerOnion,
      kind: EnvelopeKind.message,
      ciphertext: sealed,
      createdAt: DateTime.now().toUtc(),
      // Three days is the compromise between "the peer was away for the
      // weekend" and "we are hoarding ciphertext on someone else's disk".
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 3)),
      hopLimit: _policy.maxHops,
    );

    _outbox[envelope.id] = envelope;
    unawaited(_attemptDelivery(envelope));
    return envelope;
  }

  /// Seals [bytes] for [peerOnion] and sends them as one envelope per chunk.
  ///
  /// Called after the message that announces the attachment has been sent, and
  /// awaiting it is what lets the caller wait for the last relay to acknowledge.
  ///
  /// The bytes are sealed with the same shared secret the message envelope uses
  /// (see [FileTransfer]), so there is no second key agreement to keep in step.
  /// A file larger than [FileTransfer.maxBytes] is refused rather than attempted:
  /// the recipient verifies the whole thing in memory, so an unbounded transfer
  /// would be an unbounded allocation driven by the other end.
  Future<int> sendAttachment({
    required String peerOnion,
    required Attachment attachment,
    required List<int> bytes,
  }) async {
    final identity = _requireIdentity();
    final peerKey = _keys[peerOnion];
    if (peerKey == null) {
      throw StateError(
        'No exchange key for $peerOnion, so the attachment cannot be sealed.',
      );
    }
    if (bytes.length > FileTransfer.maxBytes) {
      throw StateError(
        'That file is ${bytes.length} bytes, which is larger than the '
        '${FileTransfer.maxBytes}-byte limit for a transfer.',
      );
    }

    final sharedKey = await EnvelopeCipher.sharedKey(
      engine: _engine,
      myExchangePrivateKey: identity.exchangePrivateKey,
      peerExchangePublicKey: peerKey,
      myOnion: identity.onionAddress,
      peerOnion: peerOnion,
    );
    try {
      final chunks = FileTransfer.sealAll(
        engine: _engine,
        sharedKey: sharedKey,
        attachmentId: attachment.id,
        bytes: bytes,
      );
      for (var index = 0; index < chunks.length; index++) {
        await _sendChunk(
          peerOnion: peerOnion,
          attachment: attachment,
          index: index,
          total: chunks.length,
          sealed: chunks[index],
        );
      }
      return chunks.length;
    } finally {
      _engine.wipe(sharedKey);
    }
  }

  /// One chunk, as its own envelope.
  ///
  /// One envelope per chunk rather than one for the file: a single envelope
  /// carrying a few hundred kilobytes is a frame the connection layer has to hold
  /// whole, and a Tor circuit that drops it loses the entire transfer. Per-chunk
  /// envelopes also let the recipient's storage layer verify each piece as it
  /// lands.
  Future<void> _sendChunk({
    required String peerOnion,
    required Attachment attachment,
    required int index,
    required int total,
    required Uint8List sealed,
  }) async {
    final identity = _requireIdentity();
    final envelope = RelayEnvelope(
      id: 'chunk-${attachment.id}-$index',
      originOnion: identity.onionAddress,
      destinationOnion: peerOnion,
      kind: EnvelopeKind.fileChunk,
      // Already AEAD-sealed by `FileTransfer`, so it is not sealed again: the
      // payload is transport ciphertext, not a frame.
      ciphertext: Uint8List.fromList(utf8.encode(jsonEncode(
        FileTransfer.toWire(
          attachment: attachment,
          index: index,
          total: total,
          sealed: sealed,
        ),
      ))),
      createdAt: DateTime.now().toUtc(),
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 3)),
      hopLimit: _policy.maxHops,
    );
    _outbox[envelope.id] = envelope;
    await _attemptDelivery(envelope);
  }

  /// Sends a receipt for messages that arrived.
  Future<void> sendReceipt({
    required String peerOnion,
    required List<String> messageIds,
    required bool read,
  }) async {
    if (messageIds.isEmpty) return;
    final identity = _requireIdentity();
    final peerKey = _keys[peerOnion];
    if (peerKey == null) return;

    final frame = payload.ReceiptFrame(messageIds: messageIds, read: read, at: DateTime.now().toUtc());
    final sealed = await EnvelopeCipher.seal(
      engine: _engine,
      myExchangePrivateKey: identity.exchangePrivateKey,
      peerExchangePublicKey: peerKey,
      myOnion: identity.onionAddress,
      peerOnion: peerOnion,
      frame: frame,
    );
    final envelope = RelayEnvelope(
      id: '${DateTime.now().microsecondsSinceEpoch}-${messageIds.length}',
      originOnion: identity.onionAddress,
      destinationOnion: peerOnion,
      kind: EnvelopeKind.receipt,
      ciphertext: sealed,
      createdAt: DateTime.now().toUtc(),
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 2)),
      requiresAck: false,
    );
    _outbox[envelope.id] = envelope;
    unawaited(_attemptDelivery(envelope));
  }


  /// Sends a call signal.
  ///

  /// Sends one slice of call audio, best effort.
  ///

  /// One pass of the mesh: retry what is stuck, then collect our own mail.
  Future<void> tick() async {
    if (!isConfigured) return;
    final now = DateTime.now().toUtc();

    // Contacts the account layer knows about but whose exchange key is still missing.
    // Dialling them is retried here, and this is the *only* thing that does.
    //
    // It used to be attempted once, when the contact was added, and that is not enough:
    // a peer who is offline at that moment, or whose onion service has not finished
    // publishing, produced one attempt, one failure, and then silence for ever. The
    // outbox retries below do not help, because there is nothing in the outbox — without
    // an exchange key no envelope can even be sealed. The contact stayed permanently
    // unreachable with a message frozen at "waiting for the first handshake", and nothing
    // in the application would ever try again.
    await debugRetryPendingHandshakes();

    for (final envelope in _outbox.values.toList(growable: false)) {
      if (envelope.isExpired) {
        _outbox.remove(envelope.id);
        _emit(MeshDeliveryChanged(
          envelopeId: envelope.id,
          messageId: envelope.id,
          status: MessageStatus.failed,
          failureReason: 'The message expired before it could be delivered.',
        ));
        continue;
      }
      // Back off with the number of attempts so a dead peer does not cause a
      // connection storm.
      final last = envelope.lastAttemptAt;
      if (last != null && now.difference(last).inSeconds < _backoffSeconds(envelope.attempts)) {
        continue;
      }
      await _attemptDelivery(envelope);
    }

    _pruneMailbox(now);
    await _collectMailbox();
  }

  /// Addresses that need a handshake and do not have one.
  ///
  /// Populated by [expectHandshake], emptied when one succeeds. Kept here rather than
  /// driven from the account layer because this is where the periodic tick already runs,
  /// and a second timer in another layer would be a second thing to keep in step.
  final Set<String> _awaitingHandshake = <String>{};
  final Map<String, int> _handshakeAttempts = <String, int>{};
  final Map<String, DateTime> _handshakeAttemptedAt = <String, DateTime>{};

  /// Records that [onionAddress] has no exchange key, so the pump keeps dialling it.
  void expectHandshake(String onionAddress) {
    if (onionAddress.isEmpty) return;
    if (_keys.containsKey(onionAddress)) return;
    _awaitingHandshake.add(onionAddress);
  }

  /// Addresses the pump is still trying to reach.
  ///
  /// Exposed for the diagnostics report, which has to describe what the pump is doing and
  /// would be lying if it inferred it from anywhere else.
  Set<String> get pendingHandshakes =>
      Set<String>.unmodifiable(_awaitingHandshake);

  /// Addresses an exchange key is held for, which is the same condition the send path
  /// refuses on — `exchangeKeyOf` returning null is exactly "not in here".
  Set<String> get establishedPeers => Set<String>.unmodifiable(_keys.keys);

  /// Dials the peers waiting for a handshake, ignoring the backoff when [force] is set.
  ///
  /// Exposed so a test can drive the retry without waiting out the backoff, which is
  /// measured in minutes because each attempt costs a Tor circuit. The application always
  /// calls it with the backoff in force, from `tick`.
  Future<void> debugRetryPendingHandshakes({bool force = false}) async {
    final now = DateTime.now().toUtc();
    for (final onion in _awaitingHandshake.toList(growable: false)) {
      if (!force) {
        final backoff = _handshakeBackoffSeconds(_handshakeAttempts[onion] ?? 0);
        final last = _handshakeAttemptedAt[onion];
        if (last != null && now.difference(last).inSeconds < backoff) continue;
      }
      _handshakeAttempts[onion] = (_handshakeAttempts[onion] ?? 0) + 1;
      _handshakeAttemptedAt[onion] = now;
      // `warmUp` raises `MeshHandshakeStarted` itself, so every dial is announced whether it
      // came from here or from `addContact`. Announcing in both places would send the event
      // twice for a retry.
      await warmUp(onion);
    }
  }

  /// Stops dialling [onionAddress], because a key has arrived or the contact has gone.
  void forgetHandshake(String onionAddress) {
    _awaitingHandshake.remove(onionAddress);
    _handshakeAttempts.remove(onionAddress);
    _handshakeAttemptedAt.remove(onionAddress);
  }

  /// Slower than the message backoff, because a handshake is a Tor circuit.
  ///
  /// An onion service that is not running will not start running because it was dialled
  /// every ten seconds, and each attempt costs a circuit. Five minutes keeps a contact who
  /// comes online reachable within a reasonable time without paying for a circuit every
  /// tick for ever.
  int _handshakeBackoffSeconds(int attempts) => switch (attempts) {
        0 => 0,
        1 => 20,
        2 => 60,
        3 => 180,
        _ => 300,
      };

  int _backoffSeconds(int attempts) => switch (attempts) {
        0 => 0,
        1 => 10,
        2 => 30,
        3 => 90,
        _ => 240,
      };

  /// Tries the destination first, then hands the envelope to relays.
  Future<void> _attemptDelivery(RelayEnvelope envelope) async {
    final attempted = envelope.copyWith(
      attempts: envelope.attempts + 1,
      lastAttemptAt: DateTime.now().toUtc(),
    );
    _outbox[envelope.id] = attempted;

    PeerConnection? direct;
    try {
      direct = await _connectionTo(envelope.destinationOnion);
      final response = await direct.request('deliver', <String, dynamic>{
        'envelopes': <Map<String, dynamic>>[envelope.toJson()],
      });
      if (response['ok'] == true) {
        _outbox.remove(envelope.id);
        _emit(MeshDeliveryChanged(
          envelopeId: envelope.id,
          messageId: envelope.id,
          status: MessageStatus.delivered,
          viaRelay: false,
        ));
        return;
      }
    } on Object catch (error) {
      // Direct delivery failed; the relay path below is the whole point of the
      // mesh, so a failure here is expected rather than exceptional.
      _noteFailure(envelope.destinationOnion, error);
    }

    await _handOffToRelays(attempted);
  }

  /// Gives the envelope to contacts that are willing to carry it.
  Future<void> _handOffToRelays(RelayEnvelope envelope) async {
    if (envelope.hopLimit <= 0) {
      _emit(MeshDeliveryChanged(
        envelopeId: envelope.id,
        messageId: envelope.id,
        status: MessageStatus.failed,
        failureReason: 'No relay would carry the message any further.',
      ));
      return;
    }

    final candidates = _peers.values
        .where((peer) =>
            peer.onionAddress != envelope.destinationOnion &&
            peer.capabilities.relaysForOthers &&
            peer.isReachable)
        .toList()
      ..sort((a, b) => b.relayScore.compareTo(a.relayScore));

    if (candidates.isEmpty) {
      // Nothing to do yet: the outbox retries, so the message is not lost — it
      // waits for a contact to come online.
      //
      // The wait is *reported*, which it used not to be. Returning silently made
      // an unroutable message look exactly like a delivered one: the bubble kept
      // its clock, the outbox kept retrying, and nothing anywhere said that with
      // no third node willing to relay there is no path at all until the
      // recipient themselves is reachable. That silence is precisely what the
      // user experienced as "sending does not work".
      _emit(MeshDeliveryChanged(
        envelopeId: envelope.id,
        messageId: envelope.id,
        status: MessageStatus.queued,
        failureReason: 'No route yet. The recipient is not reachable and no '
            'other contact is carrying messages, so there is nowhere to leave '
            'this. It is kept and retried, and will go as soon as either the '
            'recipient or a relay is online.',
      ));
      return;
    }

    for (final relay in candidates.take(3)) {
      try {
        final connection = await _connectionTo(relay.onionAddress);
        final forwarded = envelope.copyWith(
          hopLimit: envelope.hopLimit - 1,
          path: <String>[...envelope.path, relay.onionAddress],
        );
        final response = await connection.request('relay', <String, dynamic>{
          'envelopes': <Map<String, dynamic>>[forwarded.toJson()],
        });
        if (response['ok'] == true) {
          _emit(MeshDeliveryChanged(
            envelopeId: envelope.id,
            messageId: envelope.id,
            status: MessageStatus.sent,
            viaRelay: true,
          ));
          // The envelope stays in the outbox: the relay only *holds* it, and a
          // relay can disappear. It is removed when the destination confirms
          // receipt.
          return;
        }
      } on Object {
        // Try the next candidate.
      }
    }
  }

  Future<void> _collectMailbox() async {
    final relays = _peers.values
        .where((peer) => peer.capabilities.mailboxQuotaBytes > 0 || peer.capabilities.relaysForOthers)
        .toList(growable: false);
    for (final relay in relays) {
      try {
        final connection = await _connectionTo(relay.onionAddress);
        final response = await connection.request('pull', <String, dynamic>{'limit': 50});
        final list = response['envelopes'];
        if (list is! List) continue;
        for (final entry in list) {
          final envelope = RelayEnvelope.fromJson(
            Map<String, dynamic>.from(entry as Map<dynamic, dynamic>),
          );
          await _ingest(envelope, viaRelay: true);
        }
      } on Object {
        // A relay that is down is normal; the next tick tries again.
      }
    }
  }

  // ------------------------------------------------------------- inbound

  /// Handles an inbound connection: answers the handshake, then serves requests
  /// until the peer goes away.
  Future<void> handleInbound(PeerStream stream) async {
    final identity = _identity;
    if (identity == null) {
      // The vault locked between the accept and this call, so there is no key to handshake with.
      // Recorded because "the peer dialled and we could not answer" is otherwise invisible: the
      // other device reports a failed handshake and nothing here explains it.
      logMesh('inbound connection refused: no identity yet');
      stream.destroy();
      return;
    }

    logMesh('inbound handshake starting');

    final connection = PeerConnection.accept(
      engine: _engine,
      stream: stream,
      myOnion: identity.onionAddress,
      myIdentityPrivateKey: identity.identityPrivateKey,
      myIdentityPublicKey: identity.identityPublicKey,
      myExchangePrivateKey: identity.exchangePrivateKey,
      myExchangePublicKey: identity.exchangePublicKey,
      myDisplayName: identity.displayName,
      about: identity.about,
      capabilities: <String, dynamic>{
        'relaysForOthers': _policy.enabled,
        'mailboxQuotaBytes': _policy.enabled ? _policy.maxStoredBytes : 0,
        'supportsFiles': true,
        'supportsVoice': true,
        'protocolVersion': 1,
      },
    );

    try {
      await connection.ready;
    } on Object catch (error) {
      // ## This used to be silent, and that is why a whole class of failure went undiagnosed
      //
      // The `catch` swallowed the reason, closed the socket and returned. Nothing was logged and
      // no event was emitted, so a peer whose handshake *reached* this device and failed looked
      // exactly like a peer that never dialled: no contact appeared, no key was stored, and the
      // only symptom was on the other device — which is what "generally there is no connection,
      // and on the PC the contact only appears after a restart" describes.
      //
      // Emitting the failure is the part that matters beyond the log. The account layer records
      // it against the peer and shows it, so the person can see that the other side tried.
      logMesh(
        'inbound handshake failed',
        detail: '$error',
      );
      // The address is unknown on a failed handshake — the failure *is* that the peer never
      // proved who it was — so the event carries what it can. An empty address is filtered by
      // the account layer rather than being stored under the empty key.
      _emit(MeshHandshakeFailed(
        onionAddress: connection.onionAddress,
        reason: 'the other side connected but the handshake did not complete: $error',
      ));
      await connection.close();
      return;
    }

    _adoptPeer(connection);
    connection.incomingRequests.listen((request) => unawaited(_serve(connection, request)));
    logMesh('inbound handshake complete with ${shortenOnion(connection.onionAddress)}');
    // The connection stays open: `incomingRequests` is fed by the socket, and `_adoptPeer` has
    // arranged for `_live` to drop it when it closes.
  }

  void _adoptPeer(PeerConnection connection) {
    _live[connection.onionAddress] = connection;
    // The key arrived, so there is nothing left to dial for.
    forgetHandshake(connection.onionAddress);
    // The connection tells us when it dies, so the map never keeps a corpse. See the
    // cleanup in `_connectionTo` for what happened without this.
    connection.onDisconnected = (PeerConnection dead) {
      if (identical(_live[dead.onionAddress], dead)) {
        _live.remove(dead.onionAddress);
      }
    };
    rememberPeer(
      onionAddress: connection.onionAddress,
      exchangePublicKey: connection.peer?.exchangePublicKey,
      displayName: connection.peer?.displayName,
      capabilities: PeerCapabilities.fromJson(connection.peer?.capabilities ?? const {}),
    );
    _emit(MeshPeerLearned(
      onionAddress: connection.onionAddress,
      identityPublicKey: connection.peer?.identityPublicKey ?? Uint8List(0),
      exchangePublicKey: connection.peer?.exchangePublicKey ?? Uint8List(0),
      displayName: connection.peer?.displayName ?? '',
      capabilities: connection.peer?.capabilities ?? const <String, dynamic>{},
    ));
  }

  Future<void> _serve(PeerConnection connection, Map<String, dynamic> request) async {
    final operation = request['op'];
    switch (operation) {
      case 'deliver':
        await _handleDeliver(connection, request);
      case 'relay':
        await _handleRelay(connection, request);
      case 'pull':
        await _handlePull(connection, request);
      case 'ack':
        await _handleAck(connection, request);
      default:
        connection.respond(request['id'] as int? ?? 1, <String, dynamic>{
          'ok': false,
          'error': 'unknown operation "$operation"',
        });
    }
  }

  Future<void> _handleDeliver(PeerConnection connection, Map<String, dynamic> request) async {
    final list = request['envelopes'];
    final accepted = <String>[];
    if (list is List) {
      for (final entry in list) {
        final envelope = RelayEnvelope.fromJson(
          Map<String, dynamic>.from(entry as Map<dynamic, dynamic>),
        );
        if (await _ingest(envelope, viaRelay: false)) accepted.add(envelope.id);
      }
    }
    connection.respond(
      request['id'] as int? ?? 1,
      <String, dynamic>{'ok': true, 'accepted': accepted},
    );
  }

  /// Holds an envelope on behalf of somebody else.
  Future<void> _handleRelay(PeerConnection connection, Map<String, dynamic> request) async {
    if (!_policy.enabled) {
      connection.respond(request['id'] as int? ?? 1, <String, dynamic>{
        'ok': false,
        'error': 'this device does not relay for others',
      });
      return;
    }
    final list = request['envelopes'];
    final stored = <String>[];
    if (list is List) {
      for (final entry in list) {
        final envelope = RelayEnvelope.fromJson(
          Map<String, dynamic>.from(entry as Map<dynamic, dynamic>),
        );
        if (_acceptIntoMailbox(envelope)) stored.add(envelope.id);
      }
    }
    connection.respond(
      request['id'] as int? ?? 1,
      <String, dynamic>{'ok': true, 'stored': stored},
    );
  }

  /// Hands over everything held for the requesting peer.
  Future<void> _handlePull(PeerConnection connection, Map<String, dynamic> request) async {
    final origin = connection.onionAddress;
    final limit = (request['limit'] as num?)?.toInt() ?? 50;
    final held = _mailbox.values
        .where((envelope) => envelope.destinationOnion == origin && !envelope.isExpired)
        .take(limit)
        .toList(growable: false);
    connection.respond(
      request['id'] as int? ?? 1,
      <String, dynamic>{
        'ok': true,
        'envelopes': held.map((envelope) => envelope.toJson()).toList(growable: false),
      },
    );
  }

  Future<void> _handleAck(PeerConnection connection, Map<String, dynamic> request) async {
    final ids = request['ids'];
    if (ids is List) {
      for (final id in ids) {
        if (id is String) _outbox.remove(id);
      }
    }
    connection.respond(request['id'] as int? ?? 1, <String, dynamic>{'ok': true});
  }

  /// Decrypts an envelope addressed to us and turns it into an event.
  Future<bool> _ingest(RelayEnvelope envelope, {required bool viaRelay}) async {
    final identity = _identity;
    if (identity == null) return false;
    if (!envelope.isFor(identity.onionAddress)) return false;

    final senderKey = _keys[envelope.originOnion];
    if (senderKey == null) {
      // We have never completed a handshake with the sender, so we cannot open
      // the envelope. Holding it would be pointless — the key may arrive later,
      // but the sender will retry anyway.
      return false;
    }

    // Attachment chunks are not frames.
    //
    // Their payload is already AEAD-sealed by `FileTransfer` under a per-chunk
    // nonce, so it is read directly instead of being opened as an envelope: the
    // two have different AAD and a different key schedule, and running the
    // envelope open over a chunk would only ever fail and drop the bytes.
    if (envelope.kind == EnvelopeKind.fileChunk) {
      try {
        final json = jsonDecode(utf8.decode(envelope.ciphertext));
        if (json is! Map<String, dynamic>) return false;
        final chunk = FileTransfer.fromWire(json);
        if (chunk == null) return false;
        final sharedKey = await EnvelopeCipher.sharedKey(
          engine: _engine,
          myExchangePrivateKey: identity.exchangePrivateKey,
          peerExchangePublicKey: senderKey,
          myOnion: identity.onionAddress,
          peerOnion: envelope.originOnion,
        );
        try {
          // Verified here rather than by the caller, so a forged or reordered
          // chunk never reaches storage at all.
          final plain = FileTransfer.openChunk(
            engine: _engine,
            sharedKey: sharedKey,
            attachmentId: chunk.attachmentId,
            index: chunk.index,
            total: chunk.total,
            sealed: chunk.plaintext,
          );
          _emit(MeshAttachmentChunk(
            fromOnion: envelope.originOnion,
            payload: ChunkPayload(
              attachmentId: chunk.attachmentId,
              messageId: chunk.messageId,
              fileName: chunk.fileName,
              mimeType: chunk.mimeType,
              sizeBytes: chunk.sizeBytes,
              sha256Hex: chunk.sha256Hex,
              index: chunk.index,
              total: chunk.total,
              // The decrypted bytes. The account layer verifies them against the
              // digest before storing anything.
              plaintext: plain,
            ),
          ));
          if (envelope.requiresAck) unawaited(_acknowledge(envelope));
          return true;
        } finally {
          _engine.wipe(sharedKey);
        }
      } on Object {
        // A chunk that does not authenticate is dropped. The sender retries the
        // whole transfer, and the recipient has nothing usable to keep.
        return false;
      }
    }

    try {
      final frame = await EnvelopeCipher.open(
        engine: _engine,
        myExchangePrivateKey: identity.exchangePrivateKey,
        fromExchangePublicKey: senderKey,
        myOnion: identity.onionAddress,
        fromOnion: envelope.originOnion,
        sealed: envelope.ciphertext,
      );

      switch (frame) {
        case payload.MessageFrame(:final message, :final attachment):
          _emit(MeshMessageReceived(
            message: message.copyWith(
              viaRelay: viaRelay,
              relayOnion: viaRelay && envelope.path.isNotEmpty ? envelope.path.last : null,
            ),
            attachment: attachment,
            viaRelay: viaRelay,
            peerOnion: envelope.originOnion,
          ));
        case payload.ReceiptFrame(:final messageIds, :final read, :final at):
          _emit(MeshReceiptReceived(messageIds: messageIds, read: read, at: at));
          for (final id in messageIds) {
            _outbox.remove(id);
          }
        case _:
          // Handshakes, presence beacons and mailbox requests are handled on
          // the connection itself, not inside an envelope.
          break;
      }

      // Tell the sender we have it, so it can stop retrying.
      if (envelope.requiresAck) {
        unawaited(_acknowledge(envelope));
      }
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _acknowledge(RelayEnvelope envelope) async {
    try {
      final connection = _live[envelope.originOnion] ?? await _connectionTo(envelope.originOnion);
      await connection.request('ack', <String, dynamic>{
        'ids': <String>[envelope.id],
      });
    } on Object {
      // The sender will discover the delivery through its own retry loop.
    }
  }

  bool _acceptIntoMailbox(RelayEnvelope envelope) {
    if (_mailbox.length >= _policy.maxEnvelopes) return false;
    if (mailboxBytes + envelope.sizeBytes > _policy.maxStoredBytes) return false;
    if (_policy.onlyForContacts && !_peers.containsKey(envelope.destinationOnion)) {
      // Refusing unknown destinations is what stops this device from becoming a
      // public mailbox for the whole network.
      return false;
    }
    if (envelope.isExpired) return false;
    _mailbox[envelope.id] = envelope;
    return true;
  }

  void _pruneMailbox(DateTime now) {
    final cutoff = now.subtract(_policy.retention);
    _mailbox.removeWhere(
      (_, envelope) => envelope.isExpired || envelope.createdAt.isBefore(cutoff),
    );
  }

  // ---------------------------------------------------------- connections

  /// Returns a live connection to [onionAddress], reusing one when possible.
  Future<PeerConnection> _connectionTo(String onionAddress) async {
    final existing = _live[onionAddress];
    if (existing != null && !existing.isClosed) return existing;
    // A dead connection is dropped rather than returned. Handing one back is what made
    // a contact unreachable for ever: every send failed against a connection that was
    // already gone, the failure looked like "the peer is offline", and the handshake
    // that would have built a replacement was never attempted.
    if (existing != null) _live.remove(onionAddress);

    // One dial at a time per peer, and everyone who asks during a dial waits for that same dial.
    //
    // ## What this fixes, from a real report
    //
    // A Tor circuit to an unreachable onion service takes the full ninety-second timeout. Nothing
    // stopped a second dial from starting while the first was still open, and in the log that was
    // twenty-four simultaneous circuits to one address over two and a half minutes — the send
    // path, the retry pump and the handshake retry all dialling the same peer, each new attempt
    // queued behind the last, each one costing a circuit.
    //
    // Two things follow from that pile-up. Each new circuit competes with the ones already open,
    // so the peer takes longer to reach and the user sees "adding a contact takes forever" — which
    // is what was reported. And the pile is unbounded, so a peer that stays offline is a growing
    // load on the local Tor daemon.
    //
    // Sharing one future collapses them: concurrent callers get the same answer, a failure is
    // reported once, and the next attempt begins after the previous one has finished rather than
    // beside it.
    final inFlight = _dialling[onionAddress];
    if (inFlight != null) return inFlight;

    final attempt = _openConnection(onionAddress);
    _dialling[onionAddress] = attempt;
    try {
      return await attempt;
    } finally {
      // Removed once settled, so a later call starts a fresh attempt rather than reusing a
      // finished future — which would hand back a failure for ever.
      _dialling.remove(onionAddress);
    }
  }

  /// Dial attempts in flight, keyed by peer, so concurrent callers share one.
  final Map<String, Future<PeerConnection>> _dialling =
      <String, Future<PeerConnection>>{};

  Future<PeerConnection> _openConnection(String onionAddress) async {
    final identity = _requireIdentity();

    // The three facts that make a failed handshake diagnosable: who, through which port, and
    // whether the mesh believes it has a key. Without the port, a dial that fails because the
    // mesh is pointed at a stale SOCKS port is indistinguishable from a peer that is offline —
    // and that confusion is exactly what a report of "usually there is no connection" produces.
    logMesh(
      'dialling ${shortenOnion(onionAddress)}',
      detail: 'via socks $_socksHost:$_socksPort · remote port $_remotePort · '
          'as ${shortenOnion(identity.onionAddress)} · '
          'key held: ${_keys.containsKey(onionAddress)}',
    );

    final connection = await PeerConnection.connect(
      engine: _engine,
      peerOnion: onionAddress,
      myOnion: identity.onionAddress,
      myIdentityPrivateKey: identity.identityPrivateKey,
      myIdentityPublicKey: identity.identityPublicKey,
      myExchangePrivateKey: identity.exchangePrivateKey,
      myExchangePublicKey: identity.exchangePublicKey,
      myDisplayName: identity.displayName,
      about: identity.about,
      socksHost: _socksHost,
      socksPort: _socksPort,
      remotePort: _remotePort,
      capabilities: <String, dynamic>{
        'relaysForOthers': _policy.enabled,
        'mailboxQuotaBytes': _policy.enabled ? _policy.maxStoredBytes : 0,
        'protocolVersion': 1,
      },
    );

    await connection.ready;
    _adoptPeer(connection);
    connection.incomingRequests.listen((request) => unawaited(_serve(connection, request)));
    _noteSuccess(onionAddress);
    logMesh('handshake complete with ${shortenOnion(onionAddress)}');
    return connection;
  }

  /// Opens a connection and keeps it, so the next send does not pay for a new
  /// onion circuit.
  ///
  /// Never throws: warming up is opportunistic and a peer being offline is the normal
  /// case in a mesh. It does *report*, though — the failure is recorded against the peer
  /// and emitted, because the alternative is a message that sits at "waiting for the
  /// first handshake" with nothing anywhere to say the handshake was attempted and
  /// failed.
  ///
  /// Nothing is reported when the mesh is not configured yet, and that distinction is
  /// the whole point of the check. Adding a contact before Tor has finished connecting is
  /// ordinary: the mesh exists but has no SOCKS port, so dialling is impossible for a
  /// reason that has nothing to do with the peer. Reporting it stored "the mesh has not
  /// been configured with an identity" as that contact's last failure, and nothing ever
  /// cleared it — so after Tor came up, and after a successful handshake, the send path
  /// still explained itself with a stale error from before the network existed.
  ///
  /// ## Every dial announces itself, and this is where
  ///
  /// `MeshHandshakeStarted` is emitted here rather than in the pump, and that placement is
  /// the whole fix for "after adding a contact nothing happens". `addContact` calls this
  /// method **directly** — the pump only retries the dials that failed — so an event raised
  /// in the pump was never raised for the very first attempt. The user therefore saw nothing
  /// at all: no failure, because the dial had not finished, and no sign that one was running,
  /// because only the pump announced those. A Tor circuit to a peer that is not answering
  /// takes up to ninety seconds, which is long enough to conclude the application is broken.
  Future<void> warmUp(String onionAddress) async {
    if (!isConfigured) return;
    _emit(MeshHandshakeStarted(onionAddress: onionAddress));
    try {
      await _connectionTo(onionAddress);
    } on Object catch (error) {
      _noteFailure(onionAddress, error);
      _emit(MeshHandshakeFailed(onionAddress: onionAddress, reason: '$error'));
    }
  }

  void _noteSuccess(String onionAddress) {
    final existing = _peers[onionAddress];
    _peers[onionAddress] = (existing ??
            PeerRecord(onionAddress: onionAddress, firstSeenAt: DateTime.now().toUtc()))
        .copyWith(
      lastSeenAt: DateTime.now().toUtc(),
      successCount: (existing?.successCount ?? 0) + 1,
      isReachable: true,
    );
  }

  void _noteFailure(String onionAddress, Object error) {
    final existing = _peers[onionAddress];
    _peers[onionAddress] = (existing ??
            PeerRecord(onionAddress: onionAddress, firstSeenAt: DateTime.now().toUtc()))
        .copyWith(
      lastAttemptAt: DateTime.now().toUtc(),
      failureCount: (existing?.failureCount ?? 0) + 1,
      isReachable: false,
    );
    // The reason is recorded in the peer record's failure count rather than
    // emitted as an event: a peer being offline is the normal case in a mesh,
    // and surfacing every miss would drown the UI in noise.
    _lastFailure = error;
  }

  Object? _lastFailure;

  /// The most recent delivery failure, for the diagnostics panel.
  Object? get lastFailure => _lastFailure;

  MeshIdentity _requireIdentity() {
    final identity = _identity;
    if (identity == null) {
      throw StateError('The mesh has not been configured with an identity.');
    }
    return identity;
  }

  void _emit(MeshEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// Directory the mesh may use for scratch state.
  Directory get storageDirectory => _storageDirectory;
}