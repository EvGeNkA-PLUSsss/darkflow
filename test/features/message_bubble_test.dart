import 'package:darkflow/src/data/models/message.dart';
import 'package:darkflow/src/design/design.dart';
import 'package:darkflow/src/features/chats/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A clock glyph says "not delivered" and nothing more, which is how a message
/// with no route at all came to look identical to one that was on its way. The
/// mesh reports the difference; the bubble has to show it.
void main() {
  Widget host(Widget child) => MaterialApp(theme: AppTheme.build(), home: Scaffold(body: child));

  testWidgets('an undelivered message explains itself', (tester) async {
    await tester.pumpWidget(host(const MessageBubble(
      text: 'pи',
      outgoing: true,
      status: MessageStatus.queued,
      note: 'No route yet.',
    )));

    expect(find.text('pи'), findsOneWidget);
    expect(find.text('No route yet.'), findsOneWidget);
  });

  testWidgets('a delivered message stays clean', (tester) async {
    await tester.pumpWidget(host(const MessageBubble(
      text: 'pи',
      outgoing: true,
      status: MessageStatus.delivered,
    )));

    expect(find.text('pи'), findsOneWidget);
    // Nothing to explain, so nothing is added.
    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('an incoming message never carries a sending note', (tester) async {
    await tester.pumpWidget(host(const MessageBubble(
      text: 'hello',
      outgoing: false,
      status: null,
      note: null,
    )));

    expect(find.text('hello'), findsOneWidget);
    expect(find.byType(Text), findsOneWidget);
  });
}
