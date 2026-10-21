import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../app/log_book.dart';
import 'playback_completion.dart';
import 'playback_session.dart';

/// Records that playback ended by watchdog rather than by the platform's own signal.
///
/// A free function rather than a direct call into the log book so a test can replace it, and so the
/// media layer does not depend on the application's logging setup.
void logPlaybackCompletionFallback() {
  logApp(
    'a note reached its length without the platform reporting completion',
    detail: 'the end of playback was decided by the watchdog; the button would otherwise have stayed '
        'on pause',
  );
}

/// Records and plays voice messages.
///
/// The codec choice is forced by the platforms rather than chosen: `record`
/// can produce Opus on Android and iOS, but on Windows and macOS it can only
/// write AAC or PCM, and the Opus file iOS produces lives in a CAF container
/// that nothing else can play. Since a voice note has to be playable by whoever
/// receives it — who may be on any platform — DarkFlow records **AAC in an MP4
/// container**, which every target decodes natively. The cost is a slightly
/// larger file, which is a fair trade for a message that always plays.
///
/// ## Microphone selection
///
/// [microphoneId] picks the input device. Windows exposes several — a laptop's
/// built-in array, a headset, a virtual cable — and the one the system happens to
/// prefer is frequently the wrong one, which a user experiences as "the
/// microphone does not work". `record` accepts the device per recording, so the
/// choice is a stored preference rather than something to work around.
class VoiceRecorder {
  VoiceRecorder();

  /// The microphone, created on first use.
  ///
  /// Lazily, and that is a fix rather than tidiness: `AudioRecorder()`'s constructor calls `create` on
  /// the platform channel, so building a `VoiceRecorder` reached the platform even for an object that
  /// was only ever going to *play* something. The consequence was visible in two places — playback
  /// could not be exercised in a test without a microphone, and on a device where the plugin was
  /// missing the failure arrived while constructing the object rather than while recording.
  ///
  /// `VoiceRecorder` is a name for two capabilities that share a file format, and only recording needs
  /// the microphone.
  AudioRecorder? _recorderInstance;

  AudioRecorder get _recorder => _recorderInstance ??= AudioRecorder();

  /// True once the microphone has been opened, for `dispose` to know whether there is anything to
  /// release.
  bool get hasRecorder => _recorderInstance != null;

  /// The one player this recorder uses, created lazily and then kept.
  ///
  /// Never disposed until [dispose]: see the note on [play] for why reusing it is
  /// what fixes the platform crash.
  AudioPlayer? _player;

  /// Called when playback had to be ended by the watchdog rather than by the platform.
  ///
  /// The default records it in `darkflow.log`. A platform whose completion signal never arrives is
  /// otherwise completely invisible: the audio plays, the interface recovers, and nothing records that
  /// a whole code path was skipped — which is exactly the kind of fault that makes a bug take four
  /// rounds to find.
  void Function()? _onCompletionFallback = logPlaybackCompletionFallback;

  /// Replaces the default report. Set to a no-op in a test that does not want the global log touched.
  set onCompletionFallback(void Function()? callback) => _onCompletionFallback = callback;

  /// Who owns the player right now, and therefore who may report progress and
  /// clear the interface's playing state. See [PlaybackSession].
  final PlaybackSession _session = PlaybackSession();

  /// The input device id passed to the recorder, or null for the system default.
  ///
  /// Applied at `start`, because `record` takes it per recording rather than as
  /// global state.
  String? microphoneId;

  Timer? _ticker;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  final List<int> _amplitudes = <int>[];
  final Stopwatch _elapsed = Stopwatch();
  String? _currentPath;
  bool _recording = false;

  /// True while the microphone is open.
  bool get isRecording => _recording;

  /// Elapsed time of the recording in progress.
  Duration get elapsed => _elapsed.elapsed;

  /// Emits the elapsed time roughly ten times a second while recording.
  Stream<Duration> get ticks => _ticks.stream;
  final StreamController<Duration> _ticks = StreamController<Duration>.broadcast();

  /// Amplitude buckets collected so far, normalised to 0..100.
  ///
  /// A voice bubble draws these as the waveform, exactly as the mockup shows,
  /// so the shape of the sound is captured while it is recorded rather than
  /// recomputed later.
  List<int> get waveform => _normaliseWaveform(_amplitudes);

  /// True when the platform has a working microphone and a supported codec.
  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } on Object {
      return false;
    }
  }

  /// The input devices this platform offers, for the settings screen.
  ///
  /// An empty list on a platform that does not enumerate them — Android and iOS
  /// route the microphone themselves — which the screen renders as "handled by the
  /// system" rather than as an error.
  Future<List<InputDevice>> microphones() async {
    try {
      return await _recorder.listInputDevices();
    } on Object {
      // A platform whose channel does not answer is not an error worth showing:
      // the answer is "the system decides", which is also what an empty list
      // means.
      return const <InputDevice>[];
    }
  }

  /// Starts recording into the application cache.
  ///
  /// Returns false when permission is refused or the platform recorder fails,
  /// so the caller can say something useful instead of silently doing nothing.
  ///
  /// Two overlapping calls share one start. The only guard used to be
  /// `if (_recording) return true;`, and `_recording` is set *after* the
  /// permission check and the platform call — so two taps in quick succession both
  /// got past it. The second call then overwrote `_amplitudeSubscription` and
  /// `_ticker` without cancelling the first, and the first 100 ms timer ran for the
  /// rest of the process's life while its amplitude subscription was never
  /// cancelled; `_currentPath` was overwritten too, orphaning the first recording
  /// on disk so that `stop()` could only ever return the second.
  Future<bool> start() {
    if (_recording) return Future<bool>.value(true);
    return _startInFlight ??= _start().whenComplete(() => _startInFlight = null);
  }

  Future<bool>? _startInFlight;

  Future<bool> _start() async {
    try {
      if (!await hasPermission()) return false;
      final directory = await getTemporaryDirectory();
      final path =
          '${directory.path}${Platform.pathSeparator}voice-${DateTime.now().millisecondsSinceEpoch}.m4a';
      final chosen = microphoneId;
      await _recorder.start(
        RecordConfig(
          // AAC-LC in MP4: playable everywhere DarkFlow runs.
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
          numChannels: 1,
          // Null means the system default, which is what a platform that does not
          // enumerate devices expects and what a user who has not chosen gets.
          //
          // The label is synthesised from the id because `RecordConfig` only uses
          // the id: the platform resolves it against its own device list.
          device: chosen == null
              ? null
              : InputDevice(id: chosen, label: chosen),
        ),
        path: path,
      );
      _currentPath = path;
      _amplitudes.clear();
      _elapsed
        ..reset()
        ..start();
      _recording = true;
      // Belt and braces: replacing either of these without cancelling the old one
      // is the leak described above.
      await _amplitudeSubscription?.cancel();
      _ticker?.cancel();
      _amplitudeSubscription = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 120))
          .listen((amplitude) {
        // The recorder reports dBFS, which is negative and unintuitive; the
        // bubble wants a 0..100 column height.
        final normalised = ((amplitude.current + 60) / 60 * 100).clamp(0, 100).round();
        _amplitudes.add(normalised);
      });
      _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!_ticks.isClosed) _ticks.add(_elapsed.elapsed);
      });
      return true;
    } on Object {
      // The native recorder may already be open, and `_cleanup` releases only the
      // Dart side of it: leaving the microphone running while `isRecording` says
      // otherwise meant `stop()` returned null immediately and the file kept
      // growing until `dispose`.
      try {
        await _recorder.stop();
      } on Object {
        // Nothing to salvage.
      }
      await _cleanup();
      return false;
    }
  }

  /// Stops recording and returns the file, or null when nothing was captured.
  Future<File?> stop() async {
    if (!_recording) return null;
    try {
      final path = await _recorder.stop();
      final target = path ?? _currentPath;
      final duration = _elapsed.elapsed;
      await _cleanup();
      if (target == null || duration.inMilliseconds < 400) {
        // Anything shorter than a moment is a mis-tap, not a message.
        final file = target == null ? null : File(target);
        if (file != null && file.existsSync()) await file.delete();
        return null;
      }
      final file = File(target);
      return file.existsSync() ? file : null;
    } on Object {
      await _cleanup();
      return null;
    }
  }

  /// Abandons the recording in progress and deletes its file.
  ///
  /// A no-op when nothing is being recorded. It used to fall back to
  /// `_currentPath`, which still held the path of the *previous* recording after
  /// `stop()` had returned it to the caller — and `dispose()` calls this, so
  /// shutting the app down deleted the last voice note's file while the stored
  /// attachment still pointed at it, breaking any later resend.
  Future<void> cancel() async {
    if (!_recording) return;
    try {
      final path = await _recorder.stop();
      final target = path ?? _currentPath;
      if (target != null) {
        final file = File(target);
        if (file.existsSync()) await file.delete();
      }
    } on Object {
      // Nothing to salvage.
    }
    await _cleanup();
  }

  /// Plays [file], reporting progress as a 0..1 fraction of [totalDuration].
  ///
  /// Returns true when this playback ran to completion as the owner, and false
  /// when it was superseded by a stop or by another note. The caller needs the
  /// difference: clearing the interface's "now playing" state on behalf of a
  /// playback that was replaced would clear the state the *replacement* just set,
  /// which reads as a note that starts and immediately stops.
  ///
  /// ## Why there is one long-lived player
  ///
  /// This used to build an `AudioPlayer` per note and `dispose()` it at the end,
  /// and `stopPlayback` disposed it too. Two things followed, both of them the
  /// reported crash — `PlatformException(WindowsAudioError, Player has not yet
  /// been created or has already been disposed)` on Windows and
  /// `Unexpected AndroidAudioError, … java.lang.IllegalStateException` on
  /// Android:
  ///
  ///  * `dispose()` closes the player's own event streams and cancels its
  ///    subscriptions permanently. `stopPlayback` then set `_player = null`, so a
  ///    later call had no handle to reuse and built a fresh one — while the
  ///    awaited `onPlayerComplete.first` of the *previous* play was still pending
  ///    against the disposed instance, and threw the moment it resolved.
  ///  * A second tap landing while the first was still awaiting `player.play`
  ///    meant two players existed and each one's `finally` disposed whichever was
  ///    current, so the surviving tap held a dead object.
  ///
  /// One player, created once and *stopped* rather than disposed, removes both:
  /// there is nothing to race over, and `stop()` frees the native resources while
  /// leaving the Dart object usable for the next note. [PlaybackSession] makes a
  /// superseded play exit quietly instead of waiting for a completion that will
  /// never be addressed to it.
  Future<bool> play(
    File file, {
    Duration? totalDuration,
    void Function(double)? onProgress,
  }) async {
    // A test replaces this rather than the platform. Everything above it in the chain — who owns the
    // player, when the mark is set, what the screen does with it — is the part that has been wrong, and
    // none of it needs an audio device to exercise.
    final standIn = debugPlay;
    if (standIn != null) {
      return standIn(file, totalDuration: totalDuration, onProgress: onProgress);
    }

    final player = await _ensurePlayer();

    // Supersede anything already playing, and claim this playback.
    final owner = _session.begin(
      onProgress: onProgress,
      totalMs: totalDuration?.inMilliseconds ?? 0,
    );

    var finishedAsOwner = false;

    /// Released when playback is over, whether the platform said so or the watchdog decided.
    ///
    /// A plain `Completer` rather than a stream: only the first completion matters, and a stream would
    /// have to be closed on every path out of this method.
    final completion = Completer<void>();

    // Progress is driven from here as well as from the player's own position stream.
    //
    // ## Why a timer and not only `onPositionChanged`
    //
    // The waveform in a voice bubble fills in as the note plays, and that fill comes from
    // `onProgress`. On Android the platform's position stream is not reliable — for some
    // sources it simply does not fire — so the fill stayed empty for the whole note while the
    // audio played correctly. "There is no playback animation on the phone" is that: the sound
    // works and the picture does not move.
    //
    // Polling the player covers every platform, including the ones where the stream works, and
    // the two paths cannot fight: `reportPosition` only reports when a playback owns the player
    // and the total duration is known, and the session ignores anything from a superseded owner.
    //
    // The interval is the one `audioplayers` itself defaults to, so this does not make the
    // interface smoother than the player believes it is.
    Timer? progressTimer;
    try {
      // `stop` rather than `pause`: the same player is about to be handed a new
      // source, and a stopped player reports a clean state for the next one.
      await player.stop();
      if (!_session.isCurrent(owner)) return false;

      await player.setSource(DeviceFileSource(file.path));
      // Both checks matter, and the second is the one that was missing.
      //
      // `play` awaits three platform calls in a row, and the recorder can be disposed underneath it
      // — locking the vault, closing the application, or a rebuild that drops the shell. `dispose`
      // releases the player, and the next call into it throws the platform's own complaint:
      //
      //   PlatformException(WindowsAudioError, Player has not yet been created or has already been
      //   disposed)
      //
      // That is the reported "playback error on the PC". It is not a decoding problem and not a
      // missing file: the player was taken away while a note was still being set up on it.
      //
      // Returning rather than throwing, because a play whose recorder has gone has no caller left
      // to tell: the bubble that started it is gone with the same teardown.
      if (!_session.isCurrent(owner)) return false;
      if (_player == null) return false;

      await player.resume();

      if (!_session.isCurrent(owner)) return false;
      if (_player == null) return false;

      progressTimer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
        if (!_session.isCurrent(owner)) {
          progressTimer?.cancel();
          return;
        }
        try {
          _session.reportPosition(await player.getCurrentPosition() ?? Duration.zero);
        } on Object {
          // A player that cannot report a position is the case this timer exists for, and
          // there is nothing to do about it beyond leaving the fallback alone.
        }
      });

      // Completes when playback ends, is stopped, or the player is released.
      //
      // ## Why a watchdog races it
      //
      // `onPlayerComplete` is a platform signal, and it is the only thing that ends this await. When it
      // does not arrive — a codec that reaches the end without reporting, a webview or an emulator with
      // a partial implementation, a player the operating system suspends — the await never settles. The
      // consequences are all visible and all confusing: the button stays on "pause" for a note that has
      // finished, the session stays claimed so the next tap is treated as "stop this one", and the
      // progress timer keeps running for the life of the process.
      //
      // The note's length is known, so a timer can end the playback for the platform. It is set a
      // little past the duration because a timer that fires early would cut the sound off at the end of
      // every note, which is worse than the bug being fixed.
      //
      // Whichever arrives first ends the await; the other is cancelled in `finally`. Neither path can
      // double-report, because `_session.finish` only answers true for the first caller holding the
      // token.
      final watchdogMs = completionDeadline(totalDuration).inMilliseconds;
      final watchdog = Timer(Duration(milliseconds: watchdogMs), () {
        if (!completion.isCompleted) {
          // Recorded, because a platform that never reports completion is worth knowing about and is
          // otherwise invisible: everything works and one path is silently never taken.
          _onCompletionFallback?.call();
          completion.complete();
        }
      });
      try {
        await Future.any(<Future<void>>[player.onPlayerComplete.first, completion.future]);
      } finally {
        watchdog.cancel();
        if (!completion.isCompleted) completion.complete();
      }
    } on Object {
      // A codec the platform cannot decode ends playback. Reported rather than
      // swallowed: the caller has a bubble showing a play button that did nothing,
      // and silently returning leaves it that way. A playback that has been
      // superseded by a stop or another note says nothing — its failure is
      // expected.
      if (_session.isCurrent(owner)) rethrow;
    } finally {
      // Set here rather than returned from here: a `return` inside `finally`
      // discards whatever the `try` was about to do, including a rethrow.
      progressTimer?.cancel();
      finishedAsOwner = _session.finish(owner);
      if (finishedAsOwner) onProgress?.call(0);
    }
    return finishedAsOwner;
  }

  /// Creates the player on first use and wires its progress stream once.
  ///
  /// The subscription is to the player, not to a playback: `onPositionChanged`
  /// fires for whatever source the player currently holds, and the session decides
  /// whether anybody cares. Subscribing per note meant a stale closure could report
  /// progress for a note that had finished.
  Future<AudioPlayer> _ensurePlayer() async {
    final existing = _player;
    if (existing != null) return existing;

    final player = AudioPlayer();
    _player = player;
    player.onPositionChanged.listen(_session.reportPosition);
    // A note that runs to its end must stop reporting progress too, not only one
    // that is stopped by hand. `play` completes in both cases, which is what the
    // app layer awaits; this stops a stale position arriving in between.
    player.onPlayerComplete.listen((_) => _session.releaseOnCompletion());
    return player;
  }

  /// Replaces [play] with a stand-in, so a test can exercise the path above the platform.
  ///
  /// Exists because every fault in this area has been in the chain *around* the player — when the "now
  /// playing" mark is set, whether it reaches the screen, whether the button comes back at the end — and
  /// each of those needs the whole path to run without an audio device.
  ///
  /// The stand-in receives exactly what the real method receives and returns what it returns: true when
  /// the playback ran to its end, false when it was superseded by another note.
  @visibleForTesting
  Future<bool> Function(
    File file, {
    Duration? totalDuration,
    void Function(double)? onProgress,
  })? debugPlay;

  /// Stops anything currently playing. The player stays usable.
  Future<void> stopPlayback() async {
    // Invalidates any play in flight before touching the player, so its pending
    // `onPlayerComplete` cannot run its completion path against a stopped source.
    _session.cancel();
    final player = _player;
    if (player == null) return;
    try {
      await player.stop();
    } on Object {
      // Already stopped, or the platform refused. Neither is worth reporting.
    }
  }

  /// Releases the recorder and the player.
  ///
  /// The player reference is dropped **before** anything is awaited, and that order is the point.
  ///
  /// `dispose` is called while a note may still be starting: the shell rebuilds, the vault locks,
  /// the application closes. `play` checks `_player == null` between its platform calls, which only
  /// protects it if the reference is gone by then. Clearing it after `await _player?.dispose()`
  /// left a window in which the player was released and the field still pointed at it — so the
  /// guard passed and the next call threw
  /// `PlatformException(WindowsAudioError, Player has not yet been created or has already been
  /// disposed)`, which is the reported PC playback error.
  ///
  /// `_session.cancel()` first does the same job for the checks that read the session rather than
  /// the field.
  Future<void> dispose() async {
    _session.cancel();
    final player = _player;
    _player = null;
    await cancel();
    // `dispose` is correct here and only here: the object is never used again.
    await player?.dispose();
    // Only when the microphone was ever opened. The getter creates one on first use, and this used to
    // call it unconditionally — so disposing a recorder that had only ever *played* something built a
    // microphone in order to release it, and on a host without the plugin that threw from `dispose`.
    // Which is the worst moment for it: teardown, where the failure has nothing to do with the test.
    await _recorderInstance?.dispose();
    _recorderInstance = null;
    if (!_ticks.isClosed) await _ticks.close();
  }

  Future<void> _cleanup() async {
    _recording = false;
    // Cleared so the path cannot outlive the recording it names. `stop()` and
    // `cancel()` read it before calling this, so both still see their own file.
    _currentPath = null;
    _elapsed.stop();
    _ticker?.cancel();
    _ticker = null;
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
  }

  /// Reduces the raw amplitude trace to the fixed number of columns a bubble
  /// can draw, keeping the loudest sample in each bucket so a short peak stays
  /// visible instead of being averaged away.
  static List<int> _normaliseWaveform(List<int> samples, {int columns = 48}) {
    if (samples.isEmpty) return const <int>[];
    if (samples.length <= columns) return List<int>.unmodifiable(samples);
    final bucketSize = samples.length / columns;
    final out = <int>[];
    for (var i = 0; i < columns; i++) {
      final start = (i * bucketSize).floor();
      final end = min(samples.length, ((i + 1) * bucketSize).ceil());
      var peak = 0;
      for (var j = start; j < end; j++) {
        if (samples[j] > peak) peak = samples[j];
      }
      out.add(peak);
    }
    return List<int>.unmodifiable(out);
  }
}
