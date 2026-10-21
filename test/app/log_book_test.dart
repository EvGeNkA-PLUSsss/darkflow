import 'dart:io';

import 'package:darkflow/src/app/log_book.dart';
import 'package:flutter_test/flutter_test.dart';

/// The log is what makes the next failure diagnosable instead of guessable.
///
/// Three faults in this project cost a release each because the report could not answer the
/// question being asked of it. These tests cover the properties that make the difference: that
/// entries are ordered and bounded, that addresses are shortened, and that the file is released
/// rather than left holding the vault directory open.
void main() {
  test('entries come back in the order they happened', () {
    final book = LogBook();
    book.add(LogCategory.tor, 'first');
    book.add(LogCategory.mesh, 'second');
    book.add(LogCategory.error, 'third');

    expect(
      book.entries.map((LogEntry entry) => entry.message),
      <String>['first', 'second', 'third'],
    );
    expect(book.length, 3);
  });

  test('the buffer is bounded, newest kept', () {
    // A phone that logs for a week must not run out of memory. The oldest entries go, because
    // the reason a report is being written is almost always the most recent thing.
    final book = LogBook(capacity: 5);
    for (var i = 0; i < 12; i++) {
      book.add(LogCategory.app, 'entry $i');
    }

    expect(book.length, 5);
    expect(book.entries.first.message, 'entry 7');
    expect(book.entries.last.message, 'entry 11');
  });

  test('a category is part of every line', () {
    final book = LogBook();
    book.add(LogCategory.network, 'dialling example.onion:80');

    expect(book.entries.single.format(), contains('network'));
    expect(book.entries.single.format(), contains('dialling example.onion:80'));
  });

  test('detail is indented under the line it belongs to', () {
    final book = LogBook();
    book.add(
      LogCategory.tor,
      'ports: socks=1 control=2',
      detail: 'first\nsecond',
    );

    final formatted = book.entries.single.format();
    expect(formatted.split('\n'), hasLength(3));
    expect(formatted, contains('    first'));
    expect(formatted, contains('    second'));
  });

  test('an onion address is shortened for the report', () {
    // A report is written to be sent to somebody else, and a full v3 address is a way to reach
    // the account. Eight characters are enough to match an entry against a conversation.
    const full = 'wi42nus6pqm4z7lphsjsgmuou3jnmmlb3czbokrpbou3zyhuav6bquqd.onion';
    expect(shortenOnion(full), 'wi42nus6…');
    expect(shortenOnion(full), isNot(contains('pqm4z7lphsjsgmuou3jnmmlb3czbokrpbou3zy')));
    expect(shortenOnion('short'), 'short');
    expect(shortenOnion(''), '');
  });

  group('the file', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('df-logbook-');
    });

    tearDown(() {
      if (root.existsSync()) {
        try {
          root.deleteSync(recursive: true);
        } on FileSystemException {
          // Left behind on purpose by a failing test; the assertion is about the handle.
        }
      }
    });

    test('is written and can be read back', () async {
      final book = LogBook();
      await book.attachTo(root);
      book.add(LogCategory.tor, 'starting the daemon');
      await book.flush();

      final file = book.file;
      expect(file, isNotNull);
      expect(file!.existsSync(), isTrue);
      final text = await file.readAsString();
      expect(text, contains('starting the daemon'));
      expect(text, contains('tor'));
    });

    test('detaching waits for the writes in flight, so the file can be deleted', () async {
      // The failure this guards: `detachFromFile` used to drop the reference without waiting,
      // so a write was still running and Windows refused to delete the vault directory with
      // "occupied by another process". It surfaced as an unrelated test failing.
      final book = LogBook();
      await book.attachTo(root);
      for (var i = 0; i < 40; i++) {
        book.add(LogCategory.mesh, 'entry $i');
      }

      await book.detachFromFile();

      // If a handle were still open this throws on Windows, which is the platform the failure
      // was reported on.
      root.deleteSync(recursive: true);
      expect(root.existsSync(), isFalse);
    });

    test('a write failure is reported rather than thrown', () async {
      // A log that cannot be written must never stop the application: the failure is recorded
      // in memory and reflected in the report, which is the honest thing to do.
      final book = LogBook();
      await book.attachTo(Directory('${root.path}${Platform.pathSeparator}missing-root'));
      book.add(LogCategory.error, 'something happened');
      await book.flush();

      expect(book.entries, hasLength(greaterThanOrEqualTo(1)));
      expect(book.describe(), contains('something happened'));
    });

    test('the report says where the file is', () async {
      final book = LogBook();
      await book.attachTo(root);
      book.add(LogCategory.app, 'unlocked');
      await book.flush();

      final report = book.describe();
      expect(report, contains('entries:'));
      expect(report, contains('file:'));
      expect(report, contains('unlocked'));
      await book.detachFromFile();
    });

    test('the report is bounded when there is a lot to say', () async {
      final book = LogBook(capacity: 100);
      for (var i = 0; i < 100; i++) {
        book.add(LogCategory.app, 'entry $i');
      }

      final report = book.describe(limit: 10);
      expect(report, contains('showing:       last 10'));
      expect(report, contains('entry 99'));
      expect(report, isNot(contains('entry 50')));
    });
  });
}
