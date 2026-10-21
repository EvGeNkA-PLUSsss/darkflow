import 'package:darkflow/src/app/app_controller.dart';
import 'package:darkflow/src/app/app_scope.dart';
import 'package:darkflow/src/design/design.dart';
import 'package:darkflow/src/features/profile/contact_actions_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The management sheet is where a contact is renamed, cleared and deleted, and
/// it is reached from both layouts. Two things have to hold: the choice the user
/// makes is the one that reaches the account layer, and no destructive action
/// runs before its consequence has been stated and confirmed.
void main() {
  Widget host({
    String displayName = 'Bob',
    int messageCount = 0,
    Future<bool> Function(String displayName)? onRename,
    VoidCallback? onClearHistory,
    Future<void> Function()? onDelete,
  }) {
    return MaterialApp(
      theme: AppTheme.build(),
      home: AppScope(
        controller: AppController(),
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: ContactActionsSheet(
            displayName: displayName,
            messageCount: messageCount,
            onRename: onRename ?? (String name) async => true,
            onClearHistory: onClearHistory ?? () {},
            onDelete: onDelete ?? () async {},
          ),
        ),
      ),
    );
  }

  testWidgets('the three rows are offered, and only what can act', (tester) async {
    await tester.pumpWidget(host(messageCount: 4));
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Clear chat history'), findsOneWidget);
    expect(find.text('4 messages'), findsOneWidget);
    expect(find.text('Delete contact'), findsOneWidget);

    // Nothing is rendered for an empty thread: there is nothing to clear.
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text('Clear chat history'), findsNothing);
    expect(find.text('Rename'), findsOneWidget);
  });

  testWidgets('an accepted rename reports the trimmed name and closes the sheet',
      (tester) async {
    String? handed;
    await tester.pumpWidget(host(
      onRename: (String displayName) async {
        handed = displayName;
        return true;
      },
    ));

    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    // Pre-filled with the current name, which is the whole point of a rename as
    // opposed to a delete-and-re-add.
    final field = find.byType(TextFormField);
    expect(tester.widget<TextFormField>(field).controller!.text, 'Bob');

    await tester.enterText(field, '  Robert  ');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(handed, 'Robert', reason: 'the account layer would otherwise store the spaces');
    expect(find.text('Delete contact'), findsNothing, reason: 'a rename closes the sheet');
  });

  testWidgets('a blank or overlong name cannot be submitted', (tester) async {
    var calls = 0;
    await tester.pumpWidget(host(
      onRename: (String displayName) async {
        calls++;
        return true;
      },
    ));

    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    final field = find.byType(TextFormField);
    final rename = find.widgetWithText(TextButton, 'Rename');

    await tester.enterText(field, '   ');
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(rename).onPressed, isNull);
    await tester.tap(rename, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(calls, 0);

    await tester.enterText(field, 'x' * (AppController.maxDisplayNameLength + 1));
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(rename).onPressed, isNull);
    expect(find.textContaining('At most'), findsOneWidget);
  });

  testWidgets('a rename the account layer refuses leaves the sheet open',
      (tester) async {
    await tester.pumpWidget(host(onRename: (String displayName) async => false));

    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Robert');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(
      find.text('Delete contact'),
      findsOneWidget,
      reason: 'a refused rename must not look like it worked',
    );
  });

  testWidgets('clearing says what it destroys and only runs on confirmation',
      (tester) async {
    var cleared = 0;
    await tester.pumpWidget(host(messageCount: 2, onClearHistory: () => cleared++));

    await tester.tap(find.text('Clear chat history'));
    await tester.pumpAndSettle();
    expect(find.text('Clear chat history?'), findsOneWidget);
    expect(find.textContaining('no back-up'), findsOneWidget);
    expect(find.textContaining('The contact stays'), findsOneWidget);
    expect(cleared, 0);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cleared, 0, reason: 'cancelling is not clearing');

    await tester.tap(find.text('Clear chat history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();
    expect(cleared, 1);
  });

  testWidgets('deleting names the consequence and only runs on confirmation',
      (tester) async {
    var deleted = 0;
    await tester.pumpWidget(host(onDelete: () async => deleted++));

    await tester.tap(find.text('Delete contact'));
    await tester.pumpAndSettle();

    expect(find.text('Delete Bob?'), findsOneWidget);
    expect(find.textContaining('pinned identity key'), findsOneWidget);
    expect(find.textContaining('pinned onion address'), findsOneWidget);
    expect(find.textContaining('whole message history'), findsOneWidget);
    expect(find.textContaining('cannot be undone'), findsOneWidget);
    expect(find.textContaining('messages on the other side'), findsOneWidget);
    expect(deleted, 0);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deleted, 0, reason: 'cancelling is not deleting');

    await tester.tap(find.text('Delete contact'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(deleted, 1, reason: 'the confirmed delete has to reach the account layer');
  });

  testWidgets('the sheet can be opened the way the app opens it', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(),
      home: AppScope(
        controller: AppController(),
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => ContactActionsSheet.show(
                context,
                displayName: 'Bob',
                messageCount: 1,
                onRename: (String name) async => true,
                onClearHistory: () {},
                onDelete: () async {},
              ),
              child: const Text('manage'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('manage'));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Delete contact'), findsOneWidget);
  });
}
