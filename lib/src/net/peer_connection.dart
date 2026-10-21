import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../crypto/crypto_engine.dart';
import '../crypto/onion_address.dart';
import 'framing.dart';
import 'peer_stream.dart';
import 'protocol/session.dart';
import 'socks5.dart';

/// Thrown when a peer breaks the protocol or refuses an operation.
class PeerProtocolException implements Exception {
  const PeerProtocolException(this.message, {this.remote});

  final String message;
  final String? remote;

  @override
  String toString() => remote == null ? message : '$message (from $remote)';
}

/// What is known about the peer once the handshake has completed.
class PeerIdentity {
  const PeerIdentity({
    required this.onionAddress,
    required this.identityPublicKey,
    required this.exchangePublicKey,
    required this.displayName,
    required this.about,
    required this.capabilities,
  });

  final String onionAddress;
  final Uint8List identityPublicKey;
  final Uint8List exchangePublicKey;
  final String displayName;
  final String about;
  final Map<String, dynamic> capabilities;
}

/// A live, authenticated session with one peer.
///
/// The handshake runs **inside** this object rather than before it, because a
/// `dart:io` `Socket` — and therefore the [PeerStream] wrapping it — allows
/// exactly one subscription for its lifetime. Reading the handshake separately
/// and then "handing the socket over" is impossible; the connection therefore
/// starts in a handshaking state and promotes itself to established once the
/// keys exist, which is also why frames that arrive in the same TCP chunk as
/// the handshake reply are buffered rather than lost.
///
/// Every connection performs a fresh handshake, so a compromised session key
/// exposes only the frames sent on that connection. Requests and responses are
/// multiplexed by id, so a file chunk and a chat message share one onion
/// circuit — circuit setup costs seconds on Tor, which makes this worth the
/// bookkeeping.
class PeerConnection {
  PeerConnection._({
    required this._stream,
    required this._engine,
    required this._myOnion,
    required this._myIdentityPrivateKey,
    required this._myIdentityPublicKey,
    required this._myExchangePrivateKey,
    required this._myExchangePublicKey,
    required this._myDisplayName,
    required this._myAbout,
    required this._myCapabilities,
  }) {
    _subscription = _stream.incoming.listen(
      _onData,
      onError: _fail,
      onDone: () => _fail(const PeerProtocolException('the peer closed the connection')),
      cancelOnError: false,
    );
  }

  final PeerStream _stream;
  final CryptoEngine _engine;
  final String _myOnion;
  final Uint8List _myIdentityPrivateKey;
  final Uint8List _myIdentityPublicKey;
  final Uint8List _myExchangePrivateKey;
  final Uint8List _myExchangePublicKey;
  final String _myDisplayName;
  final String _myAbout;
  final Map<String, dynamic> _myCapabilities;

  late final StreamSubscription<Uint8List> _subscription;
  final FrameDecoder _decoder = FrameDecoder();
  final List<Frame> _buffered = <Frame>[];
  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};
  final StreamController<Map<String, dynamic>> _incomingRequests =
      StreamController<Map<String, dynamic>>.broadcast();
  final Completer<void> _handshake = Completer<void>();

  SessionCipher? _cipher;
  PeerIdentity? _peer;

  /// The private half of this connection's ephemeral key. The public half is
  /// sent inside the handshake offer and never needed again, so only the
  /// private half is kept.
  Uint8List? _myEphemeralPrivateKey;
  int _nextRequestId = 1;
  bool _closed = false;
  Object? _failure;
  String _remoteOnion = '';

  /// True once the first frame has been handed to the (asynchronous) handshake.
  ///
  /// It is what lets the reader tell "nothing has happened yet, this is the
  /// handshake" from "the handshake is still running, this frame belongs to the
  /// session that is being built". See [_onData].
  bool _handshakeStarted = false;

  /// Requests arriving from the peer, already decrypted.
  Stream<Map<String, dynamic>> get incomingRequests => _incomingRequests.stream;

  /// Resolves once the session keys exist, or throws if the handshake failed.
  Future<void> get ready => _handshake.future;

  /// True once the session is usable.
  bool get isEstablished => _cipher != null;

  bool get isClosed => _closed;

  /// The peer, available after [ready].
  PeerIdentity? get peer => _peer;

  String get onionAddress => _peer?.onionAddress ?? _remoteOnion;

  /// The last failure, for diagnostics.
  Object? get failure => _failure;

  /// Opens a connection to `peerOnion:port` through Tor and runs the handshake
  /// as the initiator.
  static Future<PeerConnection> connect({
    required CryptoEngine engine,
    required String peerOnion,
    required String myOnion,
    required Uint8List myIdentityPrivateKey,
    required Uint8List myIdentityPublicKey,
    required Uint8List myExchangePrivateKey,
    required Uint8List myExchangePublicKey,
    required String myDisplayName,
    required String socksHost,
    required int socksPort,
    required int remotePort,
    String about = '',
    Map<String, dynamic> capabilities = const <String, dynamic>{},
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final stream = await Socks5Client.connect(
      targetHost: peerOnion,
      targetPort: remotePort,
      proxyHost: socksHost,
      proxyPort: socksPort,
      timeout: timeout,
    );

    final connection = PeerConnection._(
      stream: stream,
      engine: engine,
      myOnion: myOnion,
      myIdentityPrivateKey: myIdentityPrivateKey,
      myIdentityPublicKey: myIdentityPublicKey,
      myExchangePrivateKey: myExchangePrivateKey,
      myExchangePublicKey: myExchangePublicKey,
      myDisplayName: myDisplayName,
      myAbout: about,
      myCapabilities: capabilities,
    );
    connection._remoteOnion = peerOnion;

    try {
      final ephemeral = await engine.generateX25519();
      connection._myEphemeralPrivateKey = ephemeral.privateKey;

      final offer = await HandshakeOffer.create(
        engine: engine,
        onionAddress: myOnion,
        identityPrivateKey: myIdentityPrivateKey,
        identityPublicKey: myIdentityPublicKey,
        exchangePublicKey: myExchangePublicKey,
        displayName: myDisplayName,
        about: about,
        capabilities: capabilities,
      );
      // The ephemeral inside the offer must be the one whose private half we
      // kept, so it is rebuilt here rather than generated inside `create`.
      final boundOffer = HandshakeOffer(
        onionAddress: offer.onionAddress,
        identityPublicKey: offer.identityPublicKey,
        exchangePublicKey: offer.exchangePublicKey,
        ephemeralPublicKey: ephemeral.publicKey,
        signature: await engine.ed25519Sign(
          privateKey: myIdentityPrivateKey,
          message: HandshakeOffer.signedBytes(myExchangePublicKey, ephemeral.publicKey),
        ),
        displayName: offer.displayName,
        about: offer.about,
        capabilities: offer.capabilities,
      );

      connection._rawSend(
        Frame(
          kind: FrameKind.request,
          requestId: 1,
          payload: utf8.encode(jsonEncode(<String, dynamic>{
            'op': 'hello',
            'offer': boundOffer.toJson(),
          })),
        ),
      );
      await stream.flush();

      await connection.ready.timeout(timeout);
      return connection;
    } on Object {
      connection._fail(const PeerProtocolException('the handshake did not complete'));
      rethrow;
    }
  }

  /// Accepts an inbound connection and runs the handshake as the responder.
  static PeerConnection accept({
    required CryptoEngine engine,
    required PeerStream stream,
    required String myOnion,
    required Uint8List myIdentityPrivateKey,
    required Uint8List myIdentityPublicKey,
    required Uint8List myExchangePrivateKey,
    required Uint8List myExchangePublicKey,
    required String myDisplayName,
    String about = '',
    Map<String, dynamic> capabilities = const <String, dynamic>{},
  }) {
    return PeerConnection._(
      stream: stream,
      engine: engine,
      myOnion: myOnion,
      myIdentityPrivateKey: myIdentityPrivateKey,
      myIdentityPublicKey: myIdentityPublicKey,
      myExchangePrivateKey: myExchangePrivateKey,
      myExchangePublicKey: myExchangePublicKey,
      myDisplayName: myDisplayName,
      myAbout: about,
      myCapabilities: capabilities,
    );
  }

  /// Sends a request and waits for the matching response.
  Future<Map<String, dynamic>> request(
    String operation, [
    Map<String, dynamic> body = const <String, dynamic>{},
  ]) async {
    await ready;
    if (_closed) {
      throw PeerProtocolException('the connection to $onionAddress is closed');
    }
    final id = _nextRequestId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _send(
      Frame(
        kind: FrameKind.request,
        requestId: id,
        payload: utf8.encode(jsonEncode(<String, dynamic>{'op': operation, ...body})),
      ),
    );
    try {
      return await completer.future.timeout(const Duration(seconds: 120));
    } finally {
      _pending.remove(id);
    }
  }

  /// Answers a request that arrived from the peer.
  void respond(int requestId, Map<String, dynamic> body) {
    if (!isEstablished) return;
    _send(
      Frame(
        kind: FrameKind.response,
        requestId: requestId,
        payload: utf8.encode(jsonEncode(body)),
      ),
    );
  }

  /// Sends a keep-alive so an idle onion circuit is not reaped.
  void keepAlive() {
    if (!isEstablished) return;
    _send(Frame(kind: FrameKind.keepAlive, requestId: 0, payload: Uint8List(0)));
  }

  Future<void> close() async {
    if (_closed) return;
    // The goodbye has to go out *before* the flag is set.
    //
    // `_send` starts with `if (_closed || cipher == null) return;`, so flipping
    // `_closed` first — which is what this did — silently discarded the frame and
    // left the peer with nothing but a socket that stopped answering. Every
    // deliberate disconnect, including `MeshService.stop()`, was therefore
    // recorded on the other side as "the peer closed the connection", which is the
    // wording used for a network drop, and the clean-close path could never be
    // built on.
    try {
      if (isEstablished) {
        _send(Frame(kind: FrameKind.goodbye, requestId: 0, payload: Uint8List(0)));
        await _stream.flush();
      }
    } on Object {
      // The peer may already be gone; not worth reporting.
    }
    _closed = true;
    _markDisconnected();
    _cipher?.destroy();
    await _subscription.cancel();
    await _stream.close();
    if (!_incomingRequests.isClosed) await _incomingRequests.close();
    _failPending(const PeerProtocolException('the connection was closed locally'));
    if (!_handshake.isCompleted) {
      _handshake.completeError(const PeerProtocolException('the connection was closed'));
    }
  }

  /// A short line for the connection log.
  String describe() =>
      'session with ${OnionAddress.shorten(onionAddress)} '
      '(${_peer?.displayName.isEmpty ?? true ? 'unnamed' : _peer!.displayName})';

  /// Called once when this connection has failed or been closed.
  ///
  /// The mesh keeps a map of live connections and hands one back on every send. Without
  /// this signal nothing ever removed a dead entry from that map: the next send found a
  /// connection that was already gone and failed against it, and — because the failure
  /// looked like "the peer is unreachable" — the handshake that would have replaced it
  /// was never attempted. That is the shape of "messages stop going out and the contact
  /// shows as unreachable for ever".
  void Function(PeerConnection connection)? onDisconnected;

  /// Marks the connection dead and tells the owner, exactly once.
  void _markDisconnected() {
    if (_disconnectedReported) return;
    _disconnectedReported = true;
    try {
      onDisconnected?.call(this);
    } on Object {
      // A listener that throws must not stop the cleanup that follows.
    }
  }

  bool _disconnectedReported = false;

  // ------------------------------------------------------------- internals

  void _onData(Uint8List data) {
    final List<Frame> frames;
    try {
      frames = _decoder.add(data);
    } on FramingException catch (error) {
      _fail(error);
      return;
    }
    for (final frame in frames) {
      if (_cipher != null) {
        _handleEstablishedFrame(frame);
      } else if (_handshakeStarted) {
        // The asynchronous handshake owns the first frame it was given.
        //
        // Handshaking involves several awaits, so it is not finished by the time
        // the next frame in the same chunk is looked at. The loop used to test
        // `isEstablished` — still false — and hand every extra frame to the
        // handshake handler, which decoded it as a hello and, for a ciphertext
        // frame, threw and tore down a connection that had just authenticated.
        // Two frames in one TCP segment is normal: a peer that batches its first
        // request with its offer, a Tor edge that coalesces, or simply a slow
        // pure-Dart Diffie-Hellman. Buffering hands them to `_buffered`, which is
        // drained once the handshake completes — the mechanism that was written
        // for exactly this and could never run.
        _buffered.add(frame);
      } else {
        _handshakeStarted = true;
        _handleHandshakeFrame(frame);
      }
    }
  }

  void _handleHandshakeFrame(Frame frame) {
    if (frame.kind == FrameKind.response && _myEphemeralPrivateKey != null) {
      // Initiator: the peer's offer.
      unawaited(_completeAsInitiator(frame));
      return;
    }
    if (frame.kind == FrameKind.request) {
      // Responder: the peer's hello.
      unawaited(_completeAsResponder(frame));
      return;
    }
    // Anything else before the handshake is a protocol violation.
    _fail(const PeerProtocolException('the peer sent data before the handshake'));
  }

  Future<void> _completeAsInitiator(Frame frame) async {
    try {
      final body = jsonDecode(utf8.decode(frame.payload));
      if (body is! Map<String, dynamic> || body['ok'] != true) {
        throw PeerProtocolException(
          'the peer rejected the handshake: ${body is Map ? body['error'] : body}',
          remote: _remoteOnion,
        );
      }
      final offer = HandshakeOffer.fromJson(
        Map<String, dynamic>.from(body['offer'] as Map<dynamic, dynamic>),
      );
      await _establish(offer, isInitiator: true);
    } on Object catch (error) {
      _fail(error);
    }
  }

  Future<void> _completeAsResponder(Frame helloFrame) async {
    try {
      final body = jsonDecode(utf8.decode(helloFrame.payload));
      if (body is! Map<String, dynamic> || body['op'] != 'hello') {
        throw const PeerProtocolException('the first frame must be a hello request');
      }
      final offer = HandshakeOffer.fromJson(
        Map<String, dynamic>.from(body['offer'] as Map<dynamic, dynamic>),
      );
      _remoteOnion = offer.onionAddress;

      final ephemeral = await _engine.generateX25519();
      _myEphemeralPrivateKey = ephemeral.privateKey;

      final reply = await HandshakeOffer.create(
        engine: _engine,
        onionAddress: _myOnion,
        identityPrivateKey: _myIdentityPrivateKey,
        identityPublicKey: _myIdentityPublicKey,
        exchangePublicKey: _myExchangePublicKey,
        displayName: _myDisplayName,
        about: _myAbout,
        capabilities: _myCapabilities,
      );
      final boundReply = HandshakeOffer(
        onionAddress: reply.onionAddress,
        identityPublicKey: reply.identityPublicKey,
        exchangePublicKey: reply.exchangePublicKey,
        ephemeralPublicKey: ephemeral.publicKey,
        signature: await _engine.ed25519Sign(
          privateKey: _myIdentityPrivateKey,
          message: HandshakeOffer.signedBytes(_myExchangePublicKey, ephemeral.publicKey),
        ),
        displayName: reply.displayName,
        about: reply.about,
        capabilities: reply.capabilities,
      );

      _rawSend(
        Frame(
          kind: FrameKind.response,
          requestId: helloFrame.requestId,
          payload: utf8.encode(jsonEncode(<String, dynamic>{
            'ok': true,
            'offer': boundReply.toJson(),
          })),
        ),
      );
      await _stream.flush();
      await _establish(offer, isInitiator: false);
    } on Object catch (error) {
      _fail(error);
    }
  }

  /// Verifies the peer's offer and derives the session keys.
  Future<void> _establish(HandshakeOffer offer, {required bool isInitiator}) async {
    if (!await offer.verify(_engine)) {
      throw PeerProtocolException(
        'the handshake signature does not prove ownership of ${offer.onionAddress}',
        remote: offer.onionAddress,
      );
    }
    if (isInitiator && offer.onionAddress != _remoteOnion) {
      throw PeerProtocolException(
        'the peer claims to be ${offer.onionAddress} but was reached at $_remoteOnion',
        remote: offer.onionAddress,
      );
    }

    final root = await SessionHandshake.deriveRoot(
      engine: _engine,
      isInitiator: isInitiator,
      myExchangePrivateKey: _myExchangePrivateKey,
      myEphemeralPrivateKey: _myEphemeralPrivateKey!,
      peer: offer,
      myOnionAddress: _myOnion,
    );

    _cipher = SessionCipher(engine: _engine, rootKey: root, isInitiator: isInitiator);
    _engine.wipe(root);
    _peer = PeerIdentity(
      onionAddress: offer.onionAddress,
      identityPublicKey: offer.identityPublicKey,
      exchangePublicKey: offer.exchangePublicKey,
      displayName: offer.displayName,
      about: offer.about,
      capabilities: offer.capabilities,
    );

    if (!_handshake.isCompleted) _handshake.complete();

    // Frames that arrived in the same chunk as the handshake reply are already
    // encrypted with the new session, so they are processed now.
    final pendingFrames = List<Frame>.from(_buffered);
    _buffered.clear();
    for (final frame in pendingFrames) {
      _handleEstablishedFrame(frame);
    }
  }

  void _handleEstablishedFrame(Frame frame) {
    switch (frame.kind) {
      case FrameKind.request:
        final body = _open(frame);
        if (body != null && !_incomingRequests.isClosed) {
          // The request id belongs to the *frame*, and the handler has to see it:
          // `respond` needs it to answer with a matching id. It used to be dropped
          // here, so every handler fell back to the `?? 1` default and every
          // reply after the first on a connection went out numbered 1.
          //
          // That is not cosmetic. The first request on a fresh connection really
          // is id 1, so the bug hid itself; from the second request on, the peer's
          // reply either matched nothing (the awaiting `request()` then stalled
          // for its full 120 s timeout, which made direct delivery look like a
          // network failure and pushed everything down the relay path) or, when
          // two requests were in flight — which they are, since the mesh pump,
          // `sendMessage` and `_acknowledge` all share one connection — completed
          // the *wrong* caller's future. A `pull` answered with a `deliver` reply
          // has no `envelopes` list, so mailbox collection silently did nothing.
          //
          // `frame.requestId` wins over anything the body happens to contain, so a
          // hostile peer cannot choose the id it is answered with.
          _incomingRequests.add(<String, dynamic>{...body, 'id': frame.requestId});
        }
      case FrameKind.response:
        final completer = _pending[frame.requestId];
        if (completer == null) return;
        final body = _open(frame);
        if (body == null) return;
        if (!completer.isCompleted) completer.complete(body);
      case FrameKind.keepAlive:
        break;
      case FrameKind.goodbye:
        _fail(const PeerProtocolException('the peer said goodbye'));
    }
  }

  Map<String, dynamic>? _open(Frame frame) {
    final cipher = _cipher;
    if (cipher == null) {
      _buffered.add(frame);
      return null;
    }
    try {
      final clear = cipher.decrypt(frame.payload);
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is Map<String, dynamic>) return decoded;
      _fail(const PeerProtocolException('a frame body was not a JSON object'));
      return null;
    } on Object catch (error) {
      _fail(error);
      return null;
    }
  }

  void _send(Frame frame) {
    final cipher = _cipher;
    if (_closed || cipher == null) return;
    final sealed = cipher.encrypt(frame.payload);
    _stream.add(Frame(kind: frame.kind, requestId: frame.requestId, payload: sealed).encode());
  }

  /// Sends a frame with no encryption, used only during the handshake.
  void _rawSend(Frame frame) {
    if (_closed) return;
    _stream.add(frame.encode());
  }

  void _fail(Object error) {
    if (_closed) return;
    _failure = error;
    _closed = true;
    _markDisconnected();
    _failPending(error);
    _cipher?.destroy();
    _stream.destroy();
    if (!_incomingRequests.isClosed) _incomingRequests.close();
    if (!_handshake.isCompleted) _handshake.completeError(error);
  }

  void _failPending(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }
}
