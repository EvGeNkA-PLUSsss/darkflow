import 'package:darkflow/src/data/models/message.dart';
import 'package:darkflow/src/design/design.dart';
import 'package:darkflow/src/features/chats/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The conversation screen's interactive behaviour: replying, and the scroll
/// behaviour that decides whether a reader keeps their place.
void main() {
  Widget host(Widget child) => MaterialApp(theme: AppTheme.build(), home: child);

  Message message(
    String id,
    String body, {
    bool outgoing = false,
    DateTime? at,
  }) =>
      Message(
        id: id,
        conversationId: 'c1',
        peerOnion: 'bob.onion',
        direction: outgoing ? MessageDirection.outgoing : MessageDirection.incoming,
        kind: MessageKind.text,
        createdAt: at ?? DateTime.utc(2026, 1, 1, 12),
        body: body,
        status: outgoing ? MessageStatus.delivered : MessageStatus.delivered,
      );

  group('replying', () {
    testWidgets('a double tap on a bubble starts a reply', (tester) async {
      // The gesture used to be wired to "copy the message text to the clipboard":
      // nothing appeared, nothing was quoted, and `Message.replyToId` was written
      // by nobody — so the quote-rendering branch in `MessageBubble` was dead code.
      await tester.pumpWidget(host(ChatScreen(
        peerName: 'Bob',
        messages: <Message>[message('m1', 'the original')],
        onSend: (_, _) => true,
        onAttach: () {},
        onReply: (_) {},
      )));

      expect(find.textContaining('Replying to'), findsNothing);

      await tester.tap(find.text('the original'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('the original'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Replying to'), findsOneWidget);
    });

    testWidgets('sending carries the id of the message being answered', (tester) async {
      String? text;
      String? replyToId;
      await tester.pumpWidget(host(ChatScreen(
        peerName: 'Bob',
        messages: <Message>[message('m1', 'the original')],
        onSend: (String t, String? id) {
          text = t;
          replyToId = id;
        return true;
        },
        onAttach: () {},
        onReply: (_) {},
      )));

      await tester.tap(find.text('the original'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('the original'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'and my answer');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      expect(text, 'and my answer');
      expect(replyToId, 'm1');
    });

    testWidgets('the reply target clears once the reply is sent', (tester) async {
      await tester.pumpWidget(host(ChatScreen(
        peerName: 'Bob',
        messages: <Message>[message('m1', 'the original')],
        onSend: (_, _) => true,
        onAttach: () {},
        onReply: (_) {},
      )));

      await tester.tap(find.text('the original'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('the original'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'answer');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // A reply that cannot be sent twice by accident: the bar is gone, so the
      // next message is a fresh one.
      expect(find.textContaining('Replying to'), findsNothing);
    });

    testWidgets('a reply is quoted on the bubble that carries it', (tester) async {
      await tester.pumpWidget(host(ChatScreen(
        peerName: 'Bob',
        messages: <Message>[
          message('m1', 'the original'),
          Message(
            id: 'm2',
            conversationId: 'c1',
            peerOnion: 'bob.onion',
            direction: MessageDirection.outgoing,
            kind: MessageKind.text,
            createdAt: DateTime.utc(2026, 1, 1, 12, 1),
            body: 'my answer',
            status: MessageStatus.delivered,
            replyToId: 'm1',
          ),
        ],
        onSend: (_, _) => true,
        onAttach: () {},
      )));

      // The quote resolves through the loaded thread, so both the original and the
      // quoting bubble show the same sentence.
      expect(find.text('the original'), findsNWidgets(2));
    });

    testWidgets('without the gesture no reply bar is shown', (tester) async {
      await tester.pumpWidget(host(ChatScreen(
        peerName: 'Bob',
        messages: <Message>[message('m1', 'the original')],
        onSend: (_, _) => true,
        onAttach: () {},
      )));

      await tester.tap(find.text('the original'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('the original'));
      await tester.pumpAndSettle();

      // A screen that does not offer replies does not pretend to.
      expect(find.textContaining('Replying to'), findsNothing);
    });
  });

  group('searching a conversation', () {
    List<Message> thread() => <Message>[
          message('m1', 'the wifi password is hunter2'),
          message('m2', 'unrelated chatter', outgoing: true),
          message('m3', 'and the address is 3g2upl4.onion'),
        ];

    testWidgets('the magnifier is offered only when there is a thread',
        (tester) async {
      await tester.pumpWidget(host(ChatScreen(
        peerName: 'Bob',
        messages: const <Message>[],
        onSend: (_, _) => true,
        onAttach: () {},
      )));
      // Nothing to search, so no control that would do nothing.
      expect(find.byTooltip('Search this conversation'), findsNothing);

      await tester.pumpWidget(host(ChatScreen(
        peerName: 'Bob',
        messages: thread(),
        onSend: (_, _) => true,
        onAttach: () {},
      )));
      expect(find.byTooltip('Search this conversation'), findsOneWidget);
    });

    testWidgets('typing filters the list and reports how much matched',
        (tester) async {
      await tester.pumpWidget(host(ChatScreen(
        peerName: 'Bob',
        messages: thread(),
        onSend: (_, _) => true,
        onAttach: () {},
      )));

      await tester.tap(find.byTooltip('Search this conversation'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(ChatScreen.searchFieldKey), 'wifi');
      await tester.pumpAndSettle();

      expect(find.text('the wifi password is hunter2'), findsOneWidget);
      expect(find.text('unrelated chatter'), findsNothing);
      expect(find.text('and the address is 3g2upl4.onion'), findsNothing);
      // The count is what tells the user the search is narrowing anything at all.
      expect(find.text('1 of 3'), findsOneWidget);
    });

    testWidgets('the search is case-insensitive', (tester) async {
      await tester.pumpWidget(host(ChatScreen(
        peerName: 'Bob',
        messages: thread(),
        onSend: (_, _) => true,
        onAttach: () {},
      )));
      await tester.tap(find.byTooltip('Search this conversation'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(ChatScreen.searchFieldKey), 'HUNTER2');
      await tester.pumpAndSettle();

      expect(find.text('the wifi password is hunter2'), findsOneWidget);
    });

    testWidgets('a search that matches nothing says so', (tester) async {
      await tester.pumpWidget(host(ChatScreen(
        peerName: 'Bob',
        messages: thread(),
        onSend: (_, _) => true,
        onAttach: () {},
      )));
      await tester.tap(find.byTooltip('Search this conversation'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(ChatScreen.searchFieldKey), 'nothing here says this');
      await tester.pumpAndSettle();

      // Distinct from "this thread is empty", which is a different fact.
      expect(find.textContaining('Nothing in this conversation matches'),
          findsOneWidget);
      expect(find.text('unrelated chatter'), findsNothing);
    });

    testWidgets('closing the search restores the whole thread', (tester) async {
      await tester.pumpWidget(host(ChatScreen(
        peerName: 'Bob',
        messages: thread(),
        onSend: (_, _) => true,
        onAttach: () {},
      )));
      await tester.tap(find.byTooltip('Search this conversation'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(ChatScreen.searchFieldKey), 'wifi');
      await tester.pumpAndSettle();
      expect(find.text('unrelated chatter'), findsNothing);

      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();

      expect(find.text('unrelated chatter'), findsOneWidget);
      expect(find.text('and the address is 3g2upl4.onion'), findsOneWidget);
      // And the strip is gone, so the composer is the only field again.
      expect(find.byKey(ChatScreen.searchFieldKey), findsNothing);
    });

    testWidgets('the search term is marked inside the message', (tester) async {
      await tester.pumpWidget(host(ChatScreen(
        peerName: 'Bob',
        messages: thread(),
        onSend: (_, _) => true,
        onAttach: () {},
      )));
      await tester.tap(find.byTooltip('Search this conversation'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(ChatScreen.searchFieldKey), 'hunter2');
      await tester.pumpAndSettle();

      // The marking is a separate span with a background, which is the only way a
      // filtered list explains *why* each entry survived the filter.
      // The span tree is walked rather than inspected one level deep: the app's
      // `DefaultTextStyle` wrapper nests the bubble's own `TextSpan` inside
      // another one, so the marked span is not a direct child of the root.
      final found = <String>[];
      void walk(InlineSpan span) {
        if (span is TextSpan) {
          if (span.style?.backgroundColor != null && span.text != null) {
            found.add(span.text!);
          }
          for (final child in span.children ?? const <InlineSpan>[]) {
            walk(child);
          }
        }
      }

      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        walk(rich.text);
      }
      expect(found, <String>['hunter2']);
    });

    testWidgets('a message keeps its body when nothing is being searched',
        (tester) async {
      await tester.pumpWidget(host(ChatScreen(
        peerName: 'Bob',
        messages: <Message>[message('m1', 'plain body')],
        onSend: (_, _) => true,
        onAttach: () {},
      )));
      await tester.pumpAndSettle();
      expect(find.text('plain body'), findsOneWidget);
    });
  });

  group('reading history', () {
    testWidgets('a short thread opens without complaint', (tester) async {
      await tester.pumpWidget(host(ChatScreen(
        peerName: 'Bob',
        messages: <Message>[message('m1', 'hello')],
        onSend: (_, _) => true,
        onAttach: () {},
      )));
      await tester.pumpAndSettle();
      expect(find.text('hello'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty thread is fine', (tester) async {
      await tester.pumpWidget(host(ChatScreen(
        peerName: 'Bob',
        messages: const <Message>[],
        onSend: (_, _) => true,
        onAttach: () {},
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('several days of history get separators', (tester) async {
      await tester.pumpWidget(host(ChatScreen(
        peerName: 'Bob',
        messages: <Message>[
          message('m1', 'yesterday', at: DateTime.now().toUtc().subtract(const Duration(days: 1))),
          message('m2', 'today', at: DateTime.now().toUtc()),
        ],
        onSend: (_, _) => true,
        onAttach: () {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
    });
  });
}
