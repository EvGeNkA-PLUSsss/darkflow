/// Which playback owns the audio player.
///
/// ## What this exists to prevent
///
/// Playing a voice note used to build an `AudioPlayer`, await its completion, and
/// dispose it — and stopping one disposed it too. Two failures came out of that,
/// both reported as a crash the moment the play button was pressed a second time
/// or the stop button was pressed at all:
///
/// * `PlatformException(WindowsAudioError, Player has not yet been created or has
///   already been disposed)`.
/// * `Unexpected AndroidAudioError, … java.lang.IllegalStateException: Player has
///   not yet been created or has already been disposed`.
///
/// `dispose()` closes the player's streams permanently, so a pending
/// `onPlayerComplete.first` against it throws the instant it resolves. The fix is
/// to keep one player and *stop* it rather than dispose it — but then two plays
/// can be in flight over that one handle, and each would report progress and clear
/// the "now playing" state for the other.
///
/// This class is that ownership, kept separate from the platform so it can be
/// tested without an audio device: [begin] claims playback and invalidates
/// whatever claimed it before, [isCurrent] is how a play discovers it has been
/// superseded and should exit without touching anything, and [finish] reports
/// whether the caller is still the owner and may therefore clear shared state.
class PlaybackSession {
  int _owner = 0;
  bool _active = false;

  /// Progress reporting for the playback in flight.
  void Function(double progress)? _onProgress;
  int _totalMs = 0;

  /// True while some playback owns the player.
  bool get isPlaying => _active;

  /// The identifier of the current owner, or 0 when nothing is playing.
  int get owner => _owner;

  /// Claims playback, superseding whatever held it before.
  ///
  /// Returns the token the caller passes to [isCurrent] and [finish]. The previous
  /// owner is not told: it discovers the change the next time it checks.
  int begin({void Function(double progress)? onProgress, required int totalMs}) {
    _owner++;
    _active = true;
    _onProgress = onProgress;
    _totalMs = totalMs;
    return _owner;
  }

  /// True when [token] still owns playback.
  ///
  /// A superseded play uses this to leave quietly: its completion, its failure and
  /// its progress all belong to a playback nobody is waiting for any more.
  bool isCurrent(int token) => _active && token == _owner;

  /// Releases ownership if [token] still holds it.
  ///
  /// Returns true when the caller was still the owner, which is the only case in
  /// which it may clear the interface's "now playing" state — otherwise a note
  /// that finished after the user started another one would stop the new one from
  /// being shown as playing.
  bool finish(int token) {
    if (!isCurrent(token)) return false;
    _active = false;
    _onProgress = null;
    _totalMs = 0;
    return true;
  }

  /// Drops ownership without a token, for a stop that has no caller to ask.
  void cancel() {
    _active = false;
    _onProgress = null;
    _totalMs = 0;
  }

  /// Reports a position, scaled to the current playback.
  ///
  /// Ignored when nothing owns the player, or when the note's duration is unknown:
  /// a division by an unknown total would draw a progress bar that means nothing.
  void reportPosition(Duration position) {
    final report = _onProgress;
    if (!_active || report == null || _totalMs <= 0) return;
    report((position.inMilliseconds / _totalMs).clamp(0.0, 1.0));
  }

  /// Called when the player reports completion.
  ///
  /// Only stops further progress being reported. Ownership is released by
  /// [finish], because the caller awaiting `play` is the one that has to clear the
  /// interface — releasing here as well would let a later `finish` claim success
  /// it no longer has.
  void releaseOnCompletion() => _onProgress = null;
}
