import 'package:darkflow/src/app/darkflow_app.dart';
import 'package:darkflow/src/design/design.dart';
import 'package:darkflow/src/features/chats/widgets/voice_message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a **pushed route** does with a value that changes after it was built.
///
/// ## The fault this pins down
///
/// On a phone the conversation is a pushed route. It used to be handed `playingAttachmentId` and
/// `voiceProgress` as parameters, and a route is built once — so both were a snapshot taken when the
/// conversation opened. The shell rebuilt when a note started, the notifier's value changed, and the route
/// went on showing the snapshot: the sound played and the button stayed on "play".
///
/// This is the half the end-to-end chain test cannot see, because that test builds the conversation
/// directly instead of pushing it. The difference is exactly where the bug was.
///
/// ## What the test does
///
/// It reproduces the shape: a route is pushed with a `PlaybackController`, the mark is set *after* the push,
/// and the route has to follow. The widget inside is the real voice bubble, so what is asserted is the
/// control a user taps rather than an internal value.
void main() {
  /// The same wiring `buildChatScreen` uses for the two values: a listener around the screen.
  ///
  /// A route that reads the values once — which is what it used to do — fails this; a route that listens
  /// passes it.
  Widget conversationRoute(PlaybackController playback) {
    return ValueListenableBuilder<PlaybackState>(
      valueListenable: playback,
      builder: (BuildContext context, PlaybackState state, Widget? _) => Scaffold(
        body: Center(
          child: VoiceMessageBubble(
            outgoing: false,
            durationMs: 4000,
            waveform: const <int>[10, 30, 50, 70, 90],
            playing: state.isPlaying('note-1'),
            progress: state.progress,
            onTogglePlayback: () {},
          ),
        ),
      ),
    );
  }

  IconData iconOf(WidgetTester tester) => tester
      .widget<Icon>(find.descendant(
        of: find.byWidgetPredicate(
          (Widget widget) => widget.runtimeType.toString() == '_PlayControl',
        ),
        matching: find.byType(Icon),
      ))
      .icon!;

  testWidgets('a route pushed before a note starts still follows the note', (tester) async {
    final playback = PlaybackController();
    addTearDown(playback.dispose);

    // The list screen, and a button that opens the conversation — which is what a tap on a row does.
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => conversationRoute(playback)),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    // Nothing is playing when the route is pushed. This is the ordinary case: the user opens a thread and
    // only then taps a note.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(iconOf(tester), Icons.play_arrow, reason: 'nothing is playing yet');

    // The note starts, after the route exists. A snapshot cannot express this.
    playback.set('note-1', 0);
    await tester.pump();

    expect(iconOf(tester), Icons.pause,
        reason: 'a note started after the route was pushed has to reach it, or the button never changes — '
            'which is the reported fault, and the reason it appeared on a phone and not in the two-pane '
            'layout, which rebuilds its pane as part of the shell');

    // And the position follows, which is what fills the wave.
    playback.set('note-1', 0.6);
    await tester.pump();
    expect(iconOf(tester), Icons.pause);

    // The note ends.
    playback.set(null, 0);
    await tester.pump();
    expect(iconOf(tester), Icons.play_arrow, reason: 'and the button comes back when it ends');
  });

  testWidgets('the mark survives going back and opening the thread again', (tester) async {
    // The other half of the same property: a route rebuilt from scratch has to read the current value, not
    // a stored one. A note that is playing while the user goes back to the list and returns has to still be
    // shown as playing — otherwise the interface contradicts the audio.
    final playback = PlaybackController();
    addTearDown(playback.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => conversationRoute(playback)),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    playback.set('note-1', 0.25);
    await tester.pump();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(iconOf(tester), Icons.pause,
        reason: 'a note already playing has to be shown as playing when the thread is opened');
  });
}
