import 'package:darkflow/src/app/app_controller.dart';
import 'package:darkflow/src/app/app_scope.dart';
import 'package:darkflow/src/data/models/message.dart';
import 'package:darkflow/src/design/design.dart';
import 'package:darkflow/src/features/chats/chat_screen.dart';
import 'package:darkflow/src/features/chats/chats_screen.dart';
import 'package:darkflow/src/features/chats/widgets/conversation_tile.dart';
import 'package:darkflow/src/features/shell/widgets/shell_sidebar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A conversation row and a conversation's top bar are the two places a user
/// starts from, and both exist twice — once in the phone layout and once in the
/// desktop shell. Every route into a contact's management has to be offered by
/// the shared widget both layouts use, or it is missing on one of them; that is
/// what happened to settings and to the account profile.
void main() {
  Widget host(Widget child) => MaterialApp(
        theme: AppTheme.build(),
        home: AppScope(
          controller: AppController(),
          child: Scaffold(backgroundColor: AppColors.background, body: child),
        ),
      );

  group('conversation row', () {
    testWidgets('a long press reports the pointer, a tap opens the thread',
        (tester) async {
      Offset? asked;
      var opened = 0;

      await tester.pumpWidget(host(ConversationTile(
        displayName: 'Bob',
        onTap: () => opened++,
        onMenuRequested: (Offset position) => asked = position,
      )));

      await tester.longPress(find.text('Bob'));
      await tester.pumpAndSettle();

      expect(asked, isNotNull, reason: 'a long press has to offer the menu');
      expect(opened, 0, reason: 'a long press is not a tap on the thread');

      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });

    testWidgets('a right click offers the same menu', (tester) async {
      var asked = 0;
      await tester.pumpWidget(host(ConversationTile(
        displayName: 'Bob',
        onTap: () {},
        onMenuRequested: (Offset position) => asked++,
      )));

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Bob')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      expect(asked, 1, reason: 'the desktop gesture is a secondary click');
    });

    testWidgets('without a menu the row only answers a tap', (tester) async {
      await tester.pumpWidget(host(const ConversationTile(
        displayName: 'Bob',
        onTap: _ignore,
      )));

      await tester.longPress(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('conversation top bar', () {
    Widget chat({VoidCallback? onOpenPeerProfile}) => ChatScreen(
          peerName: 'Bob',
          messages: const <Message>[],
          onSend: (_, _) => true,
          onAttach: () {},
          onOpenPeerProfile: onOpenPeerProfile,
        );

    testWidgets('tapping the peer opens the profile', (tester) async {
      var opened = 0;
      await tester.pumpWidget(host(chat(onOpenPeerProfile: () => opened++)));

      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(opened, 1, reason: 'the name in the top bar is the way in');
    });

    testWidgets('a null callback leaves the top bar inert', (tester) async {
      // The same rule as the profile's own row: no route, no target. A top bar
      // that swallows a tap without doing anything is worse than a plain one.
      await tester.pumpWidget(host(chat()));
      expect(find.text('Bob'), findsOneWidget);
      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
  group('the row menu in each layout', () {
    const summary = ConversationSummary(
      peerOnion: 'aabbccddeeffgghhiijjkkllmmnnooppqqrrssttuuvvwwxxyyzz2345onion',
      displayName: 'Bob',
    );

    testWidgets('the phone list offers the profile on a long press', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(host(ChatsScreen(
        conversations: const <ConversationSummary>[summary],
        onOpenConversation: (_) {},
        onAddContact: () {},
        onOpenContactProfile: opened.add,
      )));

      await tester.longPress(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(find.text('Contact profile'), findsOneWidget);

      await tester.tap(find.text('Contact profile'));
      await tester.pumpAndSettle();
      expect(
        opened,
        <String>[summary.peerOnion],
        reason: 'the menu has to carry the row it was opened on',
      );
    });

    testWidgets('the desktop sidebar offers the same item', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(host(ShellSidebar(
        conversations: const <ConversationSummary>[summary],
        selectedPeerOnion: null,
        onSelectConversation: (_) {},
        onAddContact: () {},
        onOpenSettings: () {},
        onOpenContactProfile: opened.add,
      )));

      await tester.longPress(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(find.text('Contact profile'), findsOneWidget);

      await tester.tap(find.text('Contact profile'));
      await tester.pumpAndSettle();
      expect(opened, <String>[summary.peerOnion]);
    });

    testWidgets('a list that cannot open a profile offers no menu', (tester) async {
      await tester.pumpWidget(host(ChatsScreen(
        conversations: const <ConversationSummary>[summary],
        onOpenConversation: (_) {},
        onAddContact: () {},
      )));

      await tester.longPress(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(find.text('Contact profile'), findsNothing);
    });
  });
}

void _ignore() {}
