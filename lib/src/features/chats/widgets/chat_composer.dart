import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design/design.dart';

/// What the composer is replying to, as the composer needs to draw it.
///
/// A small value type rather than a `Message`, because the bar shows the author
/// and one line of text and the composer has no business knowing the rest of the
/// model. Passing the whole message would also invite it to start reading fields
/// it does not draw.
class ComposerReply {
  const ComposerReply({required this.id, required this.author, required this.text});

  /// The id of the message being answered, sent with the reply so the peer can
  /// draw the same quote. The composer only ever passes it back, never reads it.
  final String id;

  /// "You" for the account's own messages, otherwise the peer's name.
  final String author;

  /// One line of the quoted body.
  final String text;
}

/// The bar pinned to the bottom of a conversation.
///
/// This is the only widget in the feature that owns transient input state — the
/// draft, the reply target and the recording stopwatch — so it is stateful. It
/// still performs no I/O: sending, attaching and recording arrive as callbacks,
/// which keeps the composer usable in a widget test and lets the app layer own
/// the recorder.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    required this.onSend,
    required this.onAttach,
    this.onStartVoice,
    this.onStopVoice,
    this.onDraftChanged,
    this.onSendFailed,
    this.reply,
    this.onCancelReply,
    this.busy = false,
    this.sending = false,
    this.enabled = true,
    this.autofocus = false,
    this.initialDraft = '',
    this.controller,
    super.key,
  });

  /// Called with the trimmed text, and the id of the message being replied to
  /// when there is one.
  ///
  /// Returns true when the message was accepted by the app layer. The composer
  /// clears itself and drops the reply target only then: clearing the field for a
  /// message that was thrown away is how a user's words disappeared without a
  /// trace, leaving a thread that looked as though nothing had been typed.
  final bool Function(String text, String? replyToId) onSend;

  /// Reports something the user has to know about, e.g. that the text was refused.
  ///
  /// Null leaves the composer silent, which is correct for a host that has
  /// nowhere to show a message.
  final ValueChanged<String>? onSendFailed;

  /// Opens the file picker. Doubles as the microphone's action on devices
  /// without a recorder, so the control is never dead.
  final VoidCallback onAttach;

  /// Press-and-hold starts a voice note. When null the microphone falls back to
  /// [onAttach].
  ///
  /// Begins a recording. Returns false when the platform refused — no
  /// permission, no input device, or a recorder failure — so this screen can
  /// say so instead of leaving the button looking dead.
  final Future<bool> Function()? onStartVoice;

  /// Release (or the stop control) ends the note.
  final VoidCallback? onStopVoice;

  /// Mirrors the draft so the app layer can persist it per conversation.
  final ValueChanged<String>? onDraftChanged;

  /// The message being replied to, or null. Drawn as a bar above the pill.
  final ComposerReply? reply;

  /// Clears the reply target. Null leaves the bar with no dismiss control.
  final VoidCallback? onCancelReply;

  /// True while a send is in flight; the send glyph becomes a spinner.
  final bool busy;

  /// True while a file transfer is being written to the vault.
  ///
  /// Deliberately not the same flag as [busy]. Picking a large file used to be
  /// completely silent: the picker closed, nothing appeared, and the encryption
  /// of a multi-megabyte attachment on a pure-Dart AES-GCM runs at roughly
  /// 14 MiB/s, so the app looked frozen for as long as it took.
  final bool sending;

  final bool enabled;
  final bool autofocus;

  /// Text the field starts with, e.g. a draft restored from the previous
  /// session. Ignored when [controller] is given, since that already holds it.
  final String initialDraft;

  /// An externally owned controller, e.g. one already holding a restored draft.
  /// The composer creates and disposes its own when this is null.
  final TextEditingController? controller;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  late final TextEditingController _controller;
  late final bool _ownsController;
  final FocusNode _focusNode = FocusNode();

  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  /// True while this screen believes a recording is running.
  ///
  /// The composer is the only owner of this flag. It used to be duplicated: the
  /// widget had a `recording` field that no caller ever set, and a private
  /// `_recording` that the UI actually read. Two flags for one fact, and the one
  /// the stopwatch watched was the one that was always false — so the recording
  /// indicator showed `00:00` for the whole note and never moved.
  bool _recording = false;

  /// True between a tap on the microphone and the platform's answer, so a second
  /// tap cannot start a second recorder. Starting is asynchronous — the
  /// permission check is a platform call — and without this guard two quick taps
  /// both passed the `_recording` test and both opened the microphone.
  bool _startingRecording = false;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? TextEditingController(text: widget.initialDraft);
    // Repaints the send/microphone swap when the draft changes, including when
    // the app layer sets the text from outside this widget.
    _controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A draft restored after this widget was built — which is what happens when
    // the thread's history is loaded asynchronously — has to reach the field, or
    // the composer stays empty and the saved text reappears only on the next
    // open. Only when the field is untouched, so a half-typed message is never
    // overwritten.
    if (!identical(oldWidget.initialDraft, widget.initialDraft) &&
        widget.initialDraft.isNotEmpty &&
        _controller.text.isEmpty) {
      _controller.text = widget.initialDraft;
    }
  }

  @override
  void dispose() {
    _stopTicker();
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    // Every keystroke, so a draft survives closing the thread or the app. The
    // app layer writes it without awaiting, so this stays cheap.
    widget.onDraftChanged?.call(_controller.text);
  }

  /// Counts up while a note is being recorded, so the elapsed time is never
  /// stale and never needs a second callback to update it.
  void _startTicker() {
    _elapsed = Duration.zero;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (Timer _) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
    _elapsed = Duration.zero;
  }

  bool get _hasText => _controller.text.trim().isNotEmpty;

  void _send() {
    if (widget.busy || !widget.enabled) return;
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    // The field is cleared only when the app layer took the message.
    //
    // This used to clear unconditionally, which meant a message the app layer
    // refused — most often because networking had not started yet — vanished from
    // the input along with the draft, and the user had no way to tell that
    // anything had gone wrong. On a messenger that is the worst possible failure:
    // the words were the only copy.
    final accepted = widget.onSend(text, widget.reply?.id);
    if (!accepted) {
      widget.onSendFailed?.call(
        'That message was not sent. DarkFlow has to be unlocked, and the text '
        'cannot be empty.',
      );
      return;
    }

    _controller.clear();
    widget.onDraftChanged?.call('');
    // Keeping focus keeps the keyboard up for the next message, which is what
    // a conversation screen wants.
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final reply = widget.reply;

    return Padding(
      // The keyboard inset is applied here, and the screen that hosts the
      // composer turns off `resizeToAvoidBottomInset` so it is counted once.
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: 12 + math.max(viewInsets, safeBottom),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (reply != null) _replyBar(reply),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: _recording ? _recordingIndicator() : _inputPill(),
              ),
              const SizedBox(width: 12),
              _trailingControl(),
            ],
          ),
        ],
      ),
    );
  }

  /// The quoted message the next send will answer, with a way out of replying.
  ///
  /// A reply that cannot be cancelled is a trap: the user taps the wrong message,
  /// and every message afterwards carries the same quote with nothing on screen
  /// offering to stop it. The dismiss control is therefore part of the bar, and
  /// Escape does the same thing from the keyboard.
  Widget _replyBar(ComposerReply reply) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(
            left: BorderSide(color: AppColors.accent, width: 3),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Replying to ${reply.author}',
                    style: AppTypography.caption.copyWith(
                      color: AppColors.accent,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    reply.text,
                    style: AppTypography.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (widget.onCancelReply != null)
              IconButton(
                onPressed: widget.onCancelReply,
                icon: const Icon(Icons.close, size: 18),
                color: AppColors.textSecondary,
                tooltip: 'Cancel reply',
                splashRadius: 18,
              ),
          ],
        ),
      ),
    );
  }

  /// The pill: attach glyph, text field, placeholder.
  Widget _inputPill() {
    return Container(
      constraints: const BoxConstraints(minHeight: AppMetrics.composerHeight),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppMetrics.composerHeight / 2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          // The attach button takes the pill's left edge, which is where the
          // mockup's 24 pt text padding sat; the text therefore starts after
          // the glyph rather than at a fixed 24 pt.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.enabled && !widget.sending ? widget.onAttach : null,
            child: SizedBox(
              width: 40,
              height: 40,
              child: widget.sending
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          valueColor: AlwaysStoppedAnimation(AppColors.accent),
                        ),
                      ),
                    )
                  : const Icon(
                      Icons.attach_file,
                      size: 22,
                      color: AppColors.textSecondary,
                    ),
            ),
          ),
          Expanded(
            child: Shortcuts(
              // Escape drops the reply target, which is the gesture every desktop
              // messenger binds and the only keyboard way out of a reply.
              shortcuts: const <ShortcutActivator, Intent>{
                SingleActivator(LogicalKeyboardKey.escape): _CancelReplyIntent(),
              },
              child: Actions(
                actions: <Type, Action<Intent>>{
                  _CancelReplyIntent: CallbackAction<_CancelReplyIntent>(
                    onInvoke: (_) {
                      widget.onCancelReply?.call();
                      return null;
                    },
                  ),
                },
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  enabled: widget.enabled,
                  autofocus: widget.autofocus,
                  maxLines: 1,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (String _) => _send(),
                  cursorColor: AppColors.accent,
                  style: AppTypography.input,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(horizontal: 8),
                    hintText: 'Type message...',
                    hintStyle: AppTypography.placeholder,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// What replaces the field while a note is being recorded. It says what it
  /// does and nothing more: there is no slide-to-cancel gesture to promise.
  Widget _recordingIndicator() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onStopVoice,
      child: Container(
        height: AppMetrics.composerHeight,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppMetrics.composerHeight / 2),
        ),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Text(_formatElapsed(_elapsed), style: AppTypography.body.copyWith(fontSize: 15)),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Recording — tap the stop button to send it',
                style: AppTypography.caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Send while there is text, the microphone while there is not, a spinner
  /// while a send is in flight, and a stop control while recording.
  Widget _trailingControl() {
    if (_recording) {
      return _TapTarget(
        // `_finishRecording`, not `onStopVoice` directly.
        //
        // Wiring the callback straight through sent the voice note and left this
        // widget's own `_recording` flag true: the indicator and its stopwatch
        // stayed on screen, the ticker kept running, and the only way back to the
        // text field was to press the stop control a second time and hope. The
        // screen owns the state that draws the recording UI, so it has to be the
        // thing that clears it.
        onTap: _finishRecording,
        child: const Icon(Icons.stop, size: 24, color: AppColors.danger),
      );
    }
    if (widget.busy || widget.sending) {
      return const SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              valueColor: AlwaysStoppedAnimation(AppColors.accent),
            ),
          ),
        ),
      );
    }
    return _hasText ? _sendButton() : _microphoneButton();
  }

  Widget _sendButton() {
    return _TapTarget(
      onTap: widget.enabled ? _send : null,
      child: const Icon(Icons.send, size: 24, color: AppColors.accent),
    );
  }

  Widget _microphoneButton() {
    final supported = widget.onStartVoice != null;
    return Tooltip(
      // The button used to do something on click and something else on hold with
      // nothing on screen saying so, which read as a dead control. Naming the
      // gesture is most of the fix.
      message: supported ? 'Tap to record a voice message' : 'Attach a file',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // A click toggles recording.
          //
          // It used to be `null` whenever a recorder existed, which left the
          // button genuinely inert to a click: only a press-and-hold did anything,
          // nothing on screen said so, and the recording indicator never appeared
          // because `recording` was a widget field that no caller ever set. On a
          // desktop that reads as a dead button, which is exactly how it was
          // reported.
          onTap: supported ? _toggleRecording : widget.onAttach,
          // Holding still works, and now shows the indicator while it does.
          onLongPressStart:
              supported ? (LongPressStartDetails _) => unawaited(_toggleRecording()) : null,
          onLongPressEnd:
              supported ? (LongPressEndDetails _) => unawaited(_finishRecording()) : null,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              _recording ? Icons.stop_circle_outlined : Icons.mic_none,
              size: 24,
              color: _recording ? AppColors.danger : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggleRecording() async {
    if (_recording) return _finishRecording();
    if (_startingRecording) return;

    final start = widget.onStartVoice;
    if (start == null) return;
    setState(() => _startingRecording = true);
    final bool started;
    try {
      started = await start();
    } finally {
      if (mounted) setState(() => _startingRecording = false);
    }
    if (!mounted) return;

    setState(() => _recording = started);
    if (started) {
      _startTicker();
      return;
    }
    // Silence was the whole problem: the button appeared to do nothing and
    // gave no hint that the microphone had been refused.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Could not start recording. Check that a microphone is connected and '
          'that DarkFlow is allowed to use it in Windows privacy settings.',
        ),
      ),
    );
  }

  Future<void> _finishRecording() async {
    if (!_recording) return;
    setState(() => _recording = false);
    _stopTicker();
    widget.onStopVoice?.call();
  }

  /// `mm:ss` for the recording indicator.
  static String _formatElapsed(Duration elapsed) {
    final minutes = elapsed.inMinutes;
    final seconds = elapsed.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}

/// Escape while the composer has focus cancels the pending reply.
class _CancelReplyIntent extends Intent {
  const _CancelReplyIntent();
}

/// A 44 pt square tap target, the smallest the platform guidelines allow.
class _TapTarget extends StatelessWidget {
  const _TapTarget({required this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(width: 44, height: 44, child: child),
      ),
    );
  }
}
