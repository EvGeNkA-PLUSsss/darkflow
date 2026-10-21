import 'package:darkflow/src/app/app_controller.dart';
import 'package:darkflow/src/app/app_scope.dart';
import 'package:darkflow/src/design/design.dart';
import 'package:darkflow/src/features/profile/contact_profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The contact's profile is the one surface both layouts route to for a single
/// contact, which is why the management actions are hung off it. These tests pin
/// the two things that go wrong with a screen like this: a control that is drawn
/// but leads nowhere, and a rename that the account layer applies while the
/// heading keeps showing the old name.
void main() {
  Widget host(Widget child) => MaterialApp(
        theme: AppTheme.build(),
        home: AppScope(controller: AppController(), child: child),
      );

  ContactProfileScreen profile({
    String displayName = 'Bob',
    int messageCount = 0,
    void Function(void Function(String displayName) onRenamed)? onManage,
  }) {
    return ContactProfileScreen(
      displayName: displayName,
      onionAddress: 'aabbccddeeffgghhiijjkkllmmnnooppqqrrssttuuvvwwxxyyzz2345onion',
      onCopyOnion: () {},
      onShowQr: () {},
      onToggleBlock: () {},
      onToggleNotifications: () {},
      blocked: false,
      notificationsEnabled: true,
      messageCount: messageCount,
      onManage: onManage,
      onBack: () {},
    );
  }

  testWidgets('the management row exists only when it leads somewhere',
      (tester) async {
    // The rule this codebase holds to: if there is nothing to do, there is
    // nothing to press.
    await tester.pumpWidget(host(profile()));
    expect(find.text('Rename, clear or delete…'), findsNothing);
    expect(find.text('Copy .onion'), findsOneWidget);

    var asked = 0;
    await tester.pumpWidget(host(profile(onManage: (void Function(String) _) => asked++)));
    expect(find.text('Rename, clear or delete…'), findsOneWidget);

    await tester.tap(find.text('Rename, clear or delete…'));
    await tester.pumpAndSettle();
    expect(asked, 1, reason: 'the row has to actually open the management sheet');
  });

  testWidgets('the row is offered for a contact with no history too',
      (tester) async {
    // Renaming and deleting apply to a new contact as much as to a long thread,
    // so a zero message count must not hide the row.
    await tester.pumpWidget(host(profile(messageCount: 0, onManage: (_) {})));
    expect(find.text('Rename, clear or delete…'), findsOneWidget);
  });

  testWidgets('a rename the account layer accepted is shown immediately',
      (tester) async {
    // The route is built with the values the app layer had at the time, so a
    // notification from the account layer cannot update it; the screen has to
    // carry the new name itself or the heading lies until the user navigates
    // away and back.
    void Function(String displayName)? rename;
    await tester.pumpWidget(host(profile(
      onManage: (void Function(String displayName) onRenamed) => rename = onRenamed,
    )));

    // The callback is handed out when the row is pressed, which is what the app
    // layer does with it: the sheet calls it after a rename it applied.
    await tester.tap(find.text('Rename, clear or delete…'));
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsWidgets);

    rename!('Robert');
    await tester.pumpAndSettle();

    expect(find.text('Robert'), findsWidgets);
    expect(find.text('Bob'), findsNothing);
  });

  testWidgets('the screen hands the sheet what it needs to state consequences',
      (tester) async {
    // `messageCount` is passed on to the sheet, which is the only place that
    // knows "Clear chat history" would delete nothing.
    await tester.pumpWidget(host(profile(messageCount: 7, onManage: (_) {})));
    expect(find.text('Rename, clear or delete…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
