import 'package:darkflow/src/media/playback_completion.dart';
import 'package:flutter_test/flutter_test.dart';

/// When the recorder stops waiting for the platform to announce the end of a note.
///
/// ## The case this is for
///
/// `onPlayerComplete` is a platform signal and the only thing that ends `VoiceRecorder.play`'s await.
/// When it does not arrive, the button stays on "pause" for a finished note, the session stays claimed
/// so the next tap is read as "stop this one", and the progress timer runs until the process ends.
///
/// These tests pin the two properties that keep the fix from becoming a worse bug: the deadline is
/// always past the note's length, and there is always a deadline.
void main() {
  test('the deadline is past the end of the note', () {
    // The property that matters. A deadline at or before the duration would cut the last syllable off
    // every note on a device whose clock drifts — and truncating playback is a far worse defect than a
    // button that clears a second late.
    for (final ms in <int>[200, 1_000, 4_000, 30_000, 5 * 60 * 1000]) {
      final duration = Duration(milliseconds: ms);
      expect(
        completionDeadline(duration),
        greaterThan(duration),
        reason: 'a note of ${ms}ms must not be cut short by its own watchdog',
      );
    }
  });

  test('the slack is the documented one', () {
    expect(completionDeadline(const Duration(seconds: 4)), const Duration(seconds: 6));
  });

  test('an unknown length still gets a deadline', () {
    // An older record, or a duration that never reached the store. Without a deadline the missing
    // signal would leave that note stuck for ever — which is the whole bug, for exactly the notes
    // least likely to be noticed.
    expect(completionDeadline(null), kUnknownLengthCeiling);
    expect(completionDeadline(Duration.zero), kUnknownLengthCeiling);
  });

  test('a negative length is treated as unknown rather than as immediately over', () {
    // A negative duration is nonsense that a bad record could carry. Treating it as "already finished"
    // would clear the button the instant the note started.
    expect(completionDeadline(const Duration(seconds: -5)), kUnknownLengthCeiling);
  });

  test('the ceiling is generous enough for a real note', () {
    // It is a ceiling, not an estimate: a real note has to finish well before it, or the watchdog
    // would be cutting playback short rather than recovering from a lost signal.
    expect(kUnknownLengthCeiling.inSeconds, greaterThanOrEqualTo(60));
  });
}
