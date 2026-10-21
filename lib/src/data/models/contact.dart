import 'dart:convert';
import 'dart:typed_data';

import '../../core/ids.dart';
import '../../crypto/onion_address.dart';

/// How much a contact's identity has been confirmed.
enum ContactTrust {
  /// The address was typed or pasted; nothing has been confirmed.
  unverified,

  /// The address has been connected to once, so an identity key has been seen
  /// and pinned.
  keyed,

  /// The key that was just presented differs from the pinned one. This is the
  /// signal a user must not ignore: it means either the contact reinstalled, or
  /// somebody is impersonating the address.
  keyChanged,

  /// The user compared the safety number out of band.
  verified;

  static ContactTrust fromName(String? name) => ContactTrust.values.firstWhere(
        (value) => value.name == name,
        orElse: () => ContactTrust.unverified,
      );
}

/// A peer the user talks to.
class Contact {
  const Contact({
    required this.id,
    required this.onionAddress,
    required this.displayName,
    required this.addedAt,
    this.about = '',
    this.identityPublicKey,
    this.exchangePublicKey,
    this.lastSeenAt,
    this.blocked = false,
    this.notificationsEnabled = true,
    this.trust = ContactTrust.unverified,
    this.avatarPath,
    this.relayOnions = const <String>[],
    this.isRelayForUs = false,
    this.offersMailbox = false,
  });

  final String id;

  /// The contact's onion address — their username.
  final String onionAddress;

  final String displayName;
  final String about;
  final DateTime addedAt;
  final DateTime? lastSeenAt;

  /// The Ed25519 identity key that signs the contact's handshakes.
  ///
  /// Learned from the first successful handshake and pinned from then on. The
  /// onion address cannot provide it: that address belongs to Tor's hidden
  /// service key, which is a different key from the one that authenticates the
  /// account. Pinning is what turns "an address" into "a person" — if a later
  /// handshake presents a different key, the contact is flagged rather than
  /// silently trusted.
  final Uint8List? identityPublicKey;

  /// Learned during the first successful handshake.
  final Uint8List? exchangePublicKey;

  final bool blocked;
  final bool notificationsEnabled;
  final ContactTrust trust;
  final String? avatarPath;

  /// Other onions this contact has told us it will forward messages to when we
  /// are offline.
  final List<String> relayOnions;

  /// True when the contact has agreed to store messages addressed to us while
  /// we are offline.
  final bool isRelayForUs;

  /// True when the contact may hold our ciphertext mailbox.
  final bool offersMailbox;

  String get initial {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) return '?';
    // `runes` rather than `substring(0, 1)` so an emoji or a non-BMP script
    // yields one whole character instead of half a surrogate pair.
    return String.fromCharCode(trimmed.runes.first).toUpperCase();
  }

  /// True when we hold a key we can encrypt to.
  bool get canEncrypt => exchangePublicKey != null && exchangePublicKey!.isNotEmpty;

  Contact copyWith({
    String? displayName,
    String? about,
    Uint8List? exchangePublicKey,
    Uint8List? identityPublicKey,
    DateTime? lastSeenAt,
    bool? blocked,
    bool? notificationsEnabled,
    ContactTrust? trust,
    String? avatarPath,
    List<String>? relayOnions,
    bool? isRelayForUs,
    bool? offersMailbox,
  }) {
    return Contact(
      id: id,
      onionAddress: onionAddress,
      displayName: displayName ?? this.displayName,
      about: about ?? this.about,
      addedAt: addedAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      identityPublicKey: identityPublicKey ?? this.identityPublicKey,
      exchangePublicKey: exchangePublicKey ?? this.exchangePublicKey,
      blocked: blocked ?? this.blocked,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      trust: trust ?? this.trust,
      avatarPath: avatarPath ?? this.avatarPath,
      relayOnions: relayOnions ?? this.relayOnions,
      isRelayForUs: isRelayForUs ?? this.isRelayForUs,
      offersMailbox: offersMailbox ?? this.offersMailbox,
    );
  }

  /// Builds a contact from a pasted onion address, validating it first.
  ///
  /// The identity key is left unset on purpose: the address names a Tor service,
  /// not a person, so the key that identifies the account is learned from the
  /// first handshake and pinned then. See [Contact.identityPublicKey].
  static Contact? fromOnion({
    required String onionAddress,
    String? displayName,
    String about = '',
    DateTime? addedAt,
  }) {
    final normalised = OnionAddress.normalise(onionAddress);
    if (!OnionAddress.isValid(normalised)) return null;
    return Contact(
      id: Ids.generate(),
      onionAddress: normalised,
      displayName: (displayName == null || displayName.trim().isEmpty)
          ? OnionAddress.shorten(normalised)
          : displayName.trim(),
      about: about,
      addedAt: addedAt ?? DateTime.now().toUtc(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'onionAddress': onionAddress,
        'displayName': displayName,
        'about': about,
        'addedAt': addedAt.toUtc().millisecondsSinceEpoch,
        'lastSeenAt': lastSeenAt?.toUtc().millisecondsSinceEpoch,
        'identityPublicKey':
            identityPublicKey == null ? null : base64Encode(identityPublicKey!),
        'exchangePublicKey':
            exchangePublicKey == null ? null : base64Encode(exchangePublicKey!),
        'blocked': blocked,
        'notificationsEnabled': notificationsEnabled,
        'trust': trust.name,
        'avatarPath': avatarPath,
        'relayOnions': relayOnions,
        'isRelayForUs': isRelayForUs,
        'offersMailbox': offersMailbox,
      };

  factory Contact.fromJson(Map<String, dynamic> json) {
    return Contact(
      id: json['id'] as String? ?? Ids.generate(),
      onionAddress: json['onionAddress'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      about: json['about'] as String? ?? '',
      addedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['addedAt'] as num?)?.toInt() ?? 0,
        isUtc: true,
      ),
      lastSeenAt: json['lastSeenAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (json['lastSeenAt'] as num).toInt(),
              isUtc: true,
            ),
      identityPublicKey: _bytes(json['identityPublicKey']),
      exchangePublicKey: _bytes(json['exchangePublicKey']),
      blocked: json['blocked'] as bool? ?? false,
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? true,
      trust: ContactTrust.fromName(json['trust'] as String?),
      avatarPath: json['avatarPath'] as String?,
      relayOnions: (json['relayOnions'] as List<dynamic>? ?? const <dynamic>[])
          .map((dynamic e) => e as String)
          .toList(growable: false),
      isRelayForUs: json['isRelayForUs'] as bool? ?? false,
      offersMailbox: json['offersMailbox'] as bool? ?? false,
    );
  }
}

Uint8List? _bytes(Object? value) {
  if (value is String && value.isNotEmpty) return base64Decode(value);
  return null;
}
