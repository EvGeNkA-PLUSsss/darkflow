import 'dart:convert';

import '../../core/ids.dart';

/// Who wrote a message.
enum MessageDirection {
  incoming,
  outgoing;

  static MessageDirection fromName(String? name) =>
      name == 'outgoing' ? MessageDirection.outgoing : MessageDirection.incoming;
}

/// What a message carries.
enum MessageKind {
  text,
  file,
  voice,
  image,
  system;

  static MessageKind fromName(String? name) => MessageKind.values.firstWhere(
        (value) => value.name == name,
        orElse: () => MessageKind.text,
      );
}

/// Delivery state of an outgoing message, following the mesh pipeline:
/// queued → sending → sent (accepted by the peer) → delivered (stored on the
/// peer) → read.
enum MessageStatus {
  queued,
  sending,
  sent,
  delivered,
  read,
  failed;

  static MessageStatus fromName(String? name) => MessageStatus.values.firstWhere(
        (value) => value.name == name,
        orElse: () => MessageStatus.queued,
      );

  bool get isTerminal => this == MessageStatus.read || this == MessageStatus.failed;

  /// How far along the pipeline this state is: `queued` → `sending` → `sent` →
  /// `delivered` → `read`. [failed] sits outside the order and is handled
  /// separately, because a failure can happen at any point and can also be
  /// undone by a later success.
  ///
  /// This exists because delivery is genuinely concurrent with sending. The mesh
  /// reports its outcome from a callback that may run *before* the send call
  /// returns, so a naive "set sending, then await" left a message that had
  /// already been delivered showing a `sending` arrow for ever — the state was
  /// written backwards over a newer one. Comparing ranks is what makes the
  /// status monotonic; see `AppController._applyStatus`.
  int get rank => switch (this) {
        MessageStatus.queued => 0,
        MessageStatus.sending => 1,
        MessageStatus.sent => 2,
        MessageStatus.delivered => 3,
        MessageStatus.read => 4,
        // A failure is not a position on the line, so it never wins a
        // comparison; `_applyStatus` moves it to `failed` explicitly and lets
        // any later success move it forward.
        MessageStatus.failed => -1,
      };
}

/// One person's reaction to a message.
///
/// # Deprecated, and being removed
///
/// Reactions were built, tested and then dropped at the user's request. The class is
/// kept for exactly one reason: `Message.fromJson` still has to *read* the field from
/// records written by a build that had reactions, or a stored conversation would fail to
/// load. Nothing writes one any more, nothing draws one, and [Message.reactions] is
/// parsed and discarded.
///
/// Removing the parse would be the tidier code and the worse outcome: a message record
/// is the user's history, and a version that cannot read its own past is a version that
/// loses it.
class Reaction {
  const Reaction({
    required this.emoji,
    required this.byOnion,
    required this.at,
  });

  final String emoji;
  final String byOnion;
  final DateTime at;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'emoji': emoji,
        'by': byOnion,
        'at': at.toUtc().millisecondsSinceEpoch,
      };

  factory Reaction.fromJson(Map<String, dynamic> json) => Reaction(
        emoji: json['emoji'] as String? ?? '',
        byOnion: json['by'] as String? ?? '',
        at: DateTime.fromMillisecondsSinceEpoch(
          (json['at'] as num?)?.toInt() ?? 0,
          isUtc: true,
        ),
      );
}

/// A single message inside a conversation.
///
/// The plaintext of [body] never touches the disk: the repository encrypts the
/// serialised record with the account master key before writing it, and only
/// holds decrypted instances in memory.
class Message {
  const Message({
    required this.id,
    required this.conversationId,
    required this.peerOnion,
    required this.direction,
    required this.kind,
    required this.createdAt,
    required this.body,
    this.status = MessageStatus.queued,
    this.updatedAt,
    this.replyToId,
    this.attachmentId,
    this.deliveredAt,
    this.readAt,
    this.failureReason,
    this.viaRelay = false,
    this.relayOnion,
    this.expiresAt,
    this.editedAt,
    this.isDraft = false,
    this.reactions = const <Reaction>[],
  });

  final String id;
  final String conversationId;

  /// The other party's onion address.
  final String peerOnion;

  final MessageDirection direction;
  final MessageKind kind;
  final DateTime createdAt;
  final DateTime? updatedAt;

  /// The decrypted text content. Empty for attachment-only messages.
  final String body;

  final MessageStatus status;
  final String? replyToId;

  /// Points at an [Attachment] row for file, image and voice messages.
  final String? attachmentId;

  final DateTime? deliveredAt;
  final DateTime? readAt;
  final String? failureReason;

  /// True when this message reached us through a contact acting as a relay
  /// rather than directly from the sender.
  final bool viaRelay;
  final String? relayOnion;

  /// Disappearing-message deadline, when the conversation enables it.
  final DateTime? expiresAt;

  final DateTime? editedAt;
  final bool isDraft;

  bool get isOutgoing => direction == MessageDirection.outgoing;
  bool get hasAttachment => attachmentId != null;

  /// A one-line summary for the conversation list.
  String get preview {
    switch (kind) {
      case MessageKind.text:
        return body;
      case MessageKind.voice:
        return 'Voice message';
      case MessageKind.image:
        return 'Photo';
      case MessageKind.file:
        return 'File';
      case MessageKind.system:
        return body;
    }
  }

  /// Reactions read from a record written by a build that had them.
  ///
  /// Parsed so an old record still loads, and otherwise ignored: the feature was
  /// removed, so nothing displays this and nothing writes it. See [Reaction].
  final List<Reaction> reactions;

  /// A copy with [body], [status] and friends replaced.
  ///
  /// The `clear*` flags exist because Dart cannot tell "argument omitted" from
  /// "argument passed as null" for a nullable parameter, and several of these
  /// fields genuinely have to be able to go *back* to null:
  ///
  /// * [clearFailureReason] — a message that failed and was then delivered by the
  ///   outbox kept its old explanation for ever, so a delivered bubble went on
  ///   saying "No route yet" underneath a double tick;
  /// * [clearAttachmentId] — an incoming message re-stored without its
  ///   attachment has to lose the pointer rather than keep a dangling one;
  /// * [clearReplyToId] — an edit that removes a quote.
  Message copyWith({
    String? body,
    MessageStatus? status,
    DateTime? updatedAt,
    DateTime? deliveredAt,
    DateTime? readAt,
    String? failureReason,
    bool clearFailureReason = false,
    bool? viaRelay,
    String? relayOnion,
    String? attachmentId,
    bool clearAttachmentId = false,
    DateTime? expiresAt,
    DateTime? editedAt,
    List<Reaction>? reactions,
    bool? isDraft,
    String? replyToId,
    bool clearReplyToId = false,
  }) {
    return Message(
      id: id,
      conversationId: conversationId,
      peerOnion: peerOnion,
      direction: direction,
      kind: kind,
      createdAt: createdAt,
      body: body ?? this.body,
      status: status ?? this.status,
      updatedAt: updatedAt ?? this.updatedAt,
      replyToId: clearReplyToId ? null : (replyToId ?? this.replyToId),
      attachmentId: clearAttachmentId ? null : (attachmentId ?? this.attachmentId),
      deliveredAt: deliveredAt ?? this.deliveredAt,
      readAt: readAt ?? this.readAt,
      failureReason: clearFailureReason ? null : (failureReason ?? this.failureReason),
      viaRelay: viaRelay ?? this.viaRelay,
      relayOnion: relayOnion ?? this.relayOnion,
      expiresAt: expiresAt ?? this.expiresAt,
      editedAt: editedAt ?? this.editedAt,
      isDraft: isDraft ?? this.isDraft,
      reactions: reactions ?? this.reactions,
    );
  }

  /// The message as it appears inside an end-to-end encrypted envelope.
  ///
  /// Only fields the peer needs are included; local bookkeeping such as
  /// [status] and [failureReason] stays on the sender's device.
  Map<String, dynamic> toWireJson() => <String, dynamic>{
        'id': id,
        'kind': kind.name,
        'body': body,
        'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
        'replyToId': replyToId,
        'attachmentId': attachmentId,
        'expiresAt': expiresAt?.toUtc().millisecondsSinceEpoch,
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'conversationId': conversationId,
        'peerOnion': peerOnion,
        'direction': direction.name,
        'kind': kind.name,
        'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
        'updatedAt': updatedAt?.toUtc().millisecondsSinceEpoch,
        'body': body,
        'status': status.name,
        'replyToId': replyToId,
        'attachmentId': attachmentId,
        'deliveredAt': deliveredAt?.toUtc().millisecondsSinceEpoch,
        'readAt': readAt?.toUtc().millisecondsSinceEpoch,
        'failureReason': failureReason,
        'viaRelay': viaRelay,
        'relayOnion': relayOnion,
        'expiresAt': expiresAt?.toUtc().millisecondsSinceEpoch,
        'editedAt': editedAt?.toUtc().millisecondsSinceEpoch,
        'isDraft': isDraft,
      };

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'] as String? ?? Ids.generate(),
      conversationId: json['conversationId'] as String? ?? '',
      peerOnion: json['peerOnion'] as String? ?? '',
      direction: MessageDirection.fromName(json['direction'] as String?),
      kind: MessageKind.fromName(json['kind'] as String?),
      createdAt: _time(json['createdAt']) ?? DateTime.now().toUtc(),
      updatedAt: _time(json['updatedAt']),
      body: json['body'] as String? ?? '',
      status: MessageStatus.fromName(json['status'] as String?),
      replyToId: json['replyToId'] as String?,
      attachmentId: json['attachmentId'] as String?,
      deliveredAt: _time(json['deliveredAt']),
      readAt: _time(json['readAt']),
      failureReason: json['failureReason'] as String?,
      viaRelay: json['viaRelay'] as bool? ?? false,
      relayOnion: json['relayOnion'] as String?,
      expiresAt: _time(json['expiresAt']),
      editedAt: _time(json['editedAt']),
      isDraft: json['isDraft'] as bool? ?? false,
      reactions: <Reaction>[
        for (final row in (json['reactions'] as List<dynamic>? ?? const <dynamic>[]))
          if (row is Map<dynamic, dynamic>)
            Reaction.fromJson(Map<String, dynamic>.from(row)),
      ],
    );
  }

  /// Rebuilds a message received over the wire, filling in the local fields the
  /// sender does not transmit.
  ///
  /// [peerOnion] matters: the wire format deliberately carries no recipient, and
  /// the sender's own address is not part of the payload either — the envelope
  /// that carried it is the only thing that knows who wrote it. Passing the
  /// address in from the envelope is what makes a received message land in the
  /// right thread and be sealed to the right key when it is answered. Leaving it
  /// empty here is what made plain text messages arrive in no conversation at
  /// all, because the account layer had nothing to file them under.
  factory Message.fromWireJson(
    Map<String, dynamic> json, {
    required String conversationId,
    required String peerOnion,
    required MessageDirection direction,
  }) {
    return Message(
      id: json['id'] as String? ?? Ids.generate(),
      conversationId: conversationId,
      peerOnion: peerOnion,
      direction: direction,
      kind: MessageKind.fromName(json['kind'] as String?),
      createdAt: _time(json['createdAt']) ?? DateTime.now().toUtc(),
      body: json['body'] as String? ?? '',
      status: direction == MessageDirection.outgoing
          ? MessageStatus.sent
          : MessageStatus.delivered,
      replyToId: json['replyToId'] as String?,
      attachmentId: json['attachmentId'] as String?,
      expiresAt: _time(json['expiresAt']),
    );
  }
}

/// A file, image or voice note attached to a message.
///
/// The bytes live encrypted in the app's file vault; [localPath] points at the
/// decrypted cache entry, which is only materialised on demand.
class Attachment {
  const Attachment({
    required this.id,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.sha256Hex,
    required this.createdAt,
    this.messageId,
    this.localPath,
    this.durationMs,
    this.waveform = const <int>[],
    this.width,
    this.height,
    this.transferProgress = 0,
    this.transferComplete = false,
    this.remoteKeyId,
  });

  final String id;
  final String? messageId;
  final String fileName;
  final String mimeType;
  final int sizeBytes;

  /// Integrity check over the *plaintext* bytes.
  final String sha256Hex;

  final DateTime createdAt;

  /// Where the decrypted copy lives in the app cache, once needed.
  final String? localPath;

  /// Voice notes: length in milliseconds.
  final int? durationMs;

  /// Voice notes: normalised 0-100 amplitude buckets for the waveform view.
  final List<int> waveform;

  final int? width;
  final int? height;

  /// 0..1 while receiving.
  final double transferProgress;
  final bool transferComplete;

  /// Identifier of the per-file key in the key store.
  final String? remoteKeyId;

  bool get isVoice => durationMs != null;
  bool get isImage => mimeType.startsWith('image/');

  String get readableSize {
    const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    var value = sizeBytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = value >= 10 || unit == 0 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }

  String get readableDuration {
    final ms = durationMs ?? 0;
    final totalSeconds = (ms / 1000).round();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Attachment copyWith({
    String? messageId,
    String? localPath,
    double? transferProgress,
    bool? transferComplete,
    List<int>? waveform,
    int? durationMs,
  }) {
    return Attachment(
      id: id,
      messageId: messageId ?? this.messageId,
      fileName: fileName,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      sha256Hex: sha256Hex,
      createdAt: createdAt,
      localPath: localPath ?? this.localPath,
      durationMs: durationMs ?? this.durationMs,
      waveform: waveform ?? this.waveform,
      width: width,
      height: height,
      transferProgress: transferProgress ?? this.transferProgress,
      transferComplete: transferComplete ?? this.transferComplete,
      remoteKeyId: remoteKeyId,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'messageId': messageId,
        'fileName': fileName,
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
        'sha256Hex': sha256Hex,
        'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
        'localPath': localPath,
        'durationMs': durationMs,
        'waveform': waveform,
        'width': width,
        'height': height,
        'transferProgress': transferProgress,
        'transferComplete': transferComplete,
        'remoteKeyId': remoteKeyId,
      };

  factory Attachment.fromJson(Map<String, dynamic> json) {
    return Attachment(
      id: json['id'] as String? ?? Ids.generate(),
      messageId: json['messageId'] as String?,
      fileName: json['fileName'] as String? ?? 'file',
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      sha256Hex: json['sha256Hex'] as String? ?? '',
      createdAt: _time(json['createdAt']) ?? DateTime.now().toUtc(),
      localPath: json['localPath'] as String?,
      durationMs: (json['durationMs'] as num?)?.toInt(),
      waveform: (json['waveform'] as List<dynamic>? ?? const <dynamic>[])
          .map((dynamic e) => (e as num).toInt())
          .toList(growable: false),
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      transferProgress: (json['transferProgress'] as num?)?.toDouble() ?? 0,
      transferComplete: json['transferComplete'] as bool? ?? false,
      remoteKeyId: json['remoteKeyId'] as String?,
    );
  }

  /// The metadata that travels with a file message, so the receiver knows what
  /// it is about to fetch before downloading anything.
  Map<String, dynamic> toWireJson() => <String, dynamic>{
        'id': id,
        'fileName': fileName,
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
        'sha256Hex': sha256Hex,
        'durationMs': durationMs,
        'waveform': waveform,
        'width': width,
        'height': height,
        'remoteKeyId': remoteKeyId,
      };

  /// Serialises to a JSON string for the encrypted blob store.
  String encode() => jsonEncode(toJson());
}

DateTime? _time(Object? value) {
  final millis = (value as num?)?.toInt();
  if (millis == null || millis == 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
}
