import 'dart:convert';
import 'dart:typed_data';

import '../../data/models/message.dart';

/// The plaintext that lives inside an encrypted envelope.
///
/// Relays only ever see [EnvelopeKind]; the frames below are what the two
/// endpoints understand once the payload has been opened. Keeping them in one
/// sealed hierarchy makes the decoder exhaustive — a new frame type cannot be
/// added without handling it at the receiver.
sealed class Frame {
  const Frame();

  /// The discriminator written to the wire.
  String get type;

  Map<String, dynamic> payload();

  Map<String, dynamic> toJson() => <String, dynamic>{'v': 1, 't': type, 'p': payload()};

  String encode() => jsonEncode(toJson());

  /// Parses a decrypted payload. Throws [FormatException] on anything unknown,
  /// which the caller turns into a protocol error rather than a crash.
  ///
  /// [peerOnion] is the address of whoever sealed the envelope these bytes came
  /// out of. Only `msg` needs it, and only because the wire format deliberately
  /// omits the sender; see [MessageFrame.fromPayload].
  static Frame decode(List<int> bytes, {String peerOnion = ''}) {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, dynamic>) {
      throw const FormatException('a frame must be a JSON object');
    }
    final type = json['t'] as String?;
    final payload = Map<String, dynamic>.from(
      json['p'] as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{},
    );
    return switch (type) {
      'msg' => MessageFrame.fromPayload(payload, peerOnion: peerOnion),
      'rcpt' => ReceiptFrame.fromPayload(payload),
      'hs' => HandshakeFrame.fromPayload(payload),
      'chunk' => ChunkFrame.fromPayload(payload),
      'pres' => PresenceFrame.fromPayload(payload),
      'pull' => MailboxRequestFrame.fromPayload(payload),
      'ack' => EnvelopeAckFrame.fromPayload(payload),
      _ => throw FormatException('unknown frame type "$type"'),
    };
  }
}

/// A chat message, text or attachment metadata.
class MessageFrame extends Frame {
  const MessageFrame({required this.message, this.attachment});

  final Message message;

  /// Present for file, image and voice messages.
  final Attachment? attachment;

  @override
  String get type => 'msg';

  @override
  Map<String, dynamic> payload() => <String, dynamic>{
        'message': message.toWireJson(),
        if (attachment != null) 'attachment': attachment!.toWireJson(),
      };

  /// Rebuilds the frame, attributing it to [peerOnion].
  ///
  /// The payload itself carries no recipient: the sender does not need to say who
  /// it is writing to, because the envelope is already addressed and sealed to
  /// that peer's key. The *receiver* is the one who has to work out who wrote the
  /// message, and the only thing that knows is the envelope it arrived in — so
  /// the address has to be handed in here. Hard-coding `peerOnion: ''` is what
  /// made a received text message unfileable: `AppController._storeIncoming` had
  /// no conversation to put it in and dropped it, so a message the peer had
  /// certainly sent simply never appeared. Files survived by accident, because
  /// their attachment carried a key id that was used as a stand-in — text had
  /// nothing to fall back on.
  factory MessageFrame.fromPayload(
    Map<String, dynamic> payload, {
    String peerOnion = '',
    String conversationId = '',
  }) =>
      MessageFrame(
        message: Message.fromWireJson(
          Map<String, dynamic>.from(payload['message'] as Map<dynamic, dynamic>? ?? const {}),
          conversationId: conversationId,
          peerOnion: peerOnion,
          direction: MessageDirection.incoming,
        ),
        attachment: payload['attachment'] == null
            ? null
            : Attachment.fromJson(
                Map<String, dynamic>.from(payload['attachment'] as Map<dynamic, dynamic>),
              ),
      );
}

/// A delivery or read receipt.
class ReceiptFrame extends Frame {
  const ReceiptFrame({
    required this.messageIds,
    required this.read,
    required this.at,
  });

  final List<String> messageIds;

  /// False for "delivered to the device", true for "the user opened it".
  final bool read;

  final DateTime at;

  @override
  String get type => 'rcpt';

  @override
  Map<String, dynamic> payload() => <String, dynamic>{
        'ids': messageIds,
        'read': read,
        'at': at.toUtc().millisecondsSinceEpoch,
      };

  factory ReceiptFrame.fromPayload(Map<String, dynamic> payload) => ReceiptFrame(
        messageIds: (payload['ids'] as List<dynamic>? ?? const <dynamic>[])
            .map((dynamic e) => e.toString())
            .toList(growable: false),
        read: payload['read'] as bool? ?? false,
        at: DateTime.fromMillisecondsSinceEpoch(
          (payload['at'] as num?)?.toInt() ?? 0,
          isUtc: true,
        ),
      );
}

/// A call signal: an invitation, an answer, or a hangup.
///

/// One slice of call audio.
///
/// Small and time-stamped rather than a stream, because there is no stream to be had:
/// Tor gives a peer a TCP onion service and nothing else, so audio is sent as a
/// sequence of short buffers through the same envelopes as messages. The time stamp is
/// what lets the receiver notice a gap, since the ordering guarantee of one TCP
/// connection is not available across several.
///

/// The first frame two peers exchange, carrying everything needed for the
/// session handshake: the sender's public keys, a signature over the ephemeral
/// material, the display name, and what the peer is willing to do for the mesh.
class HandshakeFrame extends Frame {
  const HandshakeFrame({
    required this.onionAddress,
    required this.identityPublicKey,
    required this.exchangePublicKey,
    required this.ephemeralPublicKey,
    required this.oneTimePreKey,
    required this.signature,
    required this.displayName,
    this.about = '',
    this.capabilities = const <String, dynamic>{},
    this.protocolVersion = 1,
  });

  final String onionAddress;
  final Uint8List identityPublicKey;
  final Uint8List exchangePublicKey;

  /// A fresh X25519 key for this session, giving forward secrecy.
  final Uint8List ephemeralPublicKey;

  /// The relay/mailbox key the sender is currently publishing, if any.
  final Uint8List? oneTimePreKey;

  /// Ed25519 signature by [identityPublicKey] over the ephemeral and exchange
  /// keys concatenated, proving the sender owns the onion address.
  final Uint8List signature;

  final String displayName;
  final String about;
  final Map<String, dynamic> capabilities;
  final int protocolVersion;

  @override
  String get type => 'hs';

  @override
  Map<String, dynamic> payload() => <String, dynamic>{
        'onion': onionAddress,
        'ik': base64Encode(identityPublicKey),
        'ek': base64Encode(exchangePublicKey),
        'epk': base64Encode(ephemeralPublicKey),
        'otp': oneTimePreKey == null ? null : base64Encode(oneTimePreKey!),
        'sig': base64Encode(signature),
        'name': displayName,
        'about': about,
        'caps': capabilities,
        'pv': protocolVersion,
      };

  factory HandshakeFrame.fromPayload(Map<String, dynamic> payload) => HandshakeFrame(
        onionAddress: payload['onion'] as String? ?? '',
        identityPublicKey: _bytes(payload['ik']),
        exchangePublicKey: _bytes(payload['ek']),
        ephemeralPublicKey: _bytes(payload['epk']),
        oneTimePreKey: payload['otp'] == null ? null : _bytes(payload['otp']),
        signature: _bytes(payload['sig']),
        displayName: payload['name'] as String? ?? '',
        about: payload['about'] as String? ?? '',
        capabilities: Map<String, dynamic>.from(
          payload['caps'] as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{},
        ),
        protocolVersion: (payload['pv'] as num?)?.toInt() ?? 1,
      );

  /// The exact byte string that [signature] covers.
  static Uint8List signedBytes(Uint8List exchangePublicKey, Uint8List ephemeralPublicKey) =>
      Uint8List.fromList(<int>[...exchangePublicKey, ...ephemeralPublicKey]);
}

/// One chunk of an attachment transfer.
class ChunkFrame extends Frame {
  const ChunkFrame({
    required this.attachmentId,
    required this.index,
    required this.totalChunks,
    required this.data,
    required this.isLast,
  });

  final String attachmentId;
  final int index;
  final int totalChunks;

  /// Already encrypted with the per-file key carried in the message frame.
  final Uint8List data;

  final bool isLast;

  @override
  String get type => 'chunk';

  @override
  Map<String, dynamic> payload() => <String, dynamic>{
        'aid': attachmentId,
        'i': index,
        'n': totalChunks,
        'd': base64Encode(data),
        'last': isLast,
      };

  factory ChunkFrame.fromPayload(Map<String, dynamic> payload) => ChunkFrame(
        attachmentId: payload['aid'] as String? ?? '',
        index: (payload['i'] as num?)?.toInt() ?? 0,
        totalChunks: (payload['n'] as num?)?.toInt() ?? 1,
        data: _bytes(payload['d']),
        isLast: payload['last'] as bool? ?? false,
      );
}

/// A presence beacon, exchanged so peers learn who is currently reachable and
/// which relays are healthy.
class PresenceFrame extends Frame {
  const PresenceFrame({
    required this.onionAddress,
    required this.online,
    required this.at,
    this.relaysHeld = 0,
    this.acceptingEnvelopes = false,
  });

  final String onionAddress;
  final bool online;
  final DateTime at;

  /// How many envelopes this peer is currently holding for others — useful
  /// back-pressure information for the mesh.
  final int relaysHeld;

  final bool acceptingEnvelopes;

  @override
  String get type => 'pres';

  @override
  Map<String, dynamic> payload() => <String, dynamic>{
        'onion': onionAddress,
        'online': online,
        'at': at.toUtc().millisecondsSinceEpoch,
        'held': relaysHeld,
        'accept': acceptingEnvelopes,
      };

  factory PresenceFrame.fromPayload(Map<String, dynamic> payload) => PresenceFrame(
        onionAddress: payload['onion'] as String? ?? '',
        online: payload['online'] as bool? ?? true,
        at: DateTime.fromMillisecondsSinceEpoch(
          (payload['at'] as num?)?.toInt() ?? 0,
          isUtc: true,
        ),
        relaysHeld: (payload['held'] as num?)?.toInt() ?? 0,
        acceptingEnvelopes: payload['accept'] as bool? ?? false,
      );
}

/// "Give me everything you are holding for me."
class MailboxRequestFrame extends Frame {
  const MailboxRequestFrame({required this.onionAddress, this.limit = 100});

  final String onionAddress;
  final int limit;

  @override
  String get type => 'pull';

  @override
  Map<String, dynamic> payload() => <String, dynamic>{'onion': onionAddress, 'limit': limit};

  factory MailboxRequestFrame.fromPayload(Map<String, dynamic> payload) => MailboxRequestFrame(
        onionAddress: payload['onion'] as String? ?? '',
        limit: (payload['limit'] as num?)?.toInt() ?? 100,
      );
}

/// Confirms that an envelope was accepted (or rejected) by its destination.
class EnvelopeAckFrame extends Frame {
  const EnvelopeAckFrame({
    required this.envelopeId,
    required this.accepted,
    required this.at,
    this.reason,
  });

  final String envelopeId;
  final bool accepted;
  final DateTime at;
  final String? reason;

  @override
  String get type => 'ack';

  @override
  Map<String, dynamic> payload() => <String, dynamic>{
        'id': envelopeId,
        'ok': accepted,
        'at': at.toUtc().millisecondsSinceEpoch,
        'reason': reason,
      };

  factory EnvelopeAckFrame.fromPayload(Map<String, dynamic> payload) => EnvelopeAckFrame(
        envelopeId: payload['id'] as String? ?? '',
        accepted: payload['ok'] as bool? ?? false,
        at: DateTime.fromMillisecondsSinceEpoch(
          (payload['at'] as num?)?.toInt() ?? 0,
          isUtc: true,
        ),
        reason: payload['reason'] as String?,
      );
}

Uint8List _bytes(Object? value) {
  if (value is String && value.isNotEmpty) return base64Decode(value);
  return Uint8List(0);
}
