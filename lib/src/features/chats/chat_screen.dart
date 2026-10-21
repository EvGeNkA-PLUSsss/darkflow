import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/message.dart';
import '../../design/design.dart';
import 'widgets/attachment_bubble.dart';
import 'widgets/chat_composer.dart';
import 'widgets/day_separator.dart';
import 'widgets/message_bubble.dart';
import 'widgets/voice_message_bubble.dart';

/// What the menu on a message offers.
///
/// An enum rather than a string, so a menu that grows cannot send a value the receiver
/// does not know about — the failure a string key produces is a silent no-op on a tap,
/// which is exactly the class of bug that is hardest to notice.
enum _MessageAction {
  reply('Reply'),
  copy('Copy text'),
  openAttachment('Open'),
  saveAttachment('Save forever');

  const _MessageAction(this.label);

  final String label;
}

/// One conversation.
///
/// The screen is presentational: messages, attachments and every action arrive
/// through the constructor, so it can be rendered with a plain list in a widget
/// test and the app layer stays free to wire storage, Tor and the recorder
/// later. The only thing it owns is scrolling.
///
/// Layout follows `Chat.svg`: every message — incoming and outgoing — is
/// left-aligned, the sender's 38 pt avatar sits at x = 14 and the bubble starts
/// at x = 69.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    required this.peerName,
    required this.messages,
    required this.onSend,
    required this.onAttach,
    this.onBack,
    this.peerOnion = '',
    this.peerAvatarPath,
    this.peerOnline = false,
    this.attachments = const <String, Attachment>{},
    this.attachmentPreviews = const <String, Widget>{},
    this.onRetry,
    this.onReply,
    this.onCall,
    this.onOpenAttachment,
    this.onStartVoice,
    this.onStopVoice,
    this.onToggleVoicePlayback,
    this.playingAttachmentId,
    this.voiceProgress,
    this.busy = false,
    this.selfName = 'Me',
    this.selfAvatarPath,
    this.onDraftChanged,
    this.onSendFailed,
    this.initialDraft = '',
    this.sending = false,
    this.onOpenPeerProfile,
    this.isSelf,
    this.onCopied,
    this.onOpenAttachmentAction,
    this.onSaveAttachment,
    super.key,
  });

  /// The peer's display name, shown in the top bar and used for the avatar.
  final String peerName;

  /// Oldest first. The list is not re-sorted: the app layer owns the order.
  final List<Message> messages;

  final bool Function(String text, String? replyToId) onSend;
  final VoidCallback onAttach;

  /// Reports a send that the app layer refused. Null leaves the composer silent.
  final ValueChanged<String>? onSendFailed;

  /// Leaves the conversation. Null when the screen is embedded in the desktop
  /// two-pane layout, where there is nothing to go back to — the list is
  /// already beside it — so no arrow is drawn.
  final VoidCallback? onBack;

  final String peerOnion;
  final String? peerAvatarPath;

  /// Drives the presence line, which is accent-coloured while true.
  final bool peerOnline;

  /// Attachment metadata keyed by [Attachment.id]; a message with an
  /// [Message.attachmentId] that is missing here renders as its preview text
  /// instead of an empty slot, which is the honest state before a transfer has
  /// started.
  final Map<String, Attachment> attachments;

  /// Rendered previews keyed by [Attachment.id], built by the app layer because
  /// turning decrypted bytes into an image needs `dart:io`.
  final Map<String, Widget> attachmentPreviews;

  /// Re-sends a failed message; [MessageBubble] routes taps to it.
  final void Function(Message message)? onRetry;

  /// Starts a reply. Bound to double-tap, as in every other messenger, because a
  /// single tap belongs to scrolling.
  final void Function(Message message)? onReply;

  /// Reports that something was put on the clipboard, so the app layer can say so.
  final ValueChanged<String>? onCopied;

  /// Opens a message's file with the system handler. Null hides the action.
  final void Function(Message message)? onOpenAttachmentAction;

  /// Writes a decrypted copy of a message's file somewhere the user chooses.
  final void Function(Message message)? onSaveAttachment;
  /// Starts a call. The action is not rendered at all when this is null, so
  /// there is never a button that cannot do anything.
  final VoidCallback? onCall;

  final void Function(Attachment attachment)? onOpenAttachment;

  /// Press-and-hold on the microphone.
  /// Starts a recording, returning false when the platform refused.
  ///
  /// The result is not optional: the composer uses it to decide whether to show
  /// the recording state or explain that the microphone was unavailable.
  final Future<bool> Function()? onStartVoice;

  /// Release, or the stop control, ends the note.
  final VoidCallback? onStopVoice;

  /// Play or pause a voice note. The screen never touches a player.
  final void Function(String attachmentId)? onToggleVoicePlayback;

  /// Which voice note is currently playing, if any.
  final String? playingAttachmentId;

  /// Playback position of [playingAttachmentId], 0..1.
  final double? voiceProgress;

  /// True while a send is in flight.
  final bool busy;

  /// The account's own name, used for the avatar on outgoing messages. The
  /// mockup shows "M" for the user, so the default initial matches it.
  final String selfName;
  final String? selfAvatarPath;

  /// Mirrors the composer draft to the app layer so it can be persisted.
  final ValueChanged<String>? onDraftChanged;

  /// The draft to restore into the composer, from the previous session.
  final String initialDraft;

  /// True while a file is being encrypted into the vault, so the composer can
  /// say so instead of appearing to have ignored the tap.
  final bool sending;

  /// Opens the peer's profile from the top bar. Not rendered when null, so no
  /// part of the bar is tappable without it.
  ///
  /// The chat screen is used by both layouts — pushed on a phone, embedded in the
  /// desktop pane — so putting the way into the profile here is what makes it
  /// reachable on both, and the profile itself is where a contact is managed.
  final VoidCallback? onOpenPeerProfile;

  /// Reserved for the app layer's "is this me?" predicate. The presentational
  /// layer answers that from [Message.direction], so it is ignored here.
  final bool Function(String peerOnion)? isSelf;

  /// Horizontal inset of a message row, from the mockup's avatar at x = 14.
  static const double _rowInset = 14;

  /// Identifies the in-conversation search field.
  ///
  /// A key rather than a search by hint text, because the composer's field is on
  /// screen at the same time and a finder for "a TextField" then matches two.
  static const Key searchFieldKey = Key('chat-search-field');

  /// Distance from the avatar's right edge to the bubble: 52 + 17 = 69.
  static const double _avatarGap = 17;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  /// The message the next send will answer, if any.
  ///
  /// The reply target lives here rather than in the composer because the gesture
  /// that sets it is on a *message bubble*, further up this same widget, and the
  /// two have to agree. It used to live nowhere: double-tapping a bubble copied
  /// its text to the clipboard, `Message.replyToId` was written by nobody, and
  /// the quote-rendering code in `MessageBubble` could never be reached.
  Message? _replyTo;

  /// The current in-conversation search term. Empty means "show everything".
  String _query = '';
  bool _searching = false;
  final TextEditingController _searchField = TextEditingController();

  /// Spacing inside one sender's group. The mockup uses roughly 22 pt, which
  /// reads as a gap rather than a group on a real device; 12 pt keeps a run of
  /// messages together and 18 pt marks the breaks.
  static const double _groupGap = 12;

  /// Spacing between senders, and after anything with an attachment.
  static const double _blockGap = 18;

  ChatScreen get _w => widget;

  @override
  void dispose() {
    _searchField.dispose();
    super.dispose();
  }

  /// The messages the list should show.
  ///
  /// Filtering happens here rather than in the app layer because it is a view
  /// concern: the thread is already in memory, the term never leaves the device,
  /// and the app layer owns the *order* of the thread, which this must not touch.
  List<Message> get _shown {
    final needle = _query.trim().toLowerCase();
    if (needle.isEmpty) return _w.messages;
    return <Message>[
      for (final message in _w.messages)
        if (message.body.toLowerCase().contains(needle) ||
            message.preview.toLowerCase().contains(needle))
          message,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final messages = _shown;
    // Built from the whole thread, not the filtered view, so a reply to a message
    // that the search filtered out still resolves its quote.
    final byId = <String, Message>{
      for (final message in _w.messages) message.id: message,
    };

    // The avatar and the name are one target: they say the same thing about who
    // this conversation is with, and the profile they open is where that contact
    // is renamed or deleted. Without the callback neither is tappable, so a
    // screen that cannot open a profile does not look like it can.
    final openProfile = _w.onOpenPeerProfile;
    final identity = Row(
      children: <Widget>[
        AppAvatar(
          name: _w.peerName,
          size: AppMetrics.avatarChat,
          imagePath: _w.peerAvatarPath,
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                _w.peerName,
                style: AppTypography.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                _w.peerOnline ? 'Online' : 'Offline',
                style: AppTypography.caption.copyWith(
                  color: _w.peerOnline ? AppColors.online : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    // The composer's view of what is being answered. A quote whose original is
    // not loaded is dropped rather than shown with invented text.
    final replyTarget = _replyTo;
    final reply = replyTarget == null || !byId.containsKey(replyTarget.id)
        ? null
        : ComposerReply(
            id: replyTarget.id,
            author: replyTarget.isOutgoing ? _w.selfName : _w.peerName,
            text: replyTarget.body.isNotEmpty ? replyTarget.body : replyTarget.preview,
          );

    return AppScaffold(
      // The composer applies the keyboard inset itself, so the scaffold must not
      // shrink the body as well or the inset would be counted twice.
      resizeToAvoidBottomInset: false,
      appBar: ChatAppBar(
        title: _w.peerName,
        onBack: _w.onBack,
        // Handed a whole header rather than an avatar and a title, because the
        // two have to travel together into one tap target, and `ChatAppBar`
        // cannot wrap them itself without knowing whether they are tappable.
        header: openProfile == null
            ? null
            : MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: openProfile,
                  child: identity,
                ),
              ),
        actions: [
          // Local search over this conversation.
          //
          // A thread in this app is meant to live for years and there is no server
          // to ask, so the only way to find "the address they sent me in March" is
          // the copy already on the device. The magnifier is offered only when
          // there is something to search, so no button is ever dead.
          if (_w.messages.isNotEmpty)
            IconButton(
              onPressed: () => setState(() {
                _searching = !_searching;
                if (!_searching) {
                  _query = '';
                  _searchField.clear();
                }
              }),
              icon: Icon(_searching ? Icons.search_off : Icons.search, size: 22),
              color: AppColors.textPrimary,
              tooltip: _searching ? 'Close search' : 'Search this conversation',
            ),
          // A visible way into the contact's profile.
          //
          // Tapping the name works and a right-click on a conversation row
          // works, but both are invisible: a user looking for "where do I rename
          // or delete this contact" has nothing to see. An overflow button is
          // the shape every messenger uses for exactly this, so it is the shape
          // people look for.
          if (openProfile != null)
            IconButton(
              onPressed: openProfile,
              icon: const Icon(Icons.more_vert, size: 22),
              color: AppColors.textPrimary,
              tooltip: 'Contact settings',
            ),
          if (_w.onCall != null) _CallAction(onCall: _w.onCall!),
        ],
      ),
      child: Column(
        children: [
          if (_searching) _buildSearchBar(),
          Expanded(
            child: messages.isEmpty && _query.trim().isNotEmpty
                ? _noMatches()
                : _MessageList(
                    // A new key per thread *and per search*, so neither the thread
                    // that was open before nor the unfiltered list carries its
                    // scroll offset into a filtered one. Reusing the state meant
                    // that opening a long conversation after a short one landed in
                    // the middle of the history with no explanation.
                    key: ValueKey<String>('${_w.peerOnion}|$_query'),
                    itemCount: messages.length,
                    itemBuilder: (BuildContext context, int index) =>
                        _buildItem(context, index, byId),
                  ),
          ),
          ChatComposer(
            onSend: (String text, String? replyToId) {
              final accepted = _w.onSend(text, replyToId);
              // The reply target is dropped only when the message was taken, so a
              // refused send leaves the composer exactly as it was.
              if (accepted && _replyTo != null) {
                setState(() => _replyTo = null);
              }
              return accepted;
            },
            onSendFailed: _w.onSendFailed,
            onAttach: _w.onAttach,
            onStartVoice: _w.onStartVoice,
            onStopVoice: _w.onStopVoice,
            onDraftChanged: _w.onDraftChanged,
            reply: reply,
            onCancelReply: reply == null ? null : () => setState(() => _replyTo = null),
            busy: _w.busy,
            sending: _w.sending,
            initialDraft: _w.initialDraft,
          ),
        ],
      ),
    );
  }

  /// Answers [message]: the composer shows the quote and the send carries the id.
  ///
  /// The app layer's own [ChatScreen.onReply] is told as well, so a host that
  /// wants to react — an unread badge, an analytics hook — can. What it must not
  /// be is a *replacement* for this, which is what it was: the whole gesture was
  /// wired to "copy the message text to the clipboard", so double-tapping a
  /// message silently put it on the clipboard and started no reply at all.
  void _startReply(Message message) {
    setState(() => _replyTo = message);
    _w.onReply?.call(message);
  }

  /// Opens the menu for [message].
  ///
  /// What a long press offers, and what a right-click offers on a desktop: reply, copy,
  /// and — when the message carries a file — open and save. Reactions were here and were
  /// removed at the user's request; what is left is the set of actions that do something
  /// the user cannot do by selecting text.
  ///
  /// The menu is a bottom sheet on a phone and a context menu on a desktop, which is what
  /// each platform's users reach for. `showMenu` is positioned at the pointer, and the
  /// position is the whole reason it exists: a menu that appears at the top of the screen
  /// when the user right-clicked near the bottom is a menu they have to hunt for.
  Future<void> _openMessageMenu(
    Message message, {
    Offset? at,
    Rect? anchor,
  }) async {
    final attachment = _attachmentFor(message);
    final canOpen = attachment != null;

    final chosen = at != null
        ? await _showPointerMenu(
            message,
            at: at,
            attachment: attachment,
            canOpen: canOpen,
          )
        : await _showSheetMenu(
            message,
            attachment: attachment,
            canOpen: canOpen,
          );
    if (!mounted || chosen == null) return;

    switch (chosen) {
      case _MessageAction.reply:
        _startReply(message);
      case _MessageAction.copy:
        // Copied here rather than handed up: the screen owns the text, and a round trip
        // through the app layer would only be a longer way to reach the clipboard. A
        // message with no text — a voice note, a bare file — has nothing to copy, and the
        // action is not offered for one.
        await Clipboard.setData(ClipboardData(text: message.body));
        if (mounted) {
          _w.onCopied?.call('Message copied.');
        }
      case _MessageAction.openAttachment:
        _w.onOpenAttachmentAction?.call(message);
      case _MessageAction.saveAttachment:
        _w.onSaveAttachment?.call(message);
    }
  }

  /// The desktop menu, at the pointer.
  Future<_MessageAction?> _showPointerMenu(
    Message message, {
    required Offset at,
    required Attachment? attachment,
    required bool canOpen,
  }) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return null;
    final choice = await showMenu<_MessageAction>(
      context: context,
      color: AppColors.surface,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(at.dx, at.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: _menuItems(message, canOpen: canOpen),
    );
    return choice;
  }

  /// The phone menu, as a sheet.
  Future<_MessageAction?> _showSheetMenu(
    Message message, {
    required Attachment? attachment,
    required bool canOpen,
  }) async {
    return showModalBottomSheet<_MessageAction>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final entry in _menuEntries(message, canOpen: canOpen))
              ListTile(
                leading: Icon(entry.value, color: AppColors.textPrimary),
                title: Text(entry.key.label, style: AppTypography.body),
                onTap: () => Navigator.of(sheet).pop(entry.key),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// The actions that exist for this message, in the order they are offered.
  List<MapEntry<_MessageAction, IconData>> _menuEntries(
    Message message, {
    required bool canOpen,
  }) =>
      <MapEntry<_MessageAction, IconData>>[
        const MapEntry<_MessageAction, IconData>(_MessageAction.reply, Icons.reply_outlined),
        // A message with no text has nothing to copy, so the row is not drawn rather
        // than drawn and dead.
        if (message.body.trim().isNotEmpty)
          const MapEntry<_MessageAction, IconData>(_MessageAction.copy, Icons.copy_outlined),
        if (canOpen) ...<MapEntry<_MessageAction, IconData>>[
          const MapEntry<_MessageAction, IconData>(
            _MessageAction.openAttachment,
            Icons.open_in_new,
          ),
          const MapEntry<_MessageAction, IconData>(
            _MessageAction.saveAttachment,
            Icons.save_alt,
          ),
        ],
      ];

  List<PopupMenuEntry<_MessageAction>> _menuItems(
    Message message, {
    required bool canOpen,
  }) =>
      <PopupMenuEntry<_MessageAction>>[
        for (final entry in _menuEntries(message, canOpen: canOpen))
          PopupMenuItem<_MessageAction>(
            value: entry.key,
            child: Row(
              children: <Widget>[
                Icon(entry.value, size: 18, color: AppColors.textPrimary),
                const SizedBox(width: 12),
                Text(entry.key.label, style: AppTypography.body),
              ],
            ),
          ),
      ];

  /// The search strip above the list.
  Widget _buildSearchBar() {
    final shown = _shown.length;
    final total = _w.messages.length;
    final active = _query.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
      child: Container(
        height: AppMetrics.searchHeight,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppMetrics.searchHeight / 2),
        ),
        child: Row(
          children: <Widget>[
            const Icon(Icons.search, size: 18, color: AppColors.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                key: ChatScreen.searchFieldKey,
                controller: _searchField,
                autofocus: true,
                onChanged: (String value) => setState(() => _query = value),
                cursorColor: AppColors.accent,
                style: AppTypography.input,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: 'Search this conversation...',
                  hintStyle: AppTypography.placeholder,
                ),
              ),
            ),
            if (active) ...<Widget>[
              Text(
                '$shown of $total',
                style: AppTypography.caption,
              ),
              const SizedBox(width: 6),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() {
                  _query = '';
                  _searchField.clear();
                }),
                child: const SizedBox(
                  width: 28,
                  height: 28,
                  child: Icon(Icons.close, size: 16, color: AppColors.textSecondary),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// An honest answer for a search that matched nothing.
  ///
  /// Distinct from an empty thread: "you have not written here yet" and "nothing
  /// in here says that" are different facts, and showing the first for the second
  /// would be wrong.
  Widget _noMatches() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppMetrics.screenPadding),
        child: Text(
          'Nothing in this conversation matches “${_query.trim()}”.',
          style: AppTypography.secondary,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  /// One entry of the list: an optional day break, then the message row.
  Widget _buildItem(BuildContext context, int index, Map<String, Message> byId) {
    // The *shown* list, so the day break and the grouping gap describe what is
    // actually on screen: after a search, two messages an hour apart in the
    // original thread are adjacent here, and the separator has to follow.
    final messages = _shown;
    final message = messages[index];
    final previous = index > 0 ? messages[index - 1] : null;
    final newDay = previous == null || !_sameDay(previous.createdAt, message.createdAt);
    final gap = previous == null || newDay ? 0.0 : _gapAfter(previous, message);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (newDay) DaySeparator(date: message.createdAt),
        Padding(
          padding: EdgeInsets.only(top: gap, left: ChatScreen._rowInset, right: ChatScreen._rowInset),
          child: _MessageRow(
            message: message,
            attachment: _attachmentFor(message),
            preview: _previewFor(message),
            quotedText: _quotedTextFor(message, byId),
            peerName: _w.peerName,
            peerAvatarPath: _w.peerAvatarPath,
            selfName: _w.selfName,
            selfAvatarPath: _w.selfAvatarPath,
            playing: _isPlaying(message),
            voiceProgress: _w.voiceProgress,
            highlight: _query,
            onRetry: _w.onRetry,
            onReply: _w.onReply == null ? null : _startReply,
            onMenu: _openMessageMenu,
            onCopied: _w.onCopied,
            onOpenAttachmentAction: _w.onOpenAttachmentAction,
            onSaveAttachment: _w.onSaveAttachment,
            onOpenAttachment: _w.onOpenAttachment,
            onToggleVoicePlayback: _w.onToggleVoicePlayback,
          ),
        ),
      ],
    );
  }

  /// 12 pt inside a run from the same sender, 18 pt everywhere else; a run that
  /// only ended because the previous message carried a file also breaks.
  static double _gapAfter(Message previous, Message current) {
    final sameSender = previous.isOutgoing == current.isOutgoing;
    return sameSender && !previous.hasAttachment ? _groupGap : _blockGap;
  }

  static bool _sameDay(DateTime a, DateTime b) {
    final localA = a.toLocal();
    final localB = b.toLocal();
    return localA.year == localB.year && localA.month == localB.month && localA.day == localB.day;
  }
  Attachment? _attachmentFor(Message message) {
    final id = message.attachmentId;
    if (id == null) return null;
    return _w.attachments[id];
  }

  Widget? _previewFor(Message message) {
    final id = message.attachmentId;
    if (id == null) return null;
    return _w.attachmentPreviews[id];
  }

  /// The quoted body, or null when the message is not a reply or the original
  /// is not loaded — a reply box with invented text would be worse than none.
  String? _quotedTextFor(Message message, Map<String, Message> byId) {
    final id = message.replyToId;
    if (id == null) return null;
    final quoted = byId[id];
    if (quoted == null) return null;
    return quoted.body.isNotEmpty ? quoted.body : quoted.preview;
  }

  bool _isPlaying(Message message) {
    final id = message.attachmentId;
    return id != null && id == _w.playingAttachmentId;
  }
}


/// The avatar, the bubble (or bubbles) and the spacing for one message.
class _MessageRow extends StatelessWidget {
  const _MessageRow({
    required this.message,
    required this.attachment,
    required this.preview,
    required this.quotedText,
    required this.peerName,
    required this.peerAvatarPath,
    required this.selfName,
    required this.selfAvatarPath,
    required this.playing,
    required this.voiceProgress,
    required this.highlight,
    required this.onRetry,
    required this.onReply,
    required this.onMenu,
    required this.onCopied,
    required this.onOpenAttachmentAction,
    required this.onSaveAttachment,
    required this.onOpenAttachment,
    required this.onToggleVoicePlayback,
  });

  final Message message;
  final Attachment? attachment;
  final Widget? preview;
  final String? quotedText;
  final String peerName;
  final String? peerAvatarPath;
  final String selfName;
  final String? selfAvatarPath;
  final bool playing;
  final double? voiceProgress;

  /// The conversation's search term, marked inside the bubble's text.
  final String highlight;

  final void Function(Message message)? onRetry;
  final void Function(Message message)? onReply;

  /// Opens the menu for this message. Null when the host offers none.
  final void Function(Message message, {Offset? at, Rect? anchor})? onMenu;

  /// Reports that something was copied, so the app layer can say so.
  final ValueChanged<String>? onCopied;

  final void Function(Message message)? onOpenAttachmentAction;
  final void Function(Message message)? onSaveAttachment;

  final void Function(Attachment attachment)? onOpenAttachment;
  final void Function(String attachmentId)? onToggleVoicePlayback;

  @override
  Widget build(BuildContext context) {
    final outgoing = message.isOutgoing;
    final attachment = this.attachment;
    final hasBody = message.body.isNotEmpty;

    return GestureDetector(
      // Right-click, everywhere on the row — avatar, card and bubble alike. A
      // desktop user reaches for the secondary button, and offering the same menu
      // only on the bubble's own text made the gesture work on some pixels of the
      // message and not others, which reads as an unreliable feature rather than as
      // one with a narrower hit area.
      //
      // `onSecondaryTapDown` rather than `onSecondaryTap`, because the menu is placed
      // where the pointer is and that position is only in the *down* event.
      onSecondaryTapDown: onMenu == null
          ? null
          : (TapDownDetails details) => onMenu!(message, at: details.globalPosition),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAvatar(
            name: outgoing ? selfName : peerName,
            size: AppMetrics.avatarChat,
            imagePath: outgoing ? selfAvatarPath : peerAvatarPath,
          ),
          const SizedBox(width: ChatScreen._avatarGap),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (attachment != null) ...[
                  if (attachment.isVoice)
                    VoiceMessageBubble(
                      durationMs: attachment.durationMs ?? 0,
                      outgoing: outgoing,
                      waveform: attachment.waveform,
                      playing: playing,
                      // Only the note that is actually playing gets a position;
                      // the others would otherwise show someone else's progress.
                      progress: playing ? voiceProgress : null,
                      onTogglePlayback: onToggleVoicePlayback == null
                          ? null
                          : () => onToggleVoicePlayback!(attachment.id),
                    )
                  else
                    AttachmentBubble(
                      attachment: attachment,
                      outgoing: outgoing,
                      preview: preview,
                      onOpen: onOpenAttachment,
                    ),
                ],
                // A file arrives with its own card; its caption, when there is
                // one, follows it as a normal bubble.
                if (hasBody || attachment == null) ...[
                  if (attachment != null) const SizedBox(height: 6),
                  MessageBubble(
                    text: hasBody ? message.body : message.preview,
                    outgoing: outgoing,
                    status: outgoing ? message.status : null,
                    // Only for a message that has not arrived and cannot: a
                    // delivered one has nothing to explain, and the reason is
                    // cleared when the outbox finally gets it through.
                    note: outgoing &&
                            message.status != MessageStatus.delivered &&
                            message.status != MessageStatus.read
                        ? message.failureReason
                        : null,
                    quotedText: quotedText,
                    highlight: highlight,
                    onRetry: onRetry == null ? null : () => onRetry!(message),
                    onDoubleTap: onReply == null ? null : () => onReply!(message),
                    // Long-press on a phone; a right-click is caught above, which
                    // knows where the pointer was.
                    onLongPress: onMenu == null ? null : () => onMenu!(message),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The 40 pt tap target that starts a call, rendered only when a call is
/// possible.
class _CallAction extends StatelessWidget {
  const _CallAction({required this.onCall});

  final VoidCallback onCall;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onCall,
        child: const SizedBox(
          width: 40,
          height: 40,
          child: Icon(Icons.call_outlined, size: 22, color: AppColors.textPrimary),
        ),
      ),
    );
  }
}

/// The scrolling message list.
///
/// It exists so [ChatScreen] stays a plain widget composition: the controller,
/// the "follow the newest message" behaviour and the jump-to-newest affordance
/// are the only mutable bits of the screen, and keeping them here means the list
/// can be dropped into any other host unchanged.
class _MessageList extends StatefulWidget {
  const _MessageList({
    required this.itemCount,
    required this.itemBuilder,
    super.key,
  });

  final int itemCount;
  final NullableIndexedWidgetBuilder itemBuilder;

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  final ScrollController _controller = ScrollController();

  /// True while the view is close enough to the end that a new message is
  /// expected to bring itself into sight.
  bool _following = true;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    // A conversation opens on its newest message.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) => _jumpToBottom());
  }

  @override
  void didUpdateWidget(_MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.itemCount > oldWidget.itemCount) {
      // Only follow when the reader is already at the end.
      //
      // This used to scroll unconditionally, which made reading history
      // impossible in an active conversation: every arriving message pulled the
      // view back to the bottom, so scrolling up was a race the user always
      // lost. Someone who has scrolled up is reading, and their position is
      // theirs to keep — the "new messages" button below brings them back when
      // they want to be.
      if (_following) {
        WidgetsBinding.instance.addPostFrameCallback((Duration _) => _animateToBottom());
      } else {
        setState(() => _unseen = true);
      }
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  /// True while there are messages below the fold that arrived after the reader
  /// scrolled away.
  bool _unseen = false;

  /// How far from the end still counts as "at the end".
  static const double _followSlack = 80;

  void _onScroll() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    if (!position.hasContentDimensions) return;
    final distance = position.maxScrollExtent - position.pixels;
    final following = distance <= _followSlack;
    if (following == _following && !(following && _unseen)) return;
    setState(() {
      _following = following;
      if (following) _unseen = false;
    });
  }

  void _jumpToBottom() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    if (!position.hasContentDimensions) return;
    _controller.jumpTo(position.maxScrollExtent);
  }

  void _animateToBottom() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    if (!position.hasContentDimensions) return;
    _controller.animateTo(
      position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ListView.builder(
          controller: _controller,
          padding: const EdgeInsets.only(top: 8, bottom: 12),
          itemCount: widget.itemCount,
          itemBuilder: widget.itemBuilder,
        ),
        if (_unseen)
          Positioned(
            right: 16,
            bottom: 12,
            child: _NewMessagesButton(
              onTap: () {
                setState(() {
                  _unseen = false;
                  _following = true;
                });
                _animateToBottom();
              },
            ),
          ),
      ],
    );
  }
}

/// The pill that returns the reader to the newest message.
///
/// It exists because the list deliberately stops following once the reader
/// scrolls up, and a list that stops following with nothing on screen saying so
/// looks broken. Naming the action is what makes the behaviour a choice rather
/// than a bug.
class _NewMessagesButton extends StatelessWidget {
  const _NewMessagesButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.accent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.arrow_downward, size: 16, color: AppColors.textOnAccent),
              const SizedBox(width: 6),
              Text(
                'New messages',
                style: AppTypography.caption.copyWith(
                  color: AppColors.textOnAccent,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}