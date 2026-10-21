import 'dart:convert';
import 'dart:typed_data';

import '../../core/ids.dart';

/// The local user.
///
/// An account is created offline, with no server involvement. Two key pairs are
/// generated: an Ed25519 *identity* key that signs handshakes, and an X25519
/// *exchange* key used for end-to-end encryption.
///
/// The onion address is **not** derived from the identity key. It is whatever
/// Tor publishes, because Tor owns the hidden-service key and its on-disk
/// secret-key layout is not the standard Ed25519 `seed || publicKey` — writing
/// the key files from the identity key produced an address Tor refused to
/// serve. The account therefore starts with an empty address and adopts Tor's
/// hostname on first startup; see `TorManager`.
class Account {
  const Account({
    required this.id,
    required this.displayName,
    required this.about,
    required this.onionAddress,
    required this.identityPublicKey,
    required this.exchangePublicKey,
    required this.createdAt,
    this.avatarPath,
    this.addressVerified = false,
  });

  final String id;
  final String displayName;

  /// A short free-text bio, entered on the "Create Account" screen.
  final String about;

  /// The user's `.onion` username, as published by Tor. Empty until the daemon
  /// has started at least once.
  final String onionAddress;

  /// The Ed25519 public key that signs handshakes. Its private half never
  /// leaves the encrypted vault.
  final Uint8List identityPublicKey;

  /// An X25519 public key used for end-to-end message encryption. Kept
  /// separate from [identityPublicKey] so that signing and key agreement never
  /// share a key.
  final Uint8List exchangePublicKey;

  final DateTime createdAt;
  final String? avatarPath;

  /// True once Tor has published the hidden service, so the address is known to
  /// be reachable rather than merely stored.
  final bool addressVerified;

  /// True once Tor has told us which address to advertise.
  bool get hasAddress => onionAddress.isNotEmpty;

  Account copyWith({
    String? displayName,
    String? about,
    String? onionAddress,
    String? avatarPath,
    bool? addressVerified,
  }) {
    return Account(
      id: id,
      displayName: displayName ?? this.displayName,
      about: about ?? this.about,
      onionAddress: onionAddress ?? this.onionAddress,
      identityPublicKey: identityPublicKey,
      exchangePublicKey: exchangePublicKey,
      createdAt: createdAt,
      avatarPath: avatarPath ?? this.avatarPath,
      addressVerified: addressVerified ?? this.addressVerified,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'displayName': displayName,
        'about': about,
        'onionAddress': onionAddress,
        'identityPublicKey': base64Encode(identityPublicKey),
        'exchangePublicKey': base64Encode(exchangePublicKey),
        'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
        'avatarPath': avatarPath,
        'addressVerified': addressVerified,
      };

  factory Account.fromJson(Map<String, dynamic> json) {
    return Account(
      id: json['id'] as String? ?? Ids.generate(),
      displayName: json['displayName'] as String? ?? '',
      about: json['about'] as String? ?? '',
      onionAddress: json['onionAddress'] as String? ?? '',
      identityPublicKey: _bytes(json['identityPublicKey']),
      exchangePublicKey: _bytes(json['exchangePublicKey']),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ?? 0,
        isUtc: true,
      ),
      avatarPath: json['avatarPath'] as String?,
      addressVerified: json['addressVerified'] as bool? ?? false,
    );
  }
}

Uint8List _bytes(Object? value) {
  if (value is String && value.isNotEmpty) {
    return base64Decode(value);
  }
  return Uint8List(0);
}
