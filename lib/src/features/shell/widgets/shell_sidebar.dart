import 'dart:async';

import 'package:flutter/material.dart';

import '../../../crypto/onion_address.dart';
import '../../../design/design.dart';
import '../../chats/chats_screen.dart' show ConversationSummary;
import '../../chats/widgets/conversation_tile.dart';
import '../../chats/widgets/peer_menu.dart';

/// The left column of [DesktopShell]: everything the account can open, and the
/// account itself.
///
/// It is public and takes the same values the mobile [ChatsScreen] does rather
/// than reading an app-level store, so it can be pumped on its own in a widget
/// test and so the shell stays a pure layout. Filtering happens here because the
/// list is already in memory: a round trip to the data layer for a keystroke
/// would make typing feel slower for no gain, and [ConversationSummary] carries
/// exactly the two fields the query is matched against.
class ShellSidebar extends StatefulWidget {
  const ShellSidebar({
    required this.conversations,
    required this.selectedPeerOnion,
    required this.onSelectConversation,
    required this.onAddContact,
    required this.onOpenSettings,
    this.onStartChatWith,
    this.onOpenSelfProfile,
    this.onOpenContactProfile,
    this.displayName = 'DarkFlow',
    this.selfInitial = '?',
    this.selfAvatarPath,
    this.searchHint = 'Search…',
    super.key,
  });

  /// The threads to show, in the order the app layer decided (pinned first,
  /// then by recency). The sidebar never reorders them.
  final List<ConversationSummary> conversations;

  /// The open thread, highlighted so the two panes stay visibly linked. Null
  /// means nothing is open and no row is highlighted.
  final String? selectedPeerOnion;

  final void Function(String peerOnion) onSelectConversation;
  final VoidCallback onAddContact;
  final VoidCallback onOpenSettings;

  /// Starts a thread with an address that is not a conversation yet. The
  /// "start chat" row is not rendered at all when this is null, because a
  /// control that cannot act would be worse than no control.
  final Future<void> Function(String onionAddress)? onStartChatWith;

  /// Opens the account's own profile. Null hides the affordance rather than
  /// leaving a dead avatar behind.
  final VoidCallback? onOpenSelfProfile;

  /// Opens the peer's profile from a long press or a right click on its row.
  ///
  /// The phone layout's list offers the same menu through the same tile; a
  /// management action that existed only here would be missing on a phone, which
  /// is what happened to settings and to the account profile before.
  final void Function(String peerOnion)? onOpenContactProfile;

  final String displayName;

  /// The account's own initial, shown in the header avatar.
  final String selfInitial;

  final String? selfAvatarPath;
  final String searchHint;

  /// The measured height of the header and the bottom bar. Both are fixed: the
  /// text inside them is a single 16 pt line, which still fits at a 1.5 text
  /// scale, so the bars cannot grow and cannot overflow.
  static const double _headerHeight = 56;
  static const double _searchRowHeight = 36;

  /// Gap under the search pill, before the first row of the list.
  static const double _searchRowBottomGap = 8;

  /// The pill is fully rounded, so its radius is half its height.
  static const double _searchRadius = _searchRowHeight / 2;

  @override
  State<ShellSidebar> createState() => _ShellSidebarState();
}

class _ShellSidebarState extends State<ShellSidebar> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  String get _trimmedQuery => _query.text.trim();

  /// The address the "start chat" row offers, or null when there is nothing to
  /// offer.
  ///
  /// A whole onion address is the one search that DarkFlow can act on: there is
  /// no directory to look a name up in, so anything shorter is only ever a
  /// filter. [OnionAddress.normalise] is tried as a second chance so a pasted
  /// `https://…` or uppercase address still resolves to the same thread instead
  /// of silently filtering to nothing.
  String? get _startChatAddress {
    if (widget.onStartChatWith == null) return null;
    final text = _trimmedQuery;
    if (text.isEmpty) return null;
    final candidate = OnionAddress.isValid(text)
        ? text.toLowerCase()
        : OnionAddress.isValid(OnionAddress.normalise(text))
            ? OnionAddress.normalise(text)
            : null;
    if (candidate == null) return null;
    final known = widget.conversations.any((ConversationSummary c) => c.peerOnion == candidate);
    return known ? null : candidate;
  }

  /// Case-insensitive match on the name, the address and the last message.
  ///
  /// The address is the important one. DarkFlow's usernames *are* onion
  /// addresses, so pasting an address is the main lookup anyone attempts — and
  /// the sidebar did not match on it, so pasting a saved contact's own address
  /// produced "No conversations match …", which was not a vague answer but a
  /// false one: exactly that conversation existed. The phone list matched on
  /// `peerOnion`, so the two layouts disagreed about what a search finds.
  List<ConversationSummary> get _visible {
    final query = _trimmedQuery.toLowerCase();
    if (query.isEmpty) return widget.conversations;
    return widget.conversations
        .where(
          (ConversationSummary c) =>
              c.displayName.toLowerCase().contains(query) ||
              c.peerOnion.toLowerCase().contains(query) ||
              c.lastMessagePreview.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  void _clearQuery() {
    _query.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final offer = _startChatAddress;
    final visible = _visible;
    // The offer is a row of the list rather than a floating banner, so it
    // scrolls away with the result it belongs to and cannot cover the rows.
    final offset = offer == null ? 0 : 1;

    // The list itself sits on the canvas; only the header, the search strip and
    // the bottom bar are lifted to a surface, which is what separates them from
    // the rows. Material is still present so the text in here inherits a
    // default style even when the sidebar is pumped without a Scaffold.
    return Material(
      color: AppColors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(),
          _buildSearchRow(),
          Expanded(
            child: visible.isEmpty && offer == null
                ? (widget.conversations.isEmpty ? const _SidebarEmptyState() : _noMatches())
                : ListView.builder(
                    padding: EdgeInsets.zero,
                    // No `itemExtent`. It pinned every row to exactly 72 pt, while
                    // `ConversationTile` documents 72 as a *minimum* precisely so a
                    // large accessibility text scale grows the row instead of
                    // clipping it — and a fixed extent hands each item a tight
                    // height. The tile already needs very nearly the whole 72 pt at
                    // the default text scale, so any scale above 1.0 produced a
                    // RenderFlex overflow and cut-off names in the sidebar. The
                    // phone list never had this constraint.
                    itemCount: visible.length + offset,
                    itemBuilder: (BuildContext context, int index) {
                      if (offer != null && index == 0) {
                        return _StartChatRow(
                          address: offer,
                          onTap: () => widget.onStartChatWith!(offer),
                        );
                      }
                      final summary = visible[index - offset];
                      final selected = summary.peerOnion == widget.selectedPeerOnion;
                      final openProfile = widget.onOpenContactProfile;
                      return ColoredBox(
                        // The wash sits behind the row rather than inside it so
                        // the tile keeps its own hover treatment unchanged.
                        color: selected ? AppColors.accentWash : AppColors.transparent,
                        child: ConversationTile(
                          displayName: summary.displayName,
                          avatarPath: summary.avatarPath,
                          online: summary.online,
                          preview: summary.lastMessagePreview,
                          lastMessageAt: summary.lastMessageAt,
                          unreadCount: summary.unreadCount,
                          muted: summary.muted,
                          pinned: summary.pinned,
                          onTap: () => widget.onSelectConversation(summary.peerOnion),
                          onMenuRequested: openProfile == null
                              ? null
                              : (Offset position) => unawaited(
                                    showPeerMenu(
                                      context,
                                      position: position,
                                      actions: <PeerMenuAction>[
                                        PeerMenuAction(
                                          label: 'Contact profile',
                                          onChosen: () =>
                                              openProfile(summary.peerOnion),
                                        ),
                                      ],
                                    ),
                                  ),
                        ),
                      );
                    },
                  ),
          ),
          _buildBottomBar(),
        ],
      ),
    );
  }

  /// The avatar, the wordmark and the way into settings.
  Widget _buildHeader() {
    final profile = widget.onOpenSelfProfile;

    return Container(
      height: ShellSidebar._headerHeight,
      color: AppColors.surface,
      child: Row(
        children: [
          const SizedBox(width: 12),
          Tooltip(
            message: 'My profile',
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // 32 pt rather than a list avatar: the header is 56 pt tall and
                // a larger disc would crowd the wordmark beside it.
                onTap: profile,
                child: AppAvatar(
                  name: widget.selfInitial,
                  size: AppMetrics.avatarSmall,
                  imagePath: widget.selfAvatarPath,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.displayName,
              style: AppTypography.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: widget.onOpenSettings,
            icon: const Icon(Icons.settings_outlined, size: 20),
            color: AppColors.textSecondary,
            tooltip: 'Settings',
            splashRadius: 20,
            // Material's default button is 48 pt wide with a 48 pt tap target;
            // compact density keeps the whole header inside its 56 pt.
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  /// The pill that filters the list.
  Widget _buildSearchRow() {
    return Container(
      // The row is taller than the pill so there is breathing room under it.
      // With the divider drawn inside the same box, the previous layout put the
      // list flush against the search field, which read as cramped.
      height: ShellSidebar._searchRowHeight + ShellSidebar._searchRowBottomGap,
      padding: const EdgeInsets.only(bottom: 1),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.divider, width: 1)),
      ),
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, ShellSidebar._searchRowBottomGap),
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(ShellSidebar._searchRadius),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const Icon(Icons.search, size: 18, color: AppColors.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _query,
                onChanged: (String _) => setState(() {}),
                cursorColor: AppColors.accent,
                style: AppTypography.input,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: widget.searchHint,
                  hintStyle: AppTypography.placeholder,
                ),
              ),
            ),
            if (_query.text.isNotEmpty)
              // An [IconButton] because a bare gesture detector would not claim
              // the cursor or react to a pointer at all.
              IconButton(
                onPressed: _clearQuery,
                icon: const Icon(Icons.close, size: 18),
                color: AppColors.textSecondary,
                tooltip: 'Clear search',
                splashRadius: 16,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                padding: EdgeInsets.zero,
              ),
          ],
        ),
      ),
    );
  }

  /// The persistent way to add someone, kept out of the list so it is reachable
  /// even when a search has filtered everything away.
  Widget _buildBottomBar() {
    return Container(
      height: ShellSidebar._headerHeight,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.divider, width: 1)),
      ),
      child: _SidebarActionRow(
        icon: Icons.person_add_alt,
        label: 'Add contact',
        onTap: widget.onAddContact,
      ),
    );
  }

  Widget _noMatches() {
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
}

/// The state shown before the account has a single thread.
///
/// It is compact on purpose: the header and the bottom bar stay put, so the
/// empty state only has to explain itself, not offer the action "Add contact"
/// a second time.
class _SidebarEmptyState extends StatelessWidget {
  const _SidebarEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: Padding(
          padding: const EdgeInsets.all(AppMetrics.screenPadding),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.forum_outlined,
                size: 40,
                color: AppColors.textSecondary.withValues(alpha: 0.4),
              ),
              const SizedBox(height: AppMetrics.gap),
              const Text(
                'No conversations yet',
                style: AppTypography.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              const Text(
                'Add someone by their .onion address to start.',
                style: AppTypography.secondary,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The row that turns a pasted address into a thread.
///
/// It is the same height as a conversation row so the list does not visibly
/// shift as it appears and disappears while the address is being typed.
class _StartChatRow extends StatelessWidget {
  const _StartChatRow({required this.address, required this.onTap});

  final String address;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _SidebarHoverRow(
      onTap: onTap,
      builder: (BuildContext context, bool hovered) {
        return Container(
          constraints: const BoxConstraints(minHeight: ConversationTile.rowHeight),
          color: hovered ? AppColors.surfacePressed : AppColors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Row(
            children: [
              Container(
                width: AppMetrics.avatarList,
                height: AppMetrics.avatarList,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: AppColors.accentWash,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.add_comment_outlined, size: 22, color: AppColors.accent),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Text(
                  'Start chat with ${OnionAddress.shorten(address)}',
                  style: AppTypography.title.copyWith(color: AppColors.accent),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The full-width "Add contact" control in the bottom bar.
class _SidebarActionRow extends StatelessWidget {
  const _SidebarActionRow({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _SidebarHoverRow(
      onTap: onTap,
      builder: (BuildContext context, bool hovered) {
        return Container(
          color: hovered ? AppColors.surfacePressed : AppColors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: AppColors.textPrimary),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  label,
                  style: AppTypography.bodyStrong,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A row that reacts to a pointer: it claims the click cursor, tracks hover and
/// hands the state to [builder].
///
/// It exists so that every clickable strip in the sidebar behaves identically;
/// the alternative is the same two [setState] calls copied into three widgets,
/// which is how one of them eventually ends up without a cursor.
class _SidebarHoverRow extends StatefulWidget {
  const _SidebarHoverRow({required this.onTap, required this.builder});

  final VoidCallback onTap;
  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<_SidebarHoverRow> createState() => _SidebarHoverRowState();
}

class _SidebarHoverRowState extends State<_SidebarHoverRow> {
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
        child: widget.builder(context, _hovered),
      ),
    );
  }
}
