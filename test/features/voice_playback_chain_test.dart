import 'dart:async';
import 'dart:io';

import 'package:darkflow/src/app/app_controller.dart';
import 'package:darkflow/src/app/darkflow_app.dart';
import 'package:darkflow/src/crypto/dart_crypto_engine.dart';
import 'package:darkflow/src/crypto/onion_address.dart';
import 'package:darkflow/src/data/models/message.dart';
import 'package:darkflow/src/data/vault_store.dart';
import 'package:darkflow/src/design/design.dart';
import 'package:darkflow/src/media/voice_recorder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The whole chain, from a tap on the play control to the icon that changes.
///
/// ## Why this exists when there are tests around each piece
///
/// Four separate faults have been found in this path, and every one was invisible to the tests beside it:
///
///   * the "now playing" mark was set *after* the file was decrypted, so the screen learned about it late;
///   * the phone layout pushes a route, which took the mark as a **snapshot** and never saw it change;
///   * the decryption runs a synchronous loop, so the frame could not be painted until it finished;
///   * `onPlayerComplete` is a platform signal, and when it does not arrive the button never returns.
///
/// Each was a gap between two pieces that were individually correct, and each needed the *whole* chain to
/// be exercised. That is what this does: a real controller, a real store and the real screen, with only
/// the audio device replaced.
///
/// ## The rule this file learned the hard way
///
/// **Nothing that touches the file system goes inside `testWidgets`.**
///
/// A widget test body runs in a fake-async zone, where a real `Directory.systemTemp.createTemp()` future
/// never completes: the test hangs with no error and no timeout, because as far as the framework is
/// concerned nothing is pending. `setUp` runs outside that zone, so all the preparation — the sandbox, the
/// account, the contact, the seeded message — happens there, and the test body only drives the interface.
///
/// That cost several attempts to find, and the symptom was the worst kind: a hang that looks exactly like
/// the code under test.
void main() {
  const password = 'a test passphrase';

  late Directory sandbox;
  late AppController controller;
  late VoiceRecorder recorder;
  late String onion;
  late String attachmentId;

  setUp(() async {
    // Outside the fake-async zone, which is the only place real file I/O completes.
    sandbox = await Directory.systemTemp.createTemp('df-voice-chain-');
    final key = await DartCryptoEngine().generateEd25519();
    onion = OnionAddress.fromPublicKey(key.publicKey);

    final paths = VaultPaths(sandbox);
    await paths.ensureCreated();
    controller = AppController(paths: paths);
    await controller.bootstrap();
    await controller.createAccount(displayName: 'Owner', about: '', password: password);
    recorder = VoiceRecorder();

    // A real onion address rather than a made-up one: `addContact` validates the checksum, so a
    // hand-written address is rejected and the conversation is never created.
    await controller.addContact(onionAddress: onion);
    final conversation = controller.conversations.single;

    attachmentId = 'note-1';
    controller.debugRememberAttachment(Attachment(
      id: attachmentId,
      fileName: 'note.m4a',
      mimeType: 'audio/mp4',
      sizeBytes: 4,
      sha256Hex: '0' * 64,
      createdAt: DateTime.utc(2026),
      durationMs: 4000,
      waveform: const <int>[10, 30, 50, 70, 90],
    ));
    controller.debugAddMessage(
      conversationId: conversation.id,
      body: '',
      attachmentId: attachmentId,
    );
  });

  tearDown(() async {
    // Locked and disposed before the directory goes: the vault holds write handles and the log book holds
    // one of its own, and on Windows a directory with an open handle inside it cannot be deleted.
    await controller.lock();
    controller.dispose();
    await recorder.dispose();
    try {
      await sandbox.delete(recursive: true);
    } on FileSystemException {
      // A leftover temporary directory fails nothing. A teardown that throws fails for a reason unrelated
      // to what the test was checking.
    }
  });

  /// The round control that starts and stops a note.
  Finder playControl() => find.byWidgetPredicate(
        (Widget widget) => widget.runtimeType.toString() == '_PlayControl',
      );

  IconData iconOf(WidgetTester tester) => tester
      .widget<Icon>(find.descendant(of: playControl(), matching: find.byType(Icon)))
      .icon!;

  Future<PlaybackController> pumpConversation(WidgetTester tester) async {
    final playback = PlaybackController();
    addTearDown(playback.dispose);

    // The screen takes a context for its failure messages, so a `Builder` supplies a real one from the
    // tree under test rather than a stand-in.
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(),
      home: Builder(
        builder: (BuildContext context) => buildChatScreen(
          context: context,
          controller: controller,
          peerOnion: onion,
          recorder: recorder,
          playback: playback,
          onPlaybackChanged: playback.set,
        ),
      ),
    ));
    await tester.pump();
    return playback;
  }

  /// Pumps a bounded number of frames.
  ///
  /// Not `pumpAndSettle`: the composer holds a periodic ticker while a note is being recorded, so nothing
  /// in this tree is guaranteed to become fully idle, and settling would wait for ever.
  Future<void> pumpFrames(WidgetTester tester, [int frames = 4]) async {
    for (var frame = 0; frame < frames; frame++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  testWidgets('the voice note is drawn as a playable control', (tester) async {
    await pumpConversation(tester);

    expect(playControl(), findsOneWidget, reason: 'the note has to be drawn at all');
    expect(iconOf(tester), Icons.play_arrow, reason: 'and nothing is playing to begin with');
  });

  testWidgets('the mark is set on the frame after the tap', (tester) async {
    final playback = await pumpConversation(tester);

    // Never reached: the assertion is about the window between the tap and the decryption. A stand-in that
    // returns at once keeps the playback short so nothing is left pending.
    recorder.debugPlay =
        (File file, {Duration? totalDuration, void Function(double)? onProgress}) async => true;

    await tester.tap(playControl());
    // A single frame: the one the tap produced. `toggleVoicePlayback` has set the mark by now but has not
    // yet decrypted anything, because it yields first — and that window is what the whole fix is about.
    await tester.pump();

    expect(playback.value.attachmentId, attachmentId,
        reason: 'the mark has to be visible on the first frame after the tap, or the button stays on play '
            'for the whole decryption while the audio is already audible');

    await pumpFrames(tester);
  });

  testWidgets('the button turns to pause while playing and back when the note ends', (tester) async {
    final playback = await pumpConversation(tester);

    // The stand-in for the audio device: it holds the playback open until the test releases it, which is
    // how a note that is still playing is expressed without a device.
    //
    // A completer rather than a polling loop, because a loop of `Future.delayed` does not advance inside a
    // widget test: the fake clock moves only when a frame is pumped, so the loop would spin for ever and
    // the note would never end.
    final release = Completer<void>();
    recorder.debugPlay = (File file, {Duration? totalDuration, void Function(double)? onProgress}) async {
      await release.future;
      return true;
    };

    await tester.tap(playControl());

    // One frame: the mark is set synchronously by the tap, and the stand-in is still waiting. This is the
    // state the user sees while a note plays — and the state the report said never appeared.
    await tester.pump();

    expect(playback.value.attachmentId, attachmentId,
        reason: 'a note in flight has to be marked, or the button stays on play');
    expect(iconOf(tester), Icons.pause, reason: 'and the button has to follow the mark');

    // Let it finish. The mark has to be cleared, or the next tap is read as "stop this one" instead of
    // starting the note again.
    release.complete();
    await pumpFrames(tester, 6);

    expect(playback.value.attachmentId, isNull, reason: 'a finished note clears the mark');
    expect(iconOf(tester), Icons.play_arrow, reason: 'and the button returns to play');
  });
}
