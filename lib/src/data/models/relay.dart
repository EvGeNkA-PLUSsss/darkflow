import 'dart:convert';
import 'dart:typed_data';

import '../../core/ids.dart';

/// The kind of payload an envelope carries. Relays never inspect beyond this
/// field, and the value is the only thing a relay can learn about the contents.
enum EnvelopeKind {
  /// A chat message (text, or metadata pointing at an attachment).
  message,

  /// A delivery/read receipt for a previously sent message.
  receipt,

  /// A key-exchange / handshake frame.
  handshake,

  /// One chunk of an attachment transfer.
  chunk,

  /// A presence beacon, used to learn which relays are currently reachable.
  presence,

  /// A request for the relay to hand over everything it holds for us.
  mailboxPull,

  /// One chunk of an attachment's bytes.
  ///
  /// Separate from [chunk] because that value is the older, unused framing; this
  /// one carries the metadata alongside the bytes so a recipient can file them
  /// without matching the frame against a message. See `FileTransfer`.
  fileChunk,

  /// A call signal: invitation, answer, or hangup.
  ///
  /// Separate from [callAudio] because a signal must not be stuck behind a backlog of
  /// audio: answering a call should not wait for a hundred queued chunks to drain.

  /// One slice of call audio.
  ///
  /// Its own kind so a relay can treat it as the disposable, time-sensitive traffic it
  /// is. The store-and-forward machinery that makes messages reliable is actively
  /// wrong for audio — a chunk that arrives ten seconds late is noise, not a late word
  /// — and a future relay policy can drop these on expiry without touching anything
  /// else.
  callAudio;

  static EnvelopeKind fromName(String? name) => EnvelopeKind.values.firstWhere(
        (value) => value.name == name,
        orElse: () => EnvelopeKind.message,
      );
}

/// A store-and-forward unit.
///
/// This is the heart of the mesh: when the destination is unreachable, the
/// sender hands the envelope to one or more mutual contacts, who hold it and
/// keep trying. The payload is already end-to-end encrypted with the
/// destination's exchange key, so a relay can forward it but never read it, and
/// [contentHint] is deliberately coarse.
class RelayEnvelope {
  RelayEnvelope({
    required this.id,
    required this.originOnion,
    required this.destinationOnion,
    required this.kind,
    required this.ciphertext,
    required this.createdAt,
    required this.expiresAt,
    this.hopLimit = 3,
    this.path = const <String>[],
    this.requiresAck = true,
    this.attempts = 0,
    this.lastAttemptAt,
    this.acknowledgedAt,
    this.signature,
  });

  /// 128-bit random identifier; also used to de-duplicate on the receiver.
  final String id;

  final String originOnion;
  final String destinationOnion;
  final EnvelopeKind kind;

  /// The end-to-end encrypted payload. A relay sees only opaque bytes.
  final Uint8List ciphertext;

  final DateTime createdAt;
  final DateTime expiresAt;

  /// How many more relays may pass this envelope along before it is dropped.
  /// Prevents an envelope from circulating forever in a well-connected mesh.
  final int hopLimit;

  /// Onions this envelope has already passed through, nearest-first at the end.
  final List<String> path;

  final bool requiresAck;

  /// Delivery attempts made by whoever currently holds the envelope.
  final int attempts;
  final DateTime? lastAttemptAt;
  final DateTime? acknowledgedAt;

  /// An Ed25519 signature by [originOnion]'s identity key, letting the
  /// destination prove who sent the envelope even if it arrived via relays.
  final Uint8List? signature;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);

  /// True when this device is the final destination.
  bool isFor(String onionAddress) => destinationOnion == onionAddress;

  /// The size on the wire, used for mailbox quota accounting.
  int get sizeBytes => ciphertext.length + 256;

  RelayEnvelope copyWith({
    int? hopLimit,
    List<String>? path,
    int? attempts,
    DateTime? lastAttemptAt,
    DateTime? acknowledgedAt,
  }) {
    return RelayEnvelope(
      id: id,
      originOnion: originOnion,
      destinationOnion: destinationOnion,
      kind: kind,
      ciphertext: ciphertext,
      createdAt: createdAt,
      expiresAt: expiresAt,
      hopLimit: hopLimit ?? this.hopLimit,
      path: path ?? this.path,
      requiresAck: requiresAck,
      attempts: attempts ?? this.attempts,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      acknowledgedAt: acknowledgedAt ?? this.acknowledgedAt,
      signature: signature,
    );
  }

  /// The relay-facing representation. Note that the origin is included so the
  /// destination can reply, but the path is kept as a list of hops only.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'originOnion': originOnion,
        'destinationOnion': destinationOnion,
        'kind': kind.name,
        'ciphertext': base64Encode(ciphertext),
        'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
        'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch,
        'hopLimit': hopLimit,
        'path': path,
        'requiresAck': requiresAck,
        'attempts': attempts,
        'lastAttemptAt': lastAttemptAt?.toUtc().millisecondsSinceEpoch,
        'acknowledgedAt': acknowledgedAt?.toUtc().millisecondsSinceEpoch,
        'signature': signature == null ? null : base64Encode(signature!),
      };

  factory RelayEnvelope.fromJson(Map<String, dynamic> json) {
    return RelayEnvelope(
      id: json['id'] as String? ?? Ids.generate(),
      originOnion: json['originOnion'] as String? ?? '',
      destinationOnion: json['destinationOnion'] as String? ?? '',
      kind: EnvelopeKind.fromName(json['kind'] as String?),
      ciphertext: _bytes(json['ciphertext']),
      createdAt: _time(json['createdAt']) ?? DateTime.now().toUtc(),
      expiresAt: _time(json['expiresAt']) ?? DateTime.now().toUtc().add(const Duration(days: 3)),
      hopLimit: (json['hopLimit'] as num?)?.toInt() ?? 3,
      path: (json['path'] as List<dynamic>? ?? const <dynamic>[])
          .map((dynamic e) => e.toString())
          .toList(growable: false),
      requiresAck: json['requiresAck'] as bool? ?? true,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      lastAttemptAt: _time(json['lastAttemptAt']),
      acknowledgedAt: _time(json['acknowledgedAt']),
      signature: json['signature'] == null ? null : _bytes(json['signature']),
    );
  }
}

/// What a peer can do for us, learned during handshakes.
class PeerCapabilities {
  const PeerCapabilities({
    this.relaysForOthers = false,
    this.mailboxQuotaBytes = 0,
    this.supportsFiles = true,
    this.supportsVoice = true,
    this.protocolVersion = 1,
  });

  /// Willing to hold envelopes addressed to third parties.
  final bool relaysForOthers;

  /// How much ciphertext it will store for us.
  final int mailboxQuotaBytes;

  final bool supportsFiles;
  final bool supportsVoice;
  final int protocolVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'relaysForOthers': relaysForOthers,
        'mailboxQuotaBytes': mailboxQuotaBytes,
        'supportsFiles': supportsFiles,
        'supportsVoice': supportsVoice,
        'protocolVersion': protocolVersion,
      };

  factory PeerCapabilities.fromJson(Map<String, dynamic> json) => PeerCapabilities(
        relaysForOthers: json['relaysForOthers'] as bool? ?? false,
        mailboxQuotaBytes: (json['mailboxQuotaBytes'] as num?)?.toInt() ?? 0,
        supportsFiles: json['supportsFiles'] as bool? ?? true,
        supportsVoice: json['supportsVoice'] as bool? ?? true,
        protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? 1,
      );
}

/// What we know about a peer's reachability, used to choose relays and to
/// decide whether to send directly or hand off.
class PeerRecord {
  const PeerRecord({
    required this.onionAddress,
    required this.firstSeenAt,
    this.lastSeenAt,
    this.lastAttemptAt,
    this.successCount = 0,
    this.failureCount = 0,
    this.averageLatencyMs,
    this.capabilities = const PeerCapabilities(),
    this.isReachable = false,
  });

  final String onionAddress;
  final DateTime firstSeenAt;
  final DateTime? lastSeenAt;
  final DateTime? lastAttemptAt;
  final int successCount;
  final int failureCount;
  final int? averageLatencyMs;
  final PeerCapabilities capabilities;
  final bool isReachable;

  /// A 0..1 score combining recency, success ratio and willingness to relay.
  /// Used to order relay candidates.
  double get relayScore {
    final total = successCount + failureCount;
    final reliability = total == 0 ? 0.5 : successCount / total;
    final minutesSinceSeen = lastSeenAt == null
        ? 1440.0
        : DateTime.now().toUtc().difference(lastSeenAt!).inMinutes.toDouble();
    final freshness = (1 - (minutesSinceSeen / 1440)).clamp(0.0, 1.0);
    final willingness = capabilities.relaysForOthers ? 1.0 : 0.0;
    return reliability * 0.5 + freshness * 0.2 + willingness * 0.3;
  }

  PeerRecord copyWith({
    DateTime? lastSeenAt,
    DateTime? lastAttemptAt,
    int? successCount,
    int? failureCount,
    int? averageLatencyMs,
    PeerCapabilities? capabilities,
    bool? isReachable,
  }) {
    return PeerRecord(
      onionAddress: onionAddress,
      firstSeenAt: firstSeenAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      successCount: successCount ?? this.successCount,
      failureCount: failureCount ?? this.failureCount,
      averageLatencyMs: averageLatencyMs ?? this.averageLatencyMs,
      capabilities: capabilities ?? this.capabilities,
      isReachable: isReachable ?? this.isReachable,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'onionAddress': onionAddress,
        'firstSeenAt': firstSeenAt.toUtc().millisecondsSinceEpoch,
        'lastSeenAt': lastSeenAt?.toUtc().millisecondsSinceEpoch,
        'lastAttemptAt': lastAttemptAt?.toUtc().millisecondsSinceEpoch,
        'successCount': successCount,
        'failureCount': failureCount,
        'averageLatencyMs': averageLatencyMs,
        'capabilities': capabilities.toJson(),
        'isReachable': isReachable,
      };

  factory PeerRecord.fromJson(Map<String, dynamic> json) => PeerRecord(
        onionAddress: json['onionAddress'] as String? ?? '',
        firstSeenAt: _time(json['firstSeenAt']) ?? DateTime.now().toUtc(),
        lastSeenAt: _time(json['lastSeenAt']),
        lastAttemptAt: _time(json['lastAttemptAt']),
        successCount: (json['successCount'] as num?)?.toInt() ?? 0,
        failureCount: (json['failureCount'] as num?)?.toInt() ?? 0,
        averageLatencyMs: (json['averageLatencyMs'] as num?)?.toInt(),
        capabilities: json['capabilities'] == null
            ? const PeerCapabilities()
            : PeerCapabilities.fromJson(
                Map<String, dynamic>.from(json['capabilities'] as Map<dynamic, dynamic>),
              ),
        isReachable: json['isReachable'] as bool? ?? false,
      );
}

/// How much of the mesh a user is willing to carry for others.
class RelayPolicy {
  const RelayPolicy({
    this.enabled = true,
    this.maxStoredBytes = 32 * 1024 * 1024,
    this.maxEnvelopes = 512,
    this.retention = const Duration(days: 3),
    this.onlyForContacts = true,
    this.maxHops = 3,
  });

  /// Master switch for acting as a relay for other people.
  final bool enabled;

  final int maxStoredBytes;
  final int maxEnvelopes;

  /// Envelopes older than this are dropped, whatever their own expiry says.
  final Duration retention;

  /// When true, only hold envelopes for people already in the contact list,
  /// which stops the device from becoming a random public mailbox.
  final bool onlyForContacts;

  final int maxHops;

  RelayPolicy copyWith({
    bool? enabled,
    int? maxStoredBytes,
    int? maxEnvelopes,
    Duration? retention,
    bool? onlyForContacts,
    int? maxHops,
  }) {
    return RelayPolicy(
      enabled: enabled ?? this.enabled,
      maxStoredBytes: maxStoredBytes ?? this.maxStoredBytes,
      maxEnvelopes: maxEnvelopes ?? this.maxEnvelopes,
      retention: retention ?? this.retention,
      onlyForContacts: onlyForContacts ?? this.onlyForContacts,
      maxHops: maxHops ?? this.maxHops,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'maxStoredBytes': maxStoredBytes,
        'maxEnvelopes': maxEnvelopes,
        // Milliseconds, not days. `inDays` truncates, so an hours-long retention
        // came back as a different policy — and a retention under a day came back
        // as *zero*, which is a mailbox that expires everything the moment it
        // arrives. The day field is still written so an older build can read the
        // setting back approximately rather than not at all.
        'retentionMs': retention.inMilliseconds,
        'retentionDays': retention.inDays,
        'onlyForContacts': onlyForContacts,
        'maxHops': maxHops,
      };

  factory RelayPolicy.fromJson(Map<String, dynamic> json) => RelayPolicy(
        enabled: json['enabled'] as bool? ?? true,
        maxStoredBytes: (json['maxStoredBytes'] as num?)?.toInt() ?? 32 * 1024 * 1024,
        maxEnvelopes: (json['maxEnvelopes'] as num?)?.toInt() ?? 512,
        retention: Duration(
          milliseconds: (json['retentionMs'] as num?)?.toInt() ??
              ((json['retentionDays'] as num?)?.toInt() ?? 3) * 86400000,
        ),
        onlyForContacts: json['onlyForContacts'] as bool? ?? true,
        maxHops: (json['maxHops'] as num?)?.toInt() ?? 3,
      );
}

Uint8List _bytes(Object? value) {
  if (value is String && value.isNotEmpty) return base64Decode(value);
  return Uint8List(0);
}

DateTime? _time(Object? value) {
  final millis = (value as num?)?.toInt();
  if (millis == null || millis == 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
}
