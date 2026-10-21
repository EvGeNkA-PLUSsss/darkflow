import 'package:darkflow/src/design/design.dart';
import 'package:darkflow/src/features/common/text_prompt_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one-field editor used to rename a contact or the account.
///
/// Written because the account rename did not work at all. The dialog used to hold
/// its error message in a local variable captured by the closure handed to
/// `showDialog`, so `setState` rebuilt a subtree still reading the old null: an
/// empty name produced no message, the dialog did not close, and the renamed value
/// was never returned. Pressing Save looked like a dead button.
void main() {
  Widget host({required void Function(String?) onResult}) => MaterialApp(
        theme: AppTheme.build(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  final value = await promptForText(
                    context,
                    title: 'Your display name',
                    initialValue: 'Old Name',
                    hint: 'Display name',
                    help: 'Up to 64 characters.',
                    maxLength: 64,
                  );
                  onResult(value);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('starts with the current value', (tester) async {
    await tester.pumpWidget(host(onResult: (_) {}));
    await open(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Old Name',
    );
  });

  testWidgets('an empty name is refused, with a visible reason', (tester) async {
    var called = false;
    await tester.pumpWidget(host(onResult: (String? _) => called = true));
    await open(tester);

    await tester.enterText(find.byKey(const Key('text-prompt-field')), '   ');
    await tester.pump();
    await tester.tap(find.byKey(const Key('text-prompt-save')));
    await tester.pumpAndSettle();

    // The regression: no message appeared at all, and nothing was returned. The
    // dialog has to stay open and say why.
    expect(find.text('A value is required.'), findsOneWidget);
    expect(find.byKey(const Key('text-prompt-field')), findsOneWidget,
        reason: 'the dialog must stay open on a rejected value');
    expect(called, isFalse);
  });

  testWidgets('an over-long name is refused, with the real limit', (tester) async {
    var called = false;
    await tester.pumpWidget(host(onResult: (_) => called = true));
    await open(tester);

    await tester.enterText(
      find.byKey(const Key('text-prompt-field')),
      'x' * 65,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('text-prompt-save')));
    await tester.pumpAndSettle();

    expect(find.textContaining('longer than 64'), findsOneWidget);
    expect(called, isFalse);
  });

  testWidgets('a valid name is returned', (tester) async {
    String? result;
    await tester.pumpWidget(host(onResult: (String? value) => result = value));
    await open(tester);

    await tester.enterText(find.byKey(const Key('text-prompt-field')), '  New Name  ');
    await tester.pump();
    await tester.tap(find.byKey(const Key('text-prompt-save')));
    await tester.pumpAndSettle();

    // Trimmed, so a name that is only spaces around a word is not treated as
    // different from the same word.
    expect(result, 'New Name');
  });

  testWidgets('a name of exactly the limit is accepted', (tester) async {
    String? result;
    await tester.pumpWidget(host(onResult: (String? value) => result = value));
    await open(tester);

    final exact = 'x' * 64;
    await tester.enterText(find.byKey(const Key('text-prompt-field')), exact);
    await tester.pump();
    await tester.tap(find.byKey(const Key('text-prompt-save')));
    await tester.pumpAndSettle();

    expect(result, exact);
  });

  testWidgets('cancelling returns nothing', (tester) async {
    String? result = 'sentinel';
    await tester.pumpWidget(host(onResult: (String? value) => result = value));
    await open(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('Enter submits, which is what a one-field dialog invites',
      (tester) async {
    String? result;
    await tester.pumpWidget(host(onResult: (String? value) => result = value));
    await open(tester);

    await tester.enterText(find.byKey(const Key('text-prompt-field')), 'By Keyboard');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(result, 'By Keyboard');
  });

  testWidgets('the help text is replaced by the error, then restored',
      (tester) async {
    await tester.pumpWidget(host(onResult: (_) {}));
    await open(tester);
    expect(find.text('Up to 64 characters.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('text-prompt-field')), '');
    await tester.pump();
    await tester.tap(find.byKey(const Key('text-prompt-save')));
    await tester.pumpAndSettle();
    expect(find.text('A value is required.'), findsOneWidget);

    // Typing a value has to clear the complaint, not leave it sitting there.
    await tester.enterText(find.byKey(const Key('text-prompt-field')), 'Fine');
    await tester.pump();
    await tester.tap(find.byKey(const Key('text-prompt-save')));
    await tester.pumpAndSettle();
    expect(find.text('A value is required.'), findsNothing);
  });
}
