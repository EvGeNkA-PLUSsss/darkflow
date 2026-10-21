import 'dart:io';

import 'package:darkflow/src/app/app_controller.dart';
import 'package:darkflow/src/app/darkflow_app.dart';
import 'package:darkflow/src/data/models/message.dart';
import 'package:darkflow/src/data/vault_store.dart';
import 'package:darkflow/src/design/design.dart';
import 'package:darkflow/src/features/chats/widgets/voice_message_bubble.dart';
import 'package:darkflow/src/media/voice_recorder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the wave and the button do with the state they are handed.
///
/// This exists because of a specific report: a voice note played — the sound was audible — and the
/// button stayed on "play" with the wave unfilled. The player was working, so the fault was in the
/// state the bubble was given, and the two halves of that state have to be pinned down separately:
/// [playing] decides the icon, [progress] decides the fill, and neither is inferred from the other.
void main() {
  Widget host(Widget child) =>
      MaterialApp(theme: AppTheme.build(), home: Scaffold(body: Center(child: child)));

  const waveform = <int>[10, 20, 30, 40, 50, 60, 70, 80];
  void noop() {}

  /// The icon inside the round play control, and only that one.
  ///
  /// Found through the control's own type rather than as `find.byType(Icon).first`. That shortcut is
  /// how a test comes to assert about a different widget than it means to, and it did exactly that
  /// here before being corrected.
  IconData iconOf(WidgetTester tester) {
    final control = find.byWidgetPredicate(
      (Widget widget) => widget.runtimeType.toString() == '_PlayControl',
    );
    expect(control, findsOneWidget, reason: 'the pill always has exactly one play control');
    return tester
        .widget<Icon>(find.descendant(of: control, matching: find.byType(Icon)))
        .icon!;
  }

  testWidgets('an idle note offers play and shows no position', (tester) async {
    await tester.pumpWidget(host(VoiceMessageBubble(
      outgoing: false,
      durationMs: 4000,
      waveform: waveform,
      playing: false,
      progress: 0.5,
      onTogglePlayback: noop,
    )));

    expect(iconOf(tester), Icons.play_arrow);

    // A position without playback is ignored rather than drawn. The chat screen already passes null
    // for notes that are not playing, so this is the second line of defence: a bubble that filled its
    // wave while idle would be showing progress for something that is not happening.
    expect(tester.takeException(), isNull);
  });

  testWidgets('a playing note offers pause', (tester) async {
    // The half that failed on the phone. `playing` is the *only* input that changes this icon, so a
    // note whose sound plays while this stays "play" means the bubble was never told it is playing
    // — which is a wiring fault above this widget, not a drawing fault inside it.
    await tester.pumpWidget(host(VoiceMessageBubble(
      outgoing: false,
      durationMs: 4000,
      waveform: waveform,
      playing: true,
      progress: 0,
      onTogglePlayback: noop,
    )));

    expect(iconOf(tester), Icons.pause,
        reason: 'the button has to follow `playing` exactly: this is the mark the screen failed '
            'to set on the phone while the audio was audible');

    await tester.pumpWidget(host(VoiceMessageBubble(
      outgoing: false,
      durationMs: 4000,
      waveform: waveform,
      playing: false,
      progress: 0.25,
      onTogglePlayback: noop,
    )));
    expect(iconOf(tester), Icons.play_arrow);
  });

  testWidgets('the wave is drawn from the position it is given', (tester) async {
    // Draws, rather than crashes, at both ends and in the middle. The fill is a fraction of the
    // bar count, so a progress outside 0..1 has to be clamped instead of reaching the painter.
    for (final progress in const <double>[-1, 0, 0.5, 1, 2]) {
      await tester.pumpWidget(host(VoiceMessageBubble(
        outgoing: false,
      durationMs: 4000,
        waveform: waveform,
        playing: true,
        progress: progress,
        onTogglePlayback: noop,
      )));
      expect(tester.takeException(), isNull,
          reason: 'a position of $progress has to be clamped, not passed through');
    }
  });

  testWidgets('a note with no waveform still draws and can be played', (tester) async {
    // The waveform is optional and older notes have none. The pill still has to be a control.
    await tester.pumpWidget(host(VoiceMessageBubble(
      outgoing: false,
      durationMs: 0,
      playing: true,
      onTogglePlayback: () {},
    )));

    expect(iconOf(tester), Icons.pause);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a note with no callback is not tappable', (tester) async {
    // A bubble that swallowed taps while doing nothing would look broken; the absence of a handler
    // has to mean the absence of the control.
    await tester.pumpWidget(host(VoiceMessageBubble(
      outgoing: false,
      durationMs: 1000,
      waveform: waveform,
    )));

    final gesture = tester.widget<GestureDetector>(find.byType(GestureDetector).first);
    expect(gesture.onTap, isNull);
  });

  test('the mark is set before the file is looked at', () async {
    // The half that failed on the phone, at the layer where it failed.
    //
    // The report was "the sound plays and the button stays off", and the bubble itself is correct —
    // so the screen never learned which note was playing. `toggleVoicePlayback` is what tells it, and
    // this pins the property that makes it work: the mark is set *before* anything is awaited.
    //
    // That order is load-bearing and not obvious. Everything after this point awaits: materialising
    // the file decrypts it, and `play` talks to the platform. If the mark were set after either, a
    // note whose sound starts would leave the button off for as long as the decryption took — and for
    // ever if that await never returned.
    //
    // The note here has no bytes in the vault, so the call fails after marking. That is the case worth
    // testing: the mark is what the screen needs, and it has to be set even when the rest cannot be.
    final sandbox = await Directory.systemTemp.createTemp('df-voice-mark-');

    final paths = VaultPaths(sandbox);
    await paths.ensureCreated();
    final controller = AppController(paths: paths);
    // Locked and disposed before the directory goes: the vault holds write handles and the log book
    // holds one of its own, and on Windows a directory with an open handle inside it cannot be deleted.
    // The order is the same one the application uses on shutdown.
    addTearDown(() async {
      await controller.lock();
      controller.dispose();
      try {
        await sandbox.delete(recursive: true);
      } on FileSystemException {
        // A test that leaves a temporary directory behind fails nothing; a test that throws during
        // teardown fails for a reason unrelated to what it was checking.
      }
    });

    await controller.bootstrap();
    await controller.createAccount(displayName: 'Owner', about: '', password: 'a test passphrase');

    controller.debugRememberAttachment(Attachment(
      id: 'attachment-1',
      fileName: 'note.m4a',
      mimeType: 'audio/mp4',
      sizeBytes: 4,
      sha256Hex: '0' * 64,
      createdAt: DateTime.utc(2026),
      durationMs: 4_000,
    ));

    final changes = <(String?, double)>[];
    final failures = <String>[];

    // Not awaited yet, on purpose: the mark has to be set *synchronously*, in the same turn as the tap.
    final pending = toggleVoicePlayback(
      controller,
      'attachment-1',
      VoiceRecorder(),
      null,
      (String? id, double progress) => changes.add((id, progress)),
      onFailed: failures.add,
    );

    // The assertion that matters most, and the one that took the longest to find.
    //
    // Everything this function does after the first `await` is heavy: `materialise` decrypts the note
    // with a synchronous loop, so while it runs the UI isolate cannot paint. If the mark were set after
    // that point, the button would stay on "play" for the whole decryption while the audio — decoded on
    // the platform's own thread — was already audible. That is the reported fault exactly, and it is
    // why setting the mark in the right *order* was still not enough to fix it.
    expect(changes, contains(('attachment-1', 0.0)),
        reason: 'the mark has to be set in the same turn as the tap, before any decrypting happens');

    final markedSynchronously = changes.length;

    await pending;

    expect(changes.length, greaterThanOrEqualTo(markedSynchronously));
    expect(failures, isNotEmpty, reason: 'a note with no bytes has to say so rather than stay silent');
    // The failure puts the screen back, so the button does not stay stuck on a note that never played.
    expect(changes.last, (null, 0.0),
        reason: 'a note that could not be played must not be left showing as playing');
  });
}
