import 'dart:async';

import 'package:darkflow/src/media/playback_completion.dart';
import 'package:flutter_test/flutter_test.dart';

/// That the watchdog actually ends a playback the platform never announces.
///
/// ## The fault
///
/// `onPlayerComplete` is a platform signal and the only thing that ends the await in `VoiceRecorder.play`.
/// When it does not arrive — a codec that reaches the end without reporting, a partial implementation, a
/// player the operating system suspends — the await never settles. The button stays on "pause" for a
/// finished note, the session stays claimed so the next tap is read as "stop this one", and the progress
/// timer runs until the process ends.
///
/// ## What is tested here, and what is not
///
/// `completionDeadline` decides *when*; this file tests that a deadline arriving first actually ends a
/// playback that is racing it. The race itself is the whole mechanism, so it is exercised directly rather
/// than through the recorder — which would need an audio device to reach the same three lines.
void main() {
  group('the deadline', () {
    test('is always past the note, so no note is cut short by its own watchdog', () {
      // The property that keeps the fix from being worse than the bug. A deadline at or before the
      // duration would truncate the last syllable of every note on a device whose clock drifts.
      for (final ms in <int>[100, 1_000, 4_000, 60_000]) {
        final duration = Duration(milliseconds: ms);
        expect(completionDeadline(duration), greaterThan(duration));
      }
    });

    test('exists even when the length is unknown', () {
      // An older record, or a duration that never reached the store. Without a deadline the missing signal
      // would leave exactly those notes stuck for ever.
      expect(completionDeadline(null), kUnknownLengthCeiling);
      expect(completionDeadline(Duration.zero), kUnknownLengthCeiling);
      expect(completionDeadline(const Duration(seconds: -1)), kUnknownLengthCeiling);
    });
  });

  group('the race a playback runs', () {
    /// The mechanism as `VoiceRecorder.play` uses it: whichever of the platform signal and the deadline
    /// arrives first ends the await, and the other is cancelled.
    Future<String> raceTheTwo({
      required Future<void> platformSignal,
      required Duration noteDuration,
      Timer? Function(Duration, void Function()) schedule = Timer.new,
    }) async {
      final completion = Completer<void>();
      final watchdog = schedule(completionDeadline(noteDuration), () {
        if (!completion.isCompleted) completion.complete();
      });
      try {
        await Future.any(<Future<void>>[platformSignal, completion.future]);
        return completion.isCompleted ? 'watchdog' : 'platform';
      } finally {
        watchdog?.cancel();
      }
    }

    test('the platform signal wins when it arrives in time', () async {
      final signal = Completer<void>();
      final result = raceTheTwo(
        platformSignal: signal.future,
        noteDuration: const Duration(seconds: 30),
      );

      signal.complete();
      expect(await result, 'platform');
    });

    test('the watchdog ends a playback the platform never announces', () async {
      // A signal that never arrives, and a note short enough that the deadline is testable.
      final never = Completer<void>();
      final result = await raceTheTwo(
        platformSignal: never.future,
        noteDuration: const Duration(milliseconds: 40),
      );

      expect(result, 'watchdog',
          reason: 'a signal that never comes has to be replaced by the deadline, or the button stays on '
              'pause for ever and the next tap is read as "stop this one"');
    });

    test('a note with an unknown length is still released by the watchdog', () async {
      // The ceiling is minutes, so the test drives the clock rather than waiting: what is checked is that
      // the deadline is always scheduled, whatever the note's length is.
      final never = Completer<void>();
      Duration? scheduledFor;
      final result = await raceTheTwo(
        platformSignal: never.future,
        noteDuration: Duration.zero,
        schedule: (delay, action) {
          scheduledFor = delay;
          // Fired immediately, because waiting ten minutes is not a test.
          return Timer(Duration.zero, action);
        },
      );

      expect(scheduledFor, kUnknownLengthCeiling,
          reason: 'a note with no recorded length still has to have a deadline');
      expect(result, 'watchdog');
    });
  });
}
