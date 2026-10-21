import 'package:darkflow/src/media/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ownership of the audio player.
///
/// These cover the logic that was producing
/// `PlatformException(WindowsAudioError, Player has not yet been created or has
/// already been disposed)` on Windows and the matching `IllegalStateException` on
/// Android. The crash came from a player being disposed while a pending
/// completion still referred to it, and from two plays racing over one handle;
/// this class is what decides who owns the handle, so the cases below are the ones
/// that have to hold.
void main() {
  group('one playback owns the player', () {
    test('beginning a playback supersedes the previous owner', () {
      final session = PlaybackSession();

      final first = session.begin(totalMs: 1000);
      expect(session.isCurrent(first), isTrue);
      expect(session.isPlaying, isTrue);

      // A second tap, on the same note or a different one.
      final second = session.begin(totalMs: 2000);
      expect(session.isCurrent(first), isFalse,
          reason: 'the first playback must learn it has been replaced');
      expect(session.isCurrent(second), isTrue);
    });

    test('only the current owner reports progress', () {
      final session = PlaybackSession();
      final reported = <double>[];

      final first = session.begin(
        onProgress: reported.add,
        totalMs: 1000,
      );
      session.reportPosition(const Duration(milliseconds: 500));
      expect(reported, <double>[0.5]);

      // The second note takes over. The first one's callback must go quiet, or a
      // replaced note would keep moving the new note's progress bar.
      session.begin(onProgress: (_) {}, totalMs: 4000);
      session.reportPosition(const Duration(milliseconds: 500));
      expect(reported, <double>[0.5], reason: 'the old reporter must be dropped');
      expect(session.isCurrent(first), isFalse);
    });

    test('finishing reports ownership, so a replaced play stays silent', () {
      final session = PlaybackSession();

      final first = session.begin(totalMs: 1000);
      final second = session.begin(totalMs: 1000);

      // The first playback completes after being replaced. It must *not* claim
      // ownership, because the interface's "now playing" state belongs to the
      // second note now — clearing it there is what made a new note look like it
      // started and immediately stopped.
      expect(session.finish(first), isFalse);
      expect(session.isCurrent(second), isTrue);

      // The second one finishes as the owner and may clear the state.
      expect(session.finish(second), isTrue);
      expect(session.isPlaying, isFalse);
    });

    test('a stop takes ownership away from the playback in flight', () {
      final session = PlaybackSession();
      final owner = session.begin(onProgress: (_) {}, totalMs: 1000);

      session.cancel();

      expect(session.isCurrent(owner), isFalse,
          reason: 'a stopped playback must not clear the state a later one sets');
      expect(session.isPlaying, isFalse);
      // And its own completion is a no-op rather than a claim.
      expect(session.finish(owner), isFalse);
    });
  });

  group('progress is only reported when it means something', () {
    test('nothing is reported when nobody owns the player', () {
      final session = PlaybackSession();
      // Straight after a stop, a late position event must not draw anything.
      session.cancel();
      // Throws if it tries to divide by an unknown total; passes if it ignores.
      session.reportPosition(const Duration(seconds: 1));
    });

    test('nothing is reported for an unknown duration', () {
      final reported = <double>[];
      final session = PlaybackSession();
      session.begin(onProgress: reported.add, totalMs: 0);

      // A note whose length is unknown would otherwise produce a bar drawn from a
      // division by zero.
      session.reportPosition(const Duration(seconds: 1));
      expect(reported, isEmpty);
    });

    test('progress is clamped to 0..1', () {
      final reported = <double>[];
      final session = PlaybackSession();
      session.begin(onProgress: reported.add, totalMs: 1000);

      // A platform that reports a position past the duration — or a duration from
      // metadata that is shorter than the file — must not draw a bar past its end.
      session.reportPosition(const Duration(milliseconds: 5000));
      expect(reported.single, 1.0);
    });

    test('a completed note stops reporting progress before it is finished', () {
      final reported = <double>[];
      final session = PlaybackSession();
      final owner = session.begin(onProgress: reported.add, totalMs: 1000);

      session.reportPosition(const Duration(milliseconds: 500));
      // The player says it is done; a position event arriving after that is stale.
      session.releaseOnCompletion();
      session.reportPosition(const Duration(milliseconds: 900));

      expect(reported, <double>[0.5]);
      // Ownership is still the caller's, so it may clear the interface state.
      expect(session.finish(owner), isTrue);
    });
  });
}
