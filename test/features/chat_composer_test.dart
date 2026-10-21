import 'package:darkflow/src/design/design.dart';
import 'package:darkflow/src/features/auth/widgets/password_strength_meter.dart';
import 'package:darkflow/src/features/chats/widgets/chat_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the parts of the composer and the password meter that
/// were broken in ways the existing suite could not see.
void main() {
  Widget host(Widget child) => MaterialApp(
        theme: AppTheme.build(),
        home: Scaffold(body: Column(children: <Widget>[child])),
      );

  group('the composer reports what it was given', () {
    testWidgets('a reply target is drawn, and cancelling removes it', (tester) async {
      var cancelled = 0;
      await tester.pumpWidget(
        host(
          ChatComposer(
            onSend: (_, _) => true,
            onAttach: () {},
            reply: const ComposerReply(
              id: 'message-1',
              author: 'Bob',
              text: 'the message being answered',
            ),
            onCancelReply: () => cancelled++,
          ),
        ),
      );

      expect(find.text('Replying to Bob'), findsOneWidget);
      expect(find.text('the message being answered'), findsOneWidget);

      await tester.tap(find.byTooltip('Cancel reply'));
      await tester.pumpAndSettle();
      expect(cancelled, 1);
    });

    testWidgets('the send carries the id of the message being answered', (tester) async {
      String? sentText;
      String? sentReplyTo;
      await tester.pumpWidget(
        host(
          ChatComposer(
            onSend: (String text, String? replyToId) {
              sentText = text;
              sentReplyTo = replyToId;
              return true;
            },
            onAttach: () {},
            reply: const ComposerReply(id: 'quoted-id', author: 'Bob', text: 'earlier'),
            onCancelReply: () {},
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'my answer');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // The quote only means anything to the peer if the id travels with the text.
      // Nothing ever set `replyToId`, so the whole reply feature was dead.
      expect(sentText, 'my answer');
      expect(sentReplyTo, 'quoted-id');
    });

    testWidgets('a draft is restored into the field', (tester) async {
      await tester.pumpWidget(
        host(
          ChatComposer(
            onSend: (_, _) => true,
            onAttach: () {},
            initialDraft: 'half a thought',
          ),
        ),
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'half a thought',
      );
    });

    testWidgets('a draft restored after the first build reaches the field',
        (tester) async {
      // The real sequence: the thread's history is loaded asynchronously, so the
      // first frame has no draft and the restored one arrives on a later build.
      Widget build(String draft) => host(
            ChatComposer(onSend: (_, _) => true, onAttach: () {}, initialDraft: draft),
          );

      await tester.pumpWidget(build(''));
      await tester.pumpWidget(build('typed while away'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'typed while away',
      );
    });

    testWidgets('typing reports the draft on every change', (tester) async {
      final drafts = <String>[];
      await tester.pumpWidget(
        host(
          ChatComposer(
            onSend: (_, _) => true,
            onAttach: () {},
            onDraftChanged: drafts.add,
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'a');
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'ab');
      await tester.pump();

      // Persisting only on send is what made a draft disappear when the thread was
      // closed, which is the one moment the feature exists for.
      expect(drafts, containsAllInOrder(<String>['a', 'ab']));
    });

    testWidgets('sending clears the field and reports an empty draft', (tester) async {
      final drafts = <String>[];
      await tester.pumpWidget(
        host(
          ChatComposer(
            onSend: (_, _) => true,
            onAttach: () {},
            onDraftChanged: drafts.add,
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'gone');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
      expect(drafts.last, isEmpty);
    });

    testWidgets('the microphone shows the recording state and counts up',
        (tester) async {
      var stopped = 0;
      await tester.pumpWidget(
        host(
          ChatComposer(
            onSend: (_, _) => true,
            onAttach: () {},
            onStartVoice: () async => true,
            onStopVoice: () => stopped++,
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.mic_none));
      await tester.pump();

      // The recording indicator and its stopwatch. A `recording` widget field
      // existed for this and no caller ever set it, so the elapsed time read
      // 00:00 for the whole note and never moved.
      expect(find.textContaining('Recording'), findsOneWidget);
      expect(find.text('00:00'), findsOneWidget);

      // One tick, then read the display again.
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('00:01'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();
      expect(stopped, 1);
      expect(find.textContaining('Recording'), findsNothing);
    });

    testWidgets('a refused recording says so instead of looking dead', (tester) async {
      await tester.pumpWidget(
        host(
          ChatComposer(
            onSend: (_, _) => true,
            onAttach: () {},
            onStartVoice: () async => false,
            onStopVoice: () {},
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.mic_none));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not start recording'), findsOneWidget);
    });

    testWidgets('a second tap while starting does not open a second recorder',
        (tester) async {
      var starts = 0;
      await tester.pumpWidget(
        host(
          ChatComposer(
            onSend: (_, _) => true,
            onAttach: () {},
            onStartVoice: () async {
              starts++;
              // Stands in for the platform permission call, which is what makes
              // the guard necessary: `_recording` cannot be set until this returns.
              await Future<void>.delayed(const Duration(milliseconds: 50));
              return true;
            },
            onStopVoice: () {},
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.mic_none));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.mic_none));
      await tester.pump(const Duration(milliseconds: 80));

      expect(starts, 1);
    });

    testWidgets('an in-flight file send is visible', (tester) async {
      await tester.pumpWidget(
        host(ChatComposer(onSend: (_, _) => true, onAttach: () {}, sending: true)),
      );
      // Encrypting a picked file is slow enough to look like a hang, so the
      // composer has to say something. Two spinners are correct: one where the
      // picker was opened from, one where the send control is.
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      // And the attach control must not accept a second pick while the first file
      // is still being sealed.
      expect(find.byIcon(Icons.attach_file), findsNothing);
    });
  });

  group('password advice matches what is enforced', () {
    test('the default floor is the vault floor', () {
      expect(kMinimumPasswordLength, 8);
    });

    test('a password under the floor is told the real number', () {
      for (final short in <String>['a', 'abcdef', 'abcdefg']) {
        final strength = PasswordStrength.of(short);
        expect(
          strength.hint,
          contains('at least $kMinimumPasswordLength'),
          reason: '"$short" is refused by the vault, so the meter must say why',
        );
      }
    });

    test('a password at the floor is no longer told it is too short', () {
      // The old meter said "Use at least 6 characters" and then, at exactly six,
      // "Mix letters, digits and symbols" — so a user who satisfied the advertised
      // rule was given different advice and a screen with no way forward.
      final strength = PasswordStrength.of('abcdefgh');
      expect(strength.hint, isNot(contains('at least')));
    });

    test('a caller can set its own floor', () {
      expect(
        PasswordStrength.of('abc', minimumLength: 3).hint,
        isNot(contains('at least')),
      );
      expect(
        PasswordStrength.of('abc', minimumLength: 12).hint,
        contains('at least 12'),
      );
    });

    test('the empty state names the floor too', () {
      expect(
        PasswordStrength.of('').hint,
        contains('at least $kMinimumPasswordLength'),
      );
    });
  });
}
