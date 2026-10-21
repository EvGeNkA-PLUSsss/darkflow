import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:darkflow/src/app/log_book.dart';

/// The suite's global test configuration. Flutter discovers this file by name and runs
/// [testExecutable] around the tests in every file.
///
/// ## Why this is needed
///
/// `AppController.bootstrap` attaches the log book to a file inside the vault directory. That
/// is right in the application and wrong in a test: the suite creates hundreds of temporary
/// vaults, each one then holds an open log file, and `Directory.delete` fails with
/// `PathAccessException: ... the file is occupied by another process` when a test tries to
/// clean up after itself. It presented as an unrelated failure in whichever test happened to
/// tidy up second, which is the worst kind of test failure to debug.
///
/// Replacing the book before each test keeps the logging code on the exercised path — every
/// `logXxx` call still runs, still records, and a test can read the entries — while nothing
/// touches a file unless a test asks for it by calling `attachTo` itself.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    debugSetLogBook(LogBook());
  });
  await testMain();
}
