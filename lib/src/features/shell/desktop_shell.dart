import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/design.dart';
import '../chats/chats_screen.dart' show ConversationSummary;
import 'widgets/shell_sidebar.dart';

/// The desktop window once the account is unlocked: the conversation list
/// pinned on the left, the open conversation filling the rest.
///
/// The mobile build pushes a route for a thread because a 390 pt canvas cannot
/// hold two panes; above [AppMetrics.twoPaneBreakpoint] that push is what makes
/// a desktop app feel like a phone, so this widget replaces it. It is the
/// caller's job to choose between the two and to place this inside a
/// [Scaffold] — the shell deliberately has no [Scaffold] of its own, so the
/// conversation pane keeps the background, app bar and insets it already sets.
///
/// The two panes are separated by a single hairline rather than a card edge,
/// which is the convention every desktop messenger shares and the reason the
/// selected row is tinted instead of outlined.
class DesktopShell extends StatelessWidget {
  const DesktopShell({
    required this.conversations,
    required this.selectedPeerOnion,
    required this.onSelectConversation,
    required this.onAddContact,
    required this.onOpenSettings,
    required this.conversationPane,
    this.onStartChatWith,
    this.onOpenSelfProfile,
    this.onOpenContactProfile,
    this.onClearSelection,
    this.displayName = 'DarkFlow',
    this.selfInitial = '?',
    this.selfAvatarPath,
    this.searchHint = 'Search…',
    this.emptyTitle = 'Select a conversation',
    this.emptyMessage = 'Pick a chat on the left, or start a new one with an .onion address.',
    super.key,
  });

  /// The threads shown in the left pane, already ordered by the app layer.
  final List<ConversationSummary> conversations;

  /// The open thread, highlighted on the left. Null means nothing is open and
  /// [conversationPane] is expected to be null too.
  final String? selectedPeerOnion;

  final void Function(String peerOnion) onSelectConversation;
  final VoidCallback onAddContact;
  final VoidCallback onOpenSettings;

  /// The right-hand side: the open conversation, or null when there is none, in
  /// which case the shell fills the pane with [NoConversationSelected] so a
  /// half-empty window never looks broken.
  final Widget? conversationPane;

  final Future<void> Function(String onionAddress)? onStartChatWith;
  final VoidCallback? onOpenSelfProfile;

  /// Opens a peer's profile from a long press or a right click on its row.
  ///
  /// Forwarded to the sidebar, which owns the rows. The phone layout offers the
  /// same menu from `ChatsScreen`; both are wired from the same place in the app
  /// layer so neither can be left out.
  final void Function(String peerOnion)? onOpenContactProfile;

  /// Called when the user presses Escape. Optional because "close the pane" is
  /// the caller's decision: an unsent draft may have to be confirmed first, and
  /// a shell that silently dropped it would be lying about having saved it.
  final VoidCallback? onClearSelection;

  final String displayName;
  final String selfInitial;
  final String? selfAvatarPath;
  final String searchHint;
  final String emptyTitle;
  final String emptyMessage;

  /// The hairline between the panes. One logical pixel, not a divider widget,
  /// so it cannot pick up a theme's thickness.
  static const double _dividerWidth = 1;

  @override
  Widget build(BuildContext context) {
    final clearSelection = onClearSelection;

    final content = SafeArea(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A fixed width, not a fraction: a list that reflows as the window
          // grows makes names truncate differently at every size, and every
          // desktop messenger keeps this column put for the same reason.
          SizedBox(
            width: AppMetrics.masterPaneWidth,
            child: ShellSidebar(
              conversations: conversations,
              selectedPeerOnion: selectedPeerOnion,
              onSelectConversation: onSelectConversation,
              onAddContact: onAddContact,
              onOpenSettings: onOpenSettings,
              onStartChatWith: onStartChatWith,
              onOpenSelfProfile: onOpenSelfProfile,
              onOpenContactProfile: onOpenContactProfile,
              displayName: displayName,
              selfInitial: selfInitial,
              selfAvatarPath: selfAvatarPath,
              searchHint: searchHint,
            ),
          ),
          const SizedBox(
            width: _dividerWidth,
            child: ColoredBox(color: AppColors.divider),
          ),
          Expanded(
            child: conversationPane ??
                NoConversationSelected(
                  title: emptyTitle,
                  message: emptyMessage,
                  onAddContact: onAddContact,
                ),
          ),
        ],
      ),
    );

    if (clearSelection == null) {
      return ColoredBox(color: AppColors.background, child: content);
    }

    // Escape is bound only while there is a handler for it, so the shell never
    // advertises a keyboard shortcut the app would ignore. The [Focus] above
    // the panes is the one widget guaranteed to sit on the path from whatever
    // is focused inside them up to the root: since it never asks for focus
    // itself, it leaves autofocus to the sidebar's search field and to the
    // composer, and merely observes the key on the way past.
    return ColoredBox(
      color: AppColors.background,
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.escape): _ClearSelectionIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _ClearSelectionIntent: CallbackAction<_ClearSelectionIntent>(
              onInvoke: (_) {
                clearSelection();
                return null;
              },
            ),
          },
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            child: content,
          ),
        ),
      ),
    );
  }
}

/// The Escape intent. A named type rather than [VoidCallbackIntent] so the
/// shell's own binding cannot be shadowed by, or shadow, any other Escape
/// handler a screen decides to install further down.
class _ClearSelectionIntent extends Intent {
  const _ClearSelectionIntent();
}

/// The right pane when nothing is open.
///
/// It is not a "loading" or "error" state, so it does not apologise: it states
/// the two things the user can do next, and the button is the one action that
/// is possible without an existing thread.
class NoConversationSelected extends StatelessWidget {
  const NoConversationSelected({
    required this.title,
    required this.message,
    required this.onAddContact,
    super.key,
  });

  final String title;
  final String message;
  final VoidCallback onAddContact;

  /// The width at which the copy stops growing. A measure far past this forces
  /// the eye to travel the whole width of a 2560 pt monitor for one sentence.
  static const double _maxTextWidth = 360;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxTextWidth),
        child: Padding(
          padding: const EdgeInsets.all(AppMetrics.screenPadding),
          // The column fills the pane and centres its children instead of
          // shrinking to them, so a short window squeezes nothing: every text
          // is capped and ellipsised, and the fixed parts are one 56 pt icon
          // and one 56 pt button.
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.forum_outlined,
                size: 56,
                color: AppColors.textSecondary.withValues(alpha: 0.3),
              ),
              const SizedBox(height: AppMetrics.gap),
              Text(
                title,
                style: AppTypography.h2,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 10),
              Text(
                message,
                style: AppTypography.secondary,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 24),
              // A fixed width rather than a hug: the label is a fixed string,
              // and pinning it keeps the button from resizing if the copy above
              // ever changes length.
              SizedBox(
                width: 220,
                child: SecondaryButton(label: 'Add contact', onPressed: onAddContact),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
