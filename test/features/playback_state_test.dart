import 'package:darkflow/src/app/darkflow_app.dart';
import 'package:darkflow/src/design/design.dart';
import 'package:darkflow/src/features/chats/widgets/voice_message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// How a note that starts playing reaches the bubble that has to show it.
///
/// ## The fault this pins down
///
/// On a phone the conversation is a **pushed route**. It used to be handed `playingAttachmentId` and
/// `voiceProgress` as parameters, and a route is built once — so both were a snapshot taken when the
/// conversation opened. The shell rebuilt when a note started, the notifier's value changed, and the
/// route went on showing the snapshot. The sound played and the button stayed on "play".
///
/// The fix is that the screen listens to a `PlaybackController` instead of being handed a value, and
/// these tests keep the two properties that make it work: the notifier reaches a subscriber however
/// the subscriber was built, and the state it carries cannot disagree with itself.
void main() {
  Widget host(Widget child) =>
      MaterialApp(theme: AppTheme.build(), home: Scaffold(body: Center(child: child)));

  test('a fresh controller is playing nothing', () {
    final playback = PlaybackController();
    addTearDown(playback.dispose);

    expect(playback.value.attachmentId, isNull);
    expect(playback.value.progress, 0);
    expect(playback.value.isPlaying('anything'), isFalse);
  });

  test('the mark can be set and cleared', () {
    final playback = PlaybackController();
    addTearDown(playback.dispose);

    playback.set('note-1', 0);
    expect(playback.value.isPlaying('note-1'), isTrue);
    expect(playback.value.isPlaying('note-2'), isFalse);

    playback.set('note-1', 0.5);
    expect(playback.value.progress, 0.5);

    playback.set(null, 0);
    expect(playback.value.attachmentId, isNull);
    expect(playback.value.isPlaying('note-1'), isFalse);
  });

  test('every change is announced, including one that looks the same', () {
    // Counted rather than compared, because the bubble redraws from what it is given: a change that
    // were swallowed as "no difference" would leave the wave frozen at the old position.
    final playback = PlaybackController();
    addTearDown(playback.dispose);

    var notifications = 0;
    playback.addListener(() => notifications++);

    playback.set('note-1', 0);
    playback.set('note-1', 0.25);
    playback.set('note-1', 0.25);
    playback.set(null, 0);

    expect(notifications, 4);
  });

  testWidgets('a subscriber redraws when the note changes', (tester) async {
    // The mechanism, at the level the fault was: a widget built once — as a pushed route is — still
    // has to follow the mark. This builder is the only thing connecting the two.
    final playback = PlaybackController();
    addTearDown(playback.dispose);

    await tester.pumpWidget(host(ValueListenableBuilder<PlaybackState>(
      valueListenable: playback,
      builder: (context, state, _) => VoiceMessageBubble(
        outgoing: false,
        durationMs: 4_000,
        waveform: const <int>[10, 20, 30, 40, 50, 60],
        playing: state.isPlaying('note-1'),
        progress: state.progress,
        onTogglePlayback: () {},
      ),
    )));

    IconData icon() => tester
        .widget<Icon>(find.descendant(
          of: find.byWidgetPredicate(
            (Widget widget) => widget.runtimeType.toString() == '_PlayControl',
          ),
          matching: find.byType(Icon),
        ))
        .icon!;

    expect(icon(), Icons.play_arrow, reason: 'nothing is playing yet');

    // A note starts, after the widget was built — exactly the case a snapshot cannot express.
    playback.set('note-1', 0);
    await tester.pump();
    expect(icon(), Icons.pause,
        reason: 'the note that started has to reach a widget that was already built');

    // And the position follows, which is what fills the wave.
    playback.set('note-1', 0.8);
    await tester.pump();
    expect(icon(), Icons.pause);

    playback.set(null, 0);
    await tester.pump();
    expect(icon(), Icons.play_arrow, reason: 'and it goes back when the note ends');
  });
}
