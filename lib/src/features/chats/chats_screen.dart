import 'dart:async';

import 'package:flutter/material.dart';

import '../../crypto/onion_address.dart';
import '../../design/design.dart';
import 'widgets/conversation_tile.dart';
import 'widgets/empty_chats_view.dart';
import 'widgets/peer_menu.dart';

/// What the conversation list needs to know about one thread.
///
/// The screen takes this projection rather than a `Conversation` plus a
/// `Contact`, because the list needs one field from each and nothing else. It
/// keeps the screen presentational: the app layer decides where a display name,
/// a presence flag or an avatar path comes from.
class ConversationSummary {
  const ConversationSummary({
    required this.peerOnion,
    required this.displayName,
    this.avatarPath,
    this.online = false,
    this.lastMessagePreview = '',
    this.lastMessageAt,
    this.unreadCount = 0,
    this.muted = false,
    this.pinned = false,
  });

  /// The peer's onion address, and the key of the thread.
  final String peerOnion;

  /// The contact's name, or the shortened onion address when unnamed.
  final String displayName;

  final String? avatarPath;
  final bool online;
  final String lastMessagePreview;
  final DateTime? lastMessageAt;
  final int unreadCount;
  final bool muted;
  final bool pinned;

  /// The glyph the avatar shows when there is no picture.
  String get initialLetter {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) return '?';
    // `runes` so a non-BMP first character (an emoji name, say) survives.
    return String.fromCharCode(trimmed.runes.first).toUpperCase();
  }
}

/// The conversation list: title, search field, threads and the add button.
///
/// The screen never sorts or mutates what it is given — the app layer owns the
/// order (pinned threads first, then by recency) and hands the list back. It
/// only filters locally so typing feels instant; [onSearch] still fires so the
/// app layer can query further if it ever needs to.
class ChatsScreen extends StatelessWidget {
  const ChatsScreen({
    required this.conversations,
    required this.onOpenConversation,
    required this.onAddContact,
    this.onSearch,
    this.onStartChatWith,
    this.onOpenSettings,
    this.onOpenProfile,
    this.onOpenContactProfile,
    this.title = 'Chats',
    super.key,
  });

  final List<ConversationSummary> conversations;

  /// Opens the thread with this onion address.
  final void Function(String peerOnion) onOpenConversation;

  /// Opens [AddContactSheet].
  final VoidCallback onAddContact;

  final ValueChanged<String>? onSearch;

  /// Starts a thread with an address the account does not know yet. Only used
  /// when the search field holds a whole, valid onion address: DarkFlow has no
  /// directory to look anything up in, so a pasted address is the one thing a
  /// search can legitimately resolve.
  final Future<void> Function(String onionAddress)? onStartChatWith;

  final String title;

  /// Opens the settings screen. Rendered as a gear in the header when non-null.
  ///
  /// The desktop layout reaches settings from its sidebar; this is the only
  /// route from the phone layout, so a null here means the user cannot get
  /// there at all.
  final VoidCallback? onOpenSettings;

  /// Opens the account's own profile. Rendered as a person glyph when non-null.
  final VoidCallback? onOpenProfile;

  /// Opens the peer's profile, which is where a contact is renamed, cleared or
  /// deleted.
  ///
  /// It is offered from both layouts on purpose: the phone layout is this screen
  /// and nothing else, so a management action wired only into the desktop sidebar
  /// would not exist here. When null, rows simply do not answer a long press.
  final void Function(String peerOnion)? onOpenContactProfile;

  /// The mockup's right margin for the floating add button.
  static const double _fabMargin = AppMetrics.fabMargin;

  /// The mockup's bottom margin for the floating add button.
  static const double _fabBottomMargin = 24;

  /// On a wide desktop window the list would stretch across the monitor, so it
  /// is centred in a column of at most twice the form width (880 pt).
  static const double _maxContentWidth = AppMetrics.maxContentWidth * 2;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxContentWidth),
            child: _ChatsBody(
              conversations: conversations,
              onOpenConversation: onOpenConversation,
              onAddContact: onAddContact,
              onSearch: onSearch,
              onStartChatWith: onStartChatWith,
              onOpenSettings: onOpenSettings,
              onOpenProfile: onOpenProfile,
              onOpenContactProfile: onOpenContactProfile,
              title: title,
            ),
          ),
        ),
      ),
    );
  }
}

/// Owns the one piece of state the screen has: the search query.
class _ChatsBody extends StatefulWidget {
  const _ChatsBody({
    required this.conversations,
    required this.onOpenConversation,
    required this.onAddContact,
    required this.onSearch,
    required this.onStartChatWith,
    required this.onOpenSettings,
    required this.onOpenProfile,
    required this.onOpenContactProfile,
    required this.title,
  });

  final List<ConversationSummary> conversations;
  final void Function(String peerOnion) onOpenConversation;
  final VoidCallback onAddContact;
  final ValueChanged<String>? onSearch;
  final Future<void> Function(String onionAddress)? onStartChatWith;

  /// Forwarded to the header, which draws a gear when this is non-null.
  final VoidCallback? onOpenSettings;

  /// Forwarded to the header, which draws a person glyph when this is non-null.
  final VoidCallback? onOpenProfile;

  /// Forwarded to each row, which offers it on a long press when non-null.
  final void Function(String peerOnion)? onOpenContactProfile;

  final String title;

  @override
  State<_ChatsBody> createState() => _ChatsBodyState();
}

class _ChatsBodyState extends State<_ChatsBody> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  String get _trimmedQuery => _query.text.trim();

  /// A whole onion address that is not in the list yet, which is the only
  /// query this screen can act on beyond filtering.
  String? get _pendingOnion {
    if (widget.onStartChatWith == null) return null;
    final candidate = OnionAddress.normalise(_query.text);
    if (!OnionAddress.isValid(candidate)) return null;
    final known = widget.conversations.any((c) => c.peerOnion == candidate);
    return known ? null : candidate;
  }

  List<ConversationSummary> get _visible {
    final query = _trimmedQuery.toLowerCase();
    if (query.isEmpty) return widget.conversations;
    return widget.conversations
        .where(
          (c) =>
              c.displayName.toLowerCase().contains(query) ||
              c.peerOnion.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  void _clearQuery() {
    _query.clear();
    widget.onSearch?.call('');
    setState(() {});
  }

  /// Enter on a whole onion address does what tapping the offer row does, so a
  /// pasted address can be confirmed from the keyboard alone.
  void _startPendingChat() {
    final onion = _pendingOnion;
    if (onion == null) return;
    widget.onStartChatWith?.call(onion);
  }

  @override
  Widget build(BuildContext context) {
    final pendingOnion = _pendingOnion;

    return Stack(
      children: [
        Column(
          children: [
            // 24 pt below the safe area, as the mockup measures it.
            const SizedBox(height: 24),
            // Settings and the profile live here, not only in the desktop
            // sidebar.
            //
            // They used to be wired into `DesktopShell` alone, which meant that
            // on a phone — where the shell is this screen and nothing else —
            // there was no route to either. The screen is deliberately wider
            // than the measured mockup by the two 44 pt buttons; they are the
            // same width on both sides so the title stays optically centred.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: widget.onOpenProfile == null
                        ? null
                        : IconButton(
                            onPressed: widget.onOpenProfile,
                            icon: const Icon(Icons.person_outline, size: 22),
                            color: AppColors.textPrimary,
                            tooltip: 'My profile',
                          ),
                  ),
                  Expanded(child: ScreenTitle(widget.title)),
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: widget.onOpenSettings == null
                        ? null
                        : IconButton(
                            onPressed: widget.onOpenSettings,
                            icon: const Icon(Icons.settings_outlined, size: 22),
                            color: AppColors.textPrimary,
                            tooltip: 'Settings',
                          ),
                  ),
                ],
              ),
            ),
            // The title's line box ends 26 pt above the search field in
            // `Chats.svg`; the field itself starts at x = 45, y = 120.
            const SizedBox(height: 26),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppMetrics.controlInset),
              child: _SearchField(
                controller: _query,
                onChanged: (String value) {
                  widget.onSearch?.call(value);
                  setState(() {});
                },
                onClear: _clearQuery,
                onSubmitted: _startPendingChat,
              ),
            ),
            // The list's first avatar sits 30 pt below the field; a tile
            // centres its 48 pt avatar in a 72 pt row, so the list starts 18.
            const SizedBox(height: 18),
            Expanded(child: _buildList(pendingOnion)),
          ],
        ),
        Positioned(
          right: ChatsScreen._fabMargin,
          bottom: ChatsScreen._fabBottomMargin,
          child: _AddContactButton(onTap: widget.onAddContact),
        ),
      ],
    );
  }

  Widget _buildList(String? pendingOnion) {
    final visible = _visible;
    final offset = pendingOnion == null ? 0 : 1;

    if (visible.isEmpty && pendingOnion == null) {
      // A search that matches nothing is not the same state as an account with
      // no threads, and saying so is more useful than a blank list.
      if (widget.conversations.isEmpty) {
        return EmptyChatsView(onAddContact: widget.onAddContact);
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppMetrics.screenPadding),
          child: Text(
            'No conversations match “$_trimmedQuery”.',
            style: AppTypography.secondary,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 0, bottom: 88),
      itemCount: visible.length + offset,
      itemBuilder: (BuildContext context, int index) {
        final onion = pendingOnion;
        if (onion != null && index == 0) {
          return _StartChatTile(
            onion: onion,
            onTap: () => widget.onStartChatWith!(onion),
          );
        }
        final summary = visible[index - offset];
        return ConversationTile(
          displayName: summary.displayName,
          avatarPath: summary.avatarPath,
          online: summary.online,
          preview: summary.lastMessagePreview,
          lastMessageAt: summary.lastMessageAt,
          unreadCount: summary.unreadCount,
          muted: summary.muted,
          pinned: summary.pinned,
          onTap: () => widget.onOpenConversation(summary.peerOnion),
          onMenuRequested: widget.onOpenContactProfile == null
              ? null
              : (Offset position) => unawaited(
                    showPeerMenu(
                      context,
                      position: position,
                      actions: _peerMenuActions(summary),
                    ),
                  ),
        );
      },
    );
  }

  /// What a row offers on a long press. One item per row today — the profile,
  /// which is where the contact is managed — because the profile already states
  /// the consequence of each management action and a second copy here would have
  /// to be kept in step with it.
  List<PeerMenuAction> _peerMenuActions(ConversationSummary summary) {
    final openProfile = widget.onOpenContactProfile;
    if (openProfile == null) return const <PeerMenuAction>[];
    return <PeerMenuAction>[
      PeerMenuAction(
        label: 'Contact profile',
        onChosen: () => openProfile(summary.peerOnion),
      ),
    ];
  }
}

/// The 300 x 40 pill that filters the list.
///
/// Material's `AppTextField` is deliberately not reused: it is 56 pt tall with
/// a 12 pt radius, while the mockup's search field is a 40 pt pill.
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    // The mockup's 300 pt field is exactly what a 390 pt canvas leaves between
    // two 45 pt insets; on a wider window the same 300 pt pill stays centred
    // instead of stretching.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Container(
          height: AppMetrics.searchHeight,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppMetrics.searchHeight / 2),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              const Icon(Icons.search, size: 20, color: AppColors.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: controller,
                  onChanged: onChanged,
                  onSubmitted: (String _) => onSubmitted(),
                  textInputAction: TextInputAction.search,
                  cursorColor: AppColors.accent,
                  style: AppTypography.input,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: 'Search...',
                    hintStyle: AppTypography.placeholder,
                  ),
                ),
              ),
              if (controller.text.isNotEmpty)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onClear,
                  child: const SizedBox(
                    width: 32,
                    height: 32,
                    child: Icon(Icons.close, size: 18, color: AppColors.textSecondary),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The 48 pt accent circle in the bottom-right corner.
///
/// Built from a [Positioned] rather than a [FloatingActionButton] so its size
/// and margins match the mockup exactly, without Material's own padding.
class _AddContactButton extends StatelessWidget {
  const _AddContactButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: AppMetrics.fabSize,
          height: AppMetrics.fabSize,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
          child: const Icon(Icons.add, size: 24, color: AppColors.textOnAccent),
        ),
      ),
    );
  }
}

/// The row offered when the search field holds a valid unknown address.
class _StartChatTile extends StatefulWidget {
  const _StartChatTile({required this.onion, required this.onTap});

  final String onion;
  final VoidCallback onTap;

  @override
  State<_StartChatTile> createState() => _StartChatTileState();
}

class _StartChatTileState extends State<_StartChatTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          constraints: const BoxConstraints(minHeight: ConversationTile.rowHeight),
          padding: const EdgeInsets.only(
            left: AppMetrics.controlInset,
            right: AppMetrics.screenPadding,
            top: 12,
            bottom: 12,
          ),
          color: _hovered ? AppColors.surfacePressed : AppColors.transparent,
          child: Row(
            children: [
              Container(
                width: AppMetrics.avatarList,
                height: AppMetrics.avatarList,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: AppColors.accentWash, shape: BoxShape.circle),
                child: const Icon(Icons.add_comment_outlined, size: 22, color: AppColors.accent),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Start chat with ${OnionAddress.shorten(widget.onion)}',
                      style: AppTypography.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Not in your contacts yet.',
                      style: AppTypography.secondary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
