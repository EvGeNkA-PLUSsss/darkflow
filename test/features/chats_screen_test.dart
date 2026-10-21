import 'package:darkflow/src/design/design.dart';
import 'package:darkflow/src/features/chats/chats_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The phone layout is `ChatsScreen` and nothing else, so anything reachable
/// only from the desktop sidebar is unreachable on a phone.
///
/// That is exactly what happened: settings and the profile were wired into
/// `DesktopShell` alone, which left a phone with no route to either. These
/// tests pin the entry points to the screen that the phone actually shows.
void main() {
  Widget host(Widget child) => MaterialApp(theme: AppTheme.build(), home: child);

  const conversations = <ConversationSummary>[];

  testWidgets('the header carries settings and profile when given them',
      (tester) async {
    var settings = 0;
    var profile = 0;

    await tester.pumpWidget(host(ChatsScreen(
      conversations: conversations,
      onOpenConversation: (_) {},
      onAddContact: () {},
      onOpenSettings: () => settings++,
      onOpenProfile: () => profile++,
    )));

    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    expect(find.byIcon(Icons.person_outline), findsOneWidget);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(settings, 1, reason: 'the gear must actually open settings');

    await tester.tap(find.byIcon(Icons.person_outline));
    await tester.pumpAndSettle();
    expect(profile, 1);
  });

  testWidgets('a null callback draws no control rather than a dead one',
      (tester) async {
    // The rule this codebase holds to: if there is nothing to do, there is
    // nothing to press.
    await tester.pumpWidget(host(ChatsScreen(
      conversations: conversations,
      onOpenConversation: (_) {},
      onAddContact: () {},
    )));

    expect(find.byIcon(Icons.settings_outlined), findsNothing);
    expect(find.byIcon(Icons.person_outline), findsNothing);
  });

  testWidgets('the title still renders alongside the two buttons',
      (tester) async {
    await tester.pumpWidget(host(ChatsScreen(
      conversations: conversations,
      onOpenConversation: (_) {},
      onAddContact: () {},
      onOpenSettings: () {},
      onOpenProfile: () {},
    )));

    expect(find.text('Chats'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
