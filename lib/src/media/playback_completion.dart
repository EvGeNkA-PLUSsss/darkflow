/// When to give up waiting for the platform to say a note has finished.
///
/// ## The failure this exists for
///
/// `AudioPlayer.onPlayerComplete` is a platform signal, and it is the only thing that ends the await in
/// `VoiceRecorder.play`. When it does not arrive — a codec that reaches the end without reporting, a
/// partial implementation, a player the operating system suspends — that await never settles. The
/// button stays on "pause" for a note that has already finished, the session stays claimed so the next
/// tap is read as "stop this one", and the progress timer runs for the life of the process.
///
/// ## Why the length of the note, plus slack
///
/// The note knows how long it is, so the end is predictable without the platform's help. The slack is
/// what keeps this from being worse than the bug: a timer that fired exactly at the duration would
/// truncate the last syllable of every note on a device whose clock drifts, and truncating playback is
/// a much worse defect than a button that clears a second late.
///
/// ## Why there is always a deadline
///
/// A note with no recorded length — an older record, or a duration that never made it into the store —
/// still needs one, or the missing-signal case leaves it stuck for ever. The fallback is generous
/// rather than clever: it is a ceiling, not an estimate.
library;

/// Extra time allowed past a note's own length before the watchdog decides the platform is not going to
/// report the end.
const Duration kCompletionSlack = Duration(seconds: 2);

/// Used when the note's length is unknown.
///
/// Long enough that a real note of any plausible size finishes first, short enough that a stuck player
/// recovers while the user is still looking at the screen.
const Duration kUnknownLengthCeiling = Duration(minutes: 10);

/// How long to wait for the platform to report that playback ended.
///
/// [noteDuration] is the length recorded for the note, or null and zero when it is not known.
Duration completionDeadline(Duration? noteDuration) {
  final length = noteDuration ?? Duration.zero;
  if (length <= Duration.zero) return kUnknownLengthCeiling;
  return length + kCompletionSlack;
}
