import 'dart:convert';
import 'dart:typed_data';

import 'cipher.dart';
import 'crypto_engine.dart';

/// A description of how a key-encryption key was derived, stored alongside the
/// wrapped key so the parameters can be raised later without breaking older
/// vaults.
class KdfDescriptor {
  const KdfDescriptor({required this.salt, required this.params});

  final Uint8List salt;
  final Argon2Params params;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'algorithm': 'argon2id',
        'salt': base64Encode(salt),
        'params': params.toJson(),
      };

  factory KdfDescriptor.fromJson(Map<String, dynamic> json) => KdfDescriptor(
        salt: base64Decode(json['salt'] as String? ?? ''),
        params: Argon2Params.fromJson(
          Map<String, dynamic>.from(json['params'] as Map<dynamic, dynamic>? ?? const {}),
        ),
      );
}

/// The master key, encrypted under a key-encryption key.
class WrappedKey {
  const WrappedKey({required this.blob});

  /// The sealed master key.
  final Uint8List blob;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'algorithm': 'aes-256-gcm',
        'blob': base64Encode(blob),
      };

  factory WrappedKey.fromJson(Map<String, dynamic> json) => WrappedKey(
        blob: base64Decode(json['blob'] as String? ?? ''),
      );
}

/// The vault file: everything needed to recover the master key from the account
/// password, and nothing else.
///
/// The architecture note (`Архитектура DarkFlow.md`) specifies this shape: the
/// account password is stretched with Argon2id into a key that decrypts the
/// master key on disk, and the master key in turn encrypts all data.
///
/// There used to be a second, optional wrap for a six-digit PIN, mixed with a
/// random secret from the platform keystore. It was removed: a PIN is only
/// defensible when that secret cannot leak, and on the platforms that matter
/// here it can — DPAPI and the Android Keystore are both transparent to any
/// process running as the user. What remained was a six-digit path to the
/// master key, which is worse than no second path at all. The header still
/// parses without the fields, so vaults written by that version open with the
/// password exactly as before.
class VaultHeader {
  const VaultHeader({
    required this.passwordKdf,
    required this.passwordWrap,
    this.createdAt,
    this.updatedAt,
    this.revision = 1,
  });

  /// The current on-disk format version.
  static const int currentVersion = 1;

  /// Binds a wrapped master key to this application and version, so a blob
  /// lifted from elsewhere cannot be substituted.
  static const String wrapAad = 'darkflow/vault/master-key/v1';

  final KdfDescriptor passwordKdf;
  final WrappedKey passwordWrap;

  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int revision;

  VaultHeader copyWith({
    KdfDescriptor? passwordKdf,
    WrappedKey? passwordWrap,
    DateTime? updatedAt,
  }) {
    return VaultHeader(
      passwordKdf: passwordKdf ?? this.passwordKdf,
      passwordWrap: passwordWrap ?? this.passwordWrap,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      revision: revision,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': currentVersion,
        'passwordKdf': passwordKdf.toJson(),
        'passwordWrap': passwordWrap.toJson(),
        'createdAt': createdAt?.toUtc().millisecondsSinceEpoch,
        'updatedAt': updatedAt?.toUtc().millisecondsSinceEpoch,
        'revision': revision,
      };

  /// Reads a header, ignoring any `pinKdf`/`pinWrap` an older build wrote.
  ///
  /// Those vaults are still perfectly usable: the password wrap was always the
  /// authority, and it is untouched. Dropping the fields on the way in means a
  /// rewritten header simply stops carrying a second way to the master key.
  factory VaultHeader.fromJson(Map<String, dynamic> json) {
    // The version is read, not just written.
    //
    // The field exists so that a header from a *later* format is refused rather
    // than mis-parsed: without this check a v2 header would be read as v1, and
    // whatever changed would be silently misinterpreted — with the master key as
    // the thing at stake.
    final version = (json['version'] as num?)?.toInt() ?? currentVersion;
    if (version != currentVersion) {
      throw FormatException(
        'this vault was written by a newer version of DarkFlow (header format '
        '$version, this build understands $currentVersion)',
      );
    }
    // Absent rather than wrong-typed, so a truncated `vault.json` reports what is
    // actually missing instead of a cast error from deep inside the parser.
    final kdf = json['passwordKdf'];
    final wrap = json['passwordWrap'];
    if (kdf is! Map || wrap is! Map) {
      throw const FormatException(
        'the vault header is incomplete: it does not contain the wrapped master key',
      );
    }
    return VaultHeader(
      passwordKdf: KdfDescriptor.fromJson(Map<String, dynamic>.from(kdf)),
      passwordWrap: WrappedKey.fromJson(Map<String, dynamic>.from(wrap)),
      createdAt: _time(json['createdAt']),
      updatedAt: _time(json['updatedAt']),
      revision: (json['revision'] as num?)?.toInt() ?? 1,
    );
  }

  String encode() => jsonEncode(toJson());

  factory VaultHeader.decode(String raw) =>
      VaultHeader.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map<dynamic, dynamic>));
}

/// The unlocked key material.
///
/// Holds the 256-bit master key and lazily derives the labelled subkeys that
/// different subsystems use, so a compromise of (say) the attachment store does
/// not hand over the message database.
class MasterKeyRing {
  MasterKeyRing(this._engine, this.masterKey);

  final CryptoEngine _engine;

  /// The root secret. Never written to disk except wrapped by [VaultHeader].
  final Uint8List masterKey;

  final Map<String, Uint8List> _subkeys = <String, Uint8List>{};

  /// The key protecting the encrypted record store.
  Uint8List get databaseKey => subkey('db');

  /// The key protecting attachment contents.
  Uint8List get fileKey => subkey('files');

  /// The key protecting the identity and exchange private keys at rest.
  Uint8List get identityKey => subkey('identity');

  /// The key protecting the outbox, relay mailbox and peer bookkeeping.
  Uint8List get meshKey => subkey('mesh');

  /// The key protecting user settings that are not already public.
  Uint8List get settingsKey => subkey('settings');

  /// Derives (and caches) the subkey for [label].
  ///
  /// HKDF-SHA256 with the master key as input keying material and a per-purpose
  /// `info` string, so every subsystem gets an independent key from one root.
  Uint8List subkey(String label) {
    return _subkeys.putIfAbsent(
      label,
      () => Hkdf.derive(
        engine: _engine,
        ikm: masterKey,
        salt: Uint8List(0),
        info: utf8.encode('darkflow/$label/v1'),
        length: 32,
      ),
    );
  }

  /// Zeroes every key this ring holds. Called when the app locks.
  void destroy() {
    _engine.wipe(masterKey);
    for (final key in _subkeys.values) {
      _engine.wipe(key);
    }
    _subkeys.clear();
  }
}

DateTime? _time(Object? value) {
  final millis = (value as num?)?.toInt();
  if (millis == null || millis == 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
}

/// Creates and opens the vault.
///
/// One secret, wrapped once: Argon2id(password) → AES-256-GCM(master key).
///
/// The wrap never contains the passphrase, and rotating the password rewrites
/// only the header — no message or file is touched, because the data is
/// encrypted under the master key rather than under the password.
///
/// The surface is deliberately this small: the PIN unlock that used to live here
/// is gone, so there is no second key-encryption key to get wrong. A caller
/// looking for a way in that is not the password will not find one, and that is
/// the point.
class KeyVault {
  const KeyVault(this._engine);

  final CryptoEngine _engine;

  /// Creates a brand-new vault protected by [password].
  ///
  /// Returns the header to persist and the unlocked ring to use immediately, so
  /// account creation never has to run the expensive derivation twice.
  Future<(VaultHeader, MasterKeyRing)> create({
    required String password,
    Argon2Params params = Argon2Params.interactive,
  }) async {
    _requirePassword(password);
    final salt = _engine.randomBytes(32);
    final kek = await _engine.argon2id(
      password: Uint8List.fromList(utf8.encode(password)),
      salt: salt,
      params: params,
    );
    final masterKey = _engine.randomBytes(32);
    final wrapped = Cipher.seal(
      engine: _engine,
      key: kek,
      plaintext: masterKey,
      aad: utf8.encode(VaultHeader.wrapAad),
    );
    _engine.wipe(kek);

    final now = DateTime.now().toUtc();
    final header = VaultHeader(
      passwordKdf: KdfDescriptor(salt: salt, params: params),
      passwordWrap: WrappedKey(blob: wrapped),
      createdAt: now,
      updatedAt: now,
    );
    return (header, MasterKeyRing(_engine, masterKey));
  }

  /// Unwraps the master key with the account password.
  ///
  /// Throws [WrongSecretException] when the password is wrong — the AEAD tag is
  /// the only check needed, so there is no separate password verifier to leak.
  Future<MasterKeyRing> unlockWithPassword(VaultHeader header, String password) async {
    final kek = await _engine.argon2id(
      password: Uint8List.fromList(utf8.encode(password)),
      salt: header.passwordKdf.salt,
      params: header.passwordKdf.params,
    );
    try {
      final masterKey = Cipher.open(
        engine: _engine,
        key: kek,
        sealed: header.passwordWrap.blob,
        aad: utf8.encode(VaultHeader.wrapAad),
      );
      return MasterKeyRing(_engine, masterKey);
    } on CryptoFailure {
      throw const WrongSecretException('Incorrect password');
    } on ArgumentError {
      // A tampered header can declare a wrapped-key length the AEAD refuses
      // (`Cipher._requireKey` throws an `ArgumentError`, not a `CryptoFailure`).
      // Letting that escape surfaced an internal exception on the login screen
      // instead of the one thing that is true: the password did not open this
      // vault — or the vault has been altered.
      throw const WrongSecretException('Incorrect password');
    } finally {
      _engine.wipe(kek);
    }
  }

  /// Re-wraps the master key under a new password.
  Future<VaultHeader> changePassword({
    required VaultHeader header,
    required MasterKeyRing ring,
    required String newPassword,
    Argon2Params params = Argon2Params.sensitive,
  }) async {
    _requirePassword(newPassword);
    final salt = _engine.randomBytes(32);
    final kek = await _engine.argon2id(
      password: Uint8List.fromList(utf8.encode(newPassword)),
      salt: salt,
      params: params,
    );
    final wrapped = Cipher.seal(
      engine: _engine,
      key: kek,
      plaintext: ring.masterKey,
      aad: utf8.encode(VaultHeader.wrapAad),
    );
    _engine.wipe(kek);
    return header.copyWith(
      passwordKdf: KdfDescriptor(salt: salt, params: params),
      passwordWrap: WrappedKey(blob: wrapped),
      updatedAt: DateTime.now().toUtc(),
    );
  }

  /// How long a derivation with [params] takes on this device, used by the UI
  /// to explain the cost of a stronger setting.
  Future<Duration> benchmark(Argon2Params params) async {
    final stopwatch = Stopwatch()..start();
    await _engine.argon2id(
      password: Uint8List.fromList(utf8.encode('benchmark')),
      salt: Uint8List(16),
      params: params,
    );
    stopwatch.stop();
    return stopwatch.elapsed;
  }

  void _requirePassword(String password) {
    if (password.length < 8) {
      throw ArgumentError.value(
        password.length,
        'password',
        'the account password must be at least eight characters',
      );
    }
  }
}

/// Thrown when a password does not open the vault.
class WrongSecretException implements Exception {
  const WrongSecretException(this.message);

  final String message;

  @override
  String toString() => message;
}
