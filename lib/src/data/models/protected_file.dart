import 'dart:convert';

/// A file the user has sealed into the vault to keep.
///
/// Distinct from an [Attachment], which is a file that belongs to a message. A
/// protected file belongs to nobody: it was chosen from the file system, it has no
/// conversation, and it is never sent. The two share the encrypted blob store —
/// `FileVault` seals both the same way — but keeping them in separate records is
/// what lets the protected-files screen show the user's own files instead of every
/// attachment in every conversation.
class ProtectedFile {
  const ProtectedFile({
    required this.id,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.sha256Hex,
    required this.addedAt,
    this.savedTo,
  });

  /// The identifier the vault addresses the ciphertext by.
  ///
  /// Not derived from the name: two files may share one, and a name is exactly the
  /// kind of thing a user changes after the fact.
  final String id;

  final String fileName;
  final String mimeType;
  final int sizeBytes;

  /// The plaintext's SHA-256, computed while sealing. Never verified on open —
  /// GCM authentication per chunk already guarantees the bytes are the ones that
  /// were written — but kept because it identifies the content if the same file is
  /// added twice.
  final String sha256Hex;

  final DateTime addedAt;

  /// Where the user last chose to keep a decrypted copy, when they did.
  ///
  /// Recorded so the screen can say a file also exists outside the vault. It is
  /// not used to open anything: a path the user picked once may be gone, and
  /// trusting it silently would open the wrong file or none.
  final String? savedTo;

  /// True when a decrypted copy exists outside the vault.
  ///
  /// The thing a user of a protected-files screen needs at a glance: whether the
  /// file is only in here, or also somewhere they can reach without DarkFlow.
  bool get hasSavedCopy => savedTo != null && savedTo!.isNotEmpty;

  ProtectedFile copyWith({String? savedTo, bool clearSavedTo = false}) => ProtectedFile(
        id: id,
        fileName: fileName,
        mimeType: mimeType,
        sizeBytes: sizeBytes,
        sha256Hex: sha256Hex,
        addedAt: addedAt,
        savedTo: clearSavedTo ? null : (savedTo ?? this.savedTo),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'fileName': fileName,
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
        'sha256Hex': sha256Hex,
        'addedAt': addedAt.toUtc().millisecondsSinceEpoch,
        'savedTo': savedTo,
      };

  factory ProtectedFile.fromJson(Map<String, dynamic> json) => ProtectedFile(
        id: json['id'] as String? ?? '',
        fileName: json['fileName'] as String? ?? 'file',
        mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
        sha256Hex: json['sha256Hex'] as String? ?? '',
        addedAt: DateTime.fromMillisecondsSinceEpoch(
          (json['addedAt'] as num?)?.toInt() ?? 0,
          isUtc: true,
        ),
        savedTo: json['savedTo'] as String?,
      );

  String encode() => jsonEncode(toJson());

  static ProtectedFile decode(String raw) =>
      ProtectedFile.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  /// The size as a person would say it, e.g. `'2.4 MB'`.
  String get readableSize => formatBytes(sizeBytes);
}

/// Binary-prefix sizes, one decimal below ten units so `'1.4 MB'` and `'148 MB'`
/// both stay readable.
///
/// Shared with the screen rather than duplicated there, because a file list that
/// disagreed with the header total about the same file would be worse than either
/// rounding on its own.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kilobytes = bytes / 1024;
  if (kilobytes < 1024) {
    return '${kilobytes.toStringAsFixed(kilobytes < 10 ? 1 : 0)} KB';
  }
  final megabytes = kilobytes / 1024;
  if (megabytes < 1024) {
    return '${megabytes.toStringAsFixed(megabytes < 10 ? 1 : 0)} MB';
  }
  return '${(megabytes / 1024).toStringAsFixed(1)} GB';
}
