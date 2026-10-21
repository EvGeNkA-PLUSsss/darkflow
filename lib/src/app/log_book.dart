import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// What a log line is about.
///
/// Categories exist so a report can be filtered by hand without reading every line, and so a
/// reader can tell at a glance which layer stopped working. Their names are the layers of the
/// application, not its files: a connection problem shows up under `network` whether the code
/// that noticed it lives in a socket, a stream or a controller.
enum LogCategory {
  /// Starting, unlocking, locking, stage transitions.
  app,

  /// The daemon: configuration, process, bootstrap, control port.
  tor,

  /// Circuits, SOCKS dials, onion-service publication.
  network,

  /// Handshakes, envelopes, outbox, relays, delivery receipts.
  mesh,

  /// Contacts, conversations, message state, attachments.
  storage,

  /// Camera, permissions, scanning.
  scanner,

  /// Anything that should not have happened.
  error,
}

/// One recorded event.
@immutable
class LogEntry {
  const LogEntry({
    required this.at,
    required this.category,
    required this.message,
    this.detail,
  });

  final DateTime at;
  final LogCategory category;
  final String message;

  /// Extra lines, kept separate so the one-line summary stays scannable.
  final String? detail;

  /// `15:51:40.347 network  dialling wi42nus6…:80 through 127.0.0.1:39883`
  String format({bool withDate = false}) {
    final stamp = withDate ? at.toUtc().toIso8601String() : _time(at);
    final line = '$stamp ${category.name.padRight(7)} $message';
    final extra = detail;
    if (extra == null || extra.isEmpty) return line;
    return '$line\n${extra.split('\n').map((String part) => '    $part').join('\n')}';
  }

  static String _time(DateTime at) {
    final local = at.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}.'
        '${three(local.millisecond)}';
  }
}

/// Records what the application did, in order, and writes it where it can be found.
///
/// ## Why this exists
///
/// Three separate faults in this project were diagnosed from reports that could not answer the
/// question being asked of them. "The handshake does not complete" arrived as
/// `awaiting: 1 / no attempt has failed yet`, which is equally true of a dial in progress and
/// of a pump that never ran. "Tor error" arrived without the port Tor was actually listening
/// on. Each round cost a release to learn one fact.
///
/// So the rule here is that anything a future reader would have to guess at gets written down
/// at the moment it is known: which port was requested and which was bound, what was dialled
/// and through what, how long it took, and why it stopped. The buffer is bounded and the file
/// is rotated, because an unbounded log on a phone is a way to fill the disk.
///
/// ## What must never go in
///
/// Onion addresses are shortened to their first eight characters, because a full address is a
/// way to reach an account and this file is meant to be sent to somebody else. Keys, passwords
/// and message bodies are never logged at all — the helpers here take strings, and the callers
/// are responsible for not passing secrets, which the redaction below cannot detect.
class LogBook {
  LogBook({
    this.capacity = 2000,
    this.fileCapacity = 4000,
  });

  /// How many entries are kept in memory.
  final int capacity;

  /// How many entries the file is allowed to hold before it is trimmed.
  final int fileCapacity;

  final Queue<LogEntry> _entries = Queue<LogEntry>();
  final StreamController<LogEntry> _stream = StreamController<LogEntry>.broadcast();

  File? _file;
  bool _fileFailed = false;
  Future<void> _pending = Future<void>.value();

  /// Entries in the order they happened.
  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  int get length => _entries.length;

  /// Fires for every entry, for a live view.
  Stream<LogEntry> get stream => _stream.stream;

  /// Where the file is, once [attachTo] has been called.
  File? get file => _file;

  /// True when writing to a file was attempted and failed.
  ///
  /// Kept so the diagnostics report can say that its own log is incomplete, rather than
  /// presenting a truncated file as the whole story.
  bool get fileUnavailable => _fileFailed;

  /// Points the book at a file inside [directory], creating it if needed.
  ///
  /// Never throws: a log is a diagnostic aid, and an application that cannot start because it
  /// could not open its own log would be a worse failure than the one being investigated. A
  /// failure is recorded in memory and reflected by [fileUnavailable].
  Future<void> attachTo(Directory directory) async {
    try {
      if (!directory.existsSync()) await directory.create(recursive: true);
      _file = File('${directory.path}${Platform.pathSeparator}darkflow.log');
    } on Object catch (error) {
      _fileFailed = true;
      add(LogCategory.error, 'could not open the log file: $error');
    }
  }

  /// Records an event.
  void add(LogCategory category, String message, {String? detail}) {
    final entry = LogEntry(
      at: DateTime.now().toUtc(),
      category: category,
      message: message,
      detail: detail,
    );

    _entries.addLast(entry);
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    if (!_stream.isClosed) _stream.add(entry);

    // Serialised through a single future so two writes cannot interleave and produce a
    // half-line, and so the file is never touched after `close`.
    final file = _file;
    if (file == null || _fileFailed) return;
    _pending = _pending.then((_) => _write(file, entry)).catchError((Object error) {
      _fileFailed = true;
      debugPrint('darkflow log: $error');
    });
  }

  Future<void> _write(File file, LogEntry entry) async {
    try {
      await file.writeAsString(
        '${entry.format(withDate: true)}\n',
        mode: FileMode.append,
        flush: false,
      );
      // Trimmed occasionally rather than on every line: reading the whole file to count lines
      // is the expensive part, and a log that is a few hundred lines over its bound until the
      // next check is not a problem.
      if (_entries.length % 200 == 0) await _trim(file);
    } on Object {
      _fileFailed = true;
    }
  }

  Future<void> _trim(File file) async {
    try {
      if (!file.existsSync()) return;
      final lines = await file.readAsLines();
      if (lines.length <= fileCapacity) return;
      await file.writeAsString('${lines.sublist(lines.length - fileCapacity).join('\n')}\n');
    } on Object {
      // Leaving the file long is better than truncating it wrongly.
    }
  }

  /// Stops writing to the file and releases it.
  ///
  /// Called when the controller that owns the vault goes away. Without it the file stays open
  /// for the life of the process, which in the application means the vault directory cannot be
  /// removed or moved while DarkFlow runs, and in a test means every temporary vault leaks a
  /// handle and `Directory.delete` fails with `PathAccessException ... occupied by another
  /// process`. That failure appears in whichever test tidies up second, so it looks like a bug
  /// in an unrelated file.
  ///
  /// **Awaits the writes already in flight**, which is the whole point rather than a detail:
  /// dropping the reference is not the same as closing the handle, and a write that is still
  /// running holds the file open. Windows then refuses to delete it, which is exactly the
  /// failure this method exists to prevent.
  ///
  /// The in-memory entries are kept: a report written after the vault closed is still useful,
  /// and it is the file that has to go.
  Future<void> detachFromFile() async {
    try {
      await _pending;
    } on Object {
      // A failed write is recorded by `_write`; nothing more to do about it here.
    }
    _file = null;
    _fileFailed = false;
  }

  /// A section for the diagnostics report.
  ///
  /// Shortened addresses and newest-last order, because a report is read by a person who is
  /// looking for the last thing that happened.
  String describe({int limit = 400}) {
    final buffer = StringBuffer();
    buffer.writeln('entries:       ${_entries.length} of $capacity kept');
    final file = _file;
    if (file == null) {
      buffer.writeln('file:          not attached');
    } else if (_fileFailed) {
      buffer.writeln('file:          ${file.path} (writes failed; this report is partial)');
    } else {
      buffer.writeln('file:          ${file.path}');
    }

    final shown = _entries.length <= limit
        ? _entries.toList(growable: false)
        : _entries.toList(growable: false).sublist(_entries.length - limit);
    if (_entries.length > limit) {
      buffer.writeln('showing:       last $limit');
    }
    for (final entry in shown) {
      buffer.writeln('  ${entry.format()}');
    }
    return buffer.toString();
  }

  /// Waits for writes that are still in flight.
  Future<void> flush() => _pending;

  Future<void> close() async {
    await flush();
    await _stream.close();
  }
}

/// The application's single log book.
///
/// A library-level instance rather than one threaded through every constructor: the code that
/// most needs to log — a socket that failed, a port that was already taken — is often the code
/// furthest from the objects that own a reference. Tests replace it via [debugSetLogBook] so a
/// run does not write to the developer's own log file.
LogBook logBook = LogBook();

/// Replaces the global log book. For tests, which must not write to a real file.
@visibleForTesting
void debugSetLogBook(LogBook book) => logBook = book;

/// `wi42nus6…` — enough to match an entry against a conversation, not enough to dial.
String shortenOnion(String onion) =>
    onion.length <= 8 ? onion : '${onion.substring(0, 8)}…';

/// Convenience wrappers, so a call site reads as one line.
void logApp(String message, {String? detail}) =>
    logBook.add(LogCategory.app, message, detail: detail);

void logTor(String message, {String? detail}) =>
    logBook.add(LogCategory.tor, message, detail: detail);

void logNetwork(String message, {String? detail}) =>
    logBook.add(LogCategory.network, message, detail: detail);

void logMesh(String message, {String? detail}) =>
    logBook.add(LogCategory.mesh, message, detail: detail);

void logStorage(String message, {String? detail}) =>
    logBook.add(LogCategory.storage, message, detail: detail);

void logScanner(String message, {String? detail}) =>
    logBook.add(LogCategory.scanner, message, detail: detail);

void logError(String message, {String? detail}) =>
    logBook.add(LogCategory.error, message, detail: detail);
