/// A chat thread with one contact.
///
/// Conversations are keyed by onion address rather than by a synthetic id, so a
/// message arriving from a relay still lands in the right thread even if the
/// contact record has not been created yet.
class Conversation {
  const Conversation({
    required this.id,
    required this.peerOnion,
    required this.createdAt,
    this.lastMessageAt,
    this.lastMessagePreview = '',
    this.lastMessageKind = 'text',
    this.unreadCount = 0,
    this.muted = false,
    this.pinned = false,
    this.archive = false,
    this.draft = '',
    this.disappearingSeconds,
  });

  final String id;
  final String peerOnion;
  final DateTime createdAt;
  final DateTime? lastMessageAt;
  final String lastMessagePreview;
  final String lastMessageKind;
  final int unreadCount;

  /// Suppresses notifications without blocking the contact.
  final bool muted;

  final bool pinned;
  final bool archive;

  /// An unsent composer draft, persisted so it survives a restart.
  final String draft;

  /// When set, messages in this thread vanish this many seconds after being
  /// read.
  final int? disappearingSeconds;

  Conversation copyWith({
    DateTime? lastMessageAt,
    String? lastMessagePreview,
    String? lastMessageKind,
    int? unreadCount,
    bool? muted,
    bool? pinned,
    bool? archive,
    String? draft,
    int? disappearingSeconds,
    bool clearDisappearing = false,
  }) {
    return Conversation(
      id: id,
      peerOnion: peerOnion,
      createdAt: createdAt,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      lastMessageKind: lastMessageKind ?? this.lastMessageKind,
      unreadCount: unreadCount ?? this.unreadCount,
      muted: muted ?? this.muted,
      pinned: pinned ?? this.pinned,
      archive: archive ?? this.archive,
      draft: draft ?? this.draft,
      disappearingSeconds:
          clearDisappearing ? null : (disappearingSeconds ?? this.disappearingSeconds),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'peerOnion': peerOnion,
        'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
        'lastMessageAt': lastMessageAt?.toUtc().millisecondsSinceEpoch,
        'lastMessagePreview': lastMessagePreview,
        'lastMessageKind': lastMessageKind,
        'unreadCount': unreadCount,
        'muted': muted,
        'pinned': pinned,
        'archive': archive,
        'draft': draft,
        'disappearingSeconds': disappearingSeconds,
      };

  factory Conversation.fromJson(Map<String, dynamic> json) {
    return Conversation(
      id: json['id'] as String? ?? '',
      peerOnion: json['peerOnion'] as String? ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ?? 0,
        isUtc: true,
      ),
      lastMessageAt: json['lastMessageAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (json['lastMessageAt'] as num).toInt(),
              isUtc: true,
            ),
      lastMessagePreview: json['lastMessagePreview'] as String? ?? '',
      lastMessageKind: json['lastMessageKind'] as String? ?? 'text',
      unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
      muted: json['muted'] as bool? ?? false,
      pinned: json['pinned'] as bool? ?? false,
      archive: json['archive'] as bool? ?? false,
      draft: json['draft'] as String? ?? '',
      disappearingSeconds: (json['disappearingSeconds'] as num?)?.toInt(),
    );
  }
}
