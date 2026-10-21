import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../app/log_book.dart';
import '../crypto/cipher.dart';
import '../crypto/crypto_engine.dart';
import '../crypto/key_vault.dart';

/// Where DarkFlow keeps its files on disk.
///
/// Everything below [root] is either ciphertext or a header that contains only
/// wrapped keys. Nothing in here is readable without the master key, which is
/// why the app can honestly say "all your data is encrypted with your password"
/// rather than "your database is encrypted, but your attachments are not".
class VaultPaths {
  VaultPaths(this.root);

  /// The application support directory, plus `darkflow`.
  final Directory root;

  /// Resolves the standard location for the current platform.
  static Future<VaultPaths> resolve() async {
    final support = await getApplicationSupportDirectory();
    return VaultPaths(
      Directory('${support.path}${Platform.pathSeparator}darkflow'),
    );
  }

  // Every path below interpolates `root.path`, never `root`: a Directory's
  // `toString` renders as `Directory: 'C:\…'`, so using the object directly
  // produces file names that contain a quoted drive path and fail on Windows
  // with errno 123. The test suite caught exactly that.
  File get headerFile => File('${root.path}${Platform.pathSeparator}vault.json');

  Directory get recordsDirectory =>
      Directory('${root.path}${Platform.pathSeparator}records');

  File collectionLog(String collection) => File(
        '${recordsDirectory.path}${Platform.pathSeparator}$collection.log',
      );

  /// Attachment ciphertext, one file per attachment.
  Directory get filesDirectory =>
      Directory('${root.path}${Platform.pathSeparator}files');

  /// Decrypted working copies. Emptied whenever the vault locks.
  Directory get cacheDirectory =>
      Directory('${root.path}${Platform.pathSeparator}cache');

  /// Tor's data directory, its hidden-service keys and its cookie file.
  Directory get torDirectory => Directory('${root.path}${Platform.pathSeparator}tor');

  /// Writes a small file so that a crash cannot leave a half-written one.
  ///
  /// The header holds the *only* copy of the wrapped master key. Writing it with
  /// a plain `writeAsString` — which truncates the target first — means a power
  /// loss or a crash in the middle of those few hundred bytes leaves a truncated
  /// `vault.json`, and the account is then unrecoverable: there is no other copy
  /// of the wrapped key anywhere, by design. Writing to a sibling and renaming it
  /// over the target makes the change atomic, so the file is either the old one or
  /// the new one and never something in between.
  Future<void> writeFileAtomically(File target, String contents) async {
    await ensureCreated();
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(target.path);
  }

  Future<void> ensureCreated() async {
    for (final directory in <Directory>[
      root,
      recordsDirectory,
      filesDirectory,
      cacheDirectory,
      torDirectory,
    ]) {
      if (!directory.existsSync()) {
        await directory.create(recursive: true);
      }
    }
  }

  /// Deletes decrypted working copies. Called on every lock, so a stolen disk
  /// does not also hand over the last opened photo.
  ///
  /// The whole walk is guarded, not only each delete. `existsSync` followed by `list` is
  /// a check-then-use, and the gap between them is real: the directory can be removed
  /// underneath us, and on Windows a path with no parent raises `PathNotFoundException`
  /// rather than returning an empty listing. That reached the user as a crash while
  /// *locking* — the one moment a messenger must not throw, because the user has asked it
  /// to close and the vault is already half torn down.
  ///
  /// Nothing here is worth failing a lock over: the cache holds decrypted copies, and the
  /// worst case of a missed delete is that the next unlock re-encrypts over them.
  Future<void> purgeCache() async {
    if (!cacheDirectory.existsSync()) return;
    try {
      await for (final entity in cacheDirectory.list()) {
        try {
          await entity.delete(recursive: true);
        } on FileSystemException {
          // A file still held open by a media player is not worth failing over.
        }
      }
    } on FileSystemException {
      // The directory went away between the check and the listing.
    }
  }

  /// The on-disk size of the vault, for the storage screen.
  Future<int> totalBytes() async {
    var total = 0;
    if (!root.existsSync()) return 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }
}

/// The encrypted record store.
///
/// Each collection is an append-only log of sealed records:
///
/// ```text
///   magic "DF"  version (1)  reserved      length: uint32 little-endian
///   ────────────────────────────────────────────────────────────────────
///   sealed record:  version | nonce | ciphertext | GCM tag
/// ```
///
/// Appending rather than rewriting means a message arriving never rewrites the
/// whole history, and a crash mid-write can only damage the final record, which
/// the reader detects and drops. The associated data of every record includes
/// its collection and its id, so a record cannot be moved between collections,
/// between accounts, or replayed under a different key.
///
/// Compaction runs when the log has grown to twice the live set; the compacted
/// file is written next to the original and swapped in atomically, so an
/// interrupted compaction leaves the previous log intact.
class VaultStore {
  // The engine is assigned rather than taken as an initialising formal so that
  // callers write `engine:` instead of `_engine:`.
  // ignore: prefer_initializing_formals
  VaultStore({required this.paths, required CryptoEngine engine}) : _engine = engine;

  final VaultPaths paths;
  final CryptoEngine _engine;

  MasterKeyRing? _ring;
  final Map<String, Map<String, Map<String, dynamic>>> _collections =
      <String, Map<String, Map<String, dynamic>>>{};
  final Map<String, int> _logSizes = <String, int>{};
  final Map<String, int> _appendedBytes = <String, int>{};
  final Map<String, IOSink> _sinks = <String, IOSink>{};
  final StreamController<String> _changes = StreamController<String>.broadcast();

  static const List<int> _magic = <int>[0x44, 0x46, 0x01, 0x00];

  /// Emits the collection name whenever it changes.
  Stream<String> get changes => _changes.stream;

  bool get isOpen => _ring != null && !_closed;

  /// Unlocks the store with the master key ring. Loading is lazy per
  /// collection, so unlocking is instant no matter how much history exists.
  Future<void> open(MasterKeyRing ring) async {
    await paths.ensureCreated();
    // A previous ring's records must not survive into this one.
    //
    // `_ensureLoaded` returns early for a collection it has already read, so
    // opening the same store with a *different* key — switching accounts without
    // an intervening `close` — would have handed the new account the previous
    // account's decrypted records, and appended its writes to the same file under
    // a different key. `AppController.lock` closes first, which is why this never
    // showed; the store should not depend on its caller for that.
    if (_ring != null) await close();
    _ring = ring;
    // Reopened for business. `close` sets this and nothing else clears it, so without the reset a
    // store that had ever been closed would refuse every write for the rest of the process —
    // which is what "unlock, then nothing saves" would look like.
    _closed = false;
  }

  /// Closes every open file handle and forgets the decrypted records.
  ///
  /// It drops its reference to the key ring rather than wiping it, because the
  /// ring is not the store's to destroy: `MasterKeyRing` is handed in and may
  /// outlive the store (the tests reopen a vault with the same ring), and zeroing
  /// it here would silently break that. `AppController.lock` destroys the ring
  /// itself, which is the owner's job.
  Future<void> close() async {
    // The door is shut **first**, then the queue is drained, then the sinks are closed.
    //
    // All three steps are needed and the order is the whole point. Draining alone is not enough:
    // between the queue emptying and the sinks closing, an in-flight caller can queue another
    // write — `sendText` is not awaited by whoever locked the vault — and that write then races
    // the closing flush with the same `Bad state: StreamSink is bound to a stream`, losing the
    // record. Refusing new writes first makes the queue's emptiness final.
    _closed = true;
    await _drainWrites();

    for (final sink in _sinks.values) {
      try {
        await sink.flush();
        await sink.close();
      } on Object catch (error) {
        // A sink that refuses to close is not worth failing a lock over: the file is already
        // flushed by every write, and the vault is being torn down either way.
        logStorage('a record sink did not close cleanly', detail: '$error');
      }
    }
    _sinks.clear();
    _collections.clear();
    _logSizes.clear();
    _appendedBytes.clear();
    _ring = null;
    await paths.purgeCache();
  }

  /// True once [close] has begun. New writes are refused from that point.
  bool _closed = false;

  /// Waits for every queued write to finish, and reports whether any failed.
  ///
  /// Each link in the chain already swallows its own error so the collection stays usable; this
  /// only needs to know that nothing is still running.
  Future<void> _drainWrites() async {
    while (_writeQueue.isNotEmpty) {
      final pending = List<Future<void>>.of(_writeQueue.values);
      _writeQueue.clear();
      for (final write in pending) {
        try {
          await write;
        } on Object {
          // `_appendRaw` records the failure; the queue must not stop on it.
        }
      }
    }
  }

  /// Every live record of [collection], newest write winning.
  Future<List<Map<String, dynamic>>> readAll(String collection) async {
    await _ensureLoaded(collection);
    return _collections[collection]!.values
        .map((record) => Map<String, dynamic>.from(record))
        .toList(growable: false);
  }

  /// A single record by id, or null.
  Future<Map<String, dynamic>?> read(String collection, String id) async {
    await _ensureLoaded(collection);
    final record = _collections[collection]![id];
    return record == null ? null : Map<String, dynamic>.from(record);
  }

  /// Inserts or replaces a record. [record] must carry a string `id`.
  Future<void> put(String collection, Map<String, dynamic> record) async {
    final ring = _requireRing();
    final id = record['id'];
    if (id is! String || id.isEmpty) {
      throw ArgumentError.value(id, 'record[id]', 'every record needs a string id');
    }
    await _ensureLoaded(collection);
    _collections[collection]![id] = Map<String, dynamic>.from(record);
    await _append(collection, id, record, ring);
    _changes.add(collection);
  }

  /// Writes many records with a single flush.
  Future<void> putAll(String collection, Iterable<Map<String, dynamic>> records) async {
    final ring = _requireRing();
    await _ensureLoaded(collection);
    for (final record in records) {
      final id = record['id'];
      if (id is! String || id.isEmpty) continue;
      _collections[collection]![id] = Map<String, dynamic>.from(record);
      await _append(collection, id, record, ring);
    }
    await flush(collection);
    _changes.add(collection);
  }

  /// Removes a record by appending a tombstone.
  Future<void> delete(String collection, String id) async {
    final ring = _requireRing();
    await _ensureLoaded(collection);
    if (_collections[collection]!.remove(id) == null) return;
    await _appendRaw(
      collection,
      Cipher.seal(
        engine: _engine,
        key: ring.databaseKey,
        plaintext: utf8.encode(jsonEncode(<String, dynamic>{'id': id, '_deleted': true})),
        aad: Cipher.recordAad(collection, id),
      ),
      id: id,
    );
    _changes.add(collection);
  }

  /// Replaces a whole collection, e.g. after a bulk edit.
  Future<void> replaceAll(String collection, Iterable<Map<String, dynamic>> records) async {
    final ring = _requireRing();
    await _ensureLoaded(collection);
    _collections[collection]!.clear();
    for (final record in records) {
      final id = record['id'];
      if (id is! String || id.isEmpty) continue;
      _collections[collection]![id] = Map<String, dynamic>.from(record);
      await _append(collection, id, record, ring);
    }
    await compact(collection);
  }

  /// Flushes pending writes for [collection], or for every open collection.
  ///
  /// Waits for the write queue first. Flushing a sink with a record still queued behind it does
  /// not flush that record, and compaction reads the file — so a compaction that ran before the
  /// queued write landed would rewrite the log without it. That is a quiet way to lose the last
  /// thing written.
  Future<void> flush([String? collection]) async {
    await _drainWrites();
    if (collection != null) {
      await _sinks[collection]?.flush();
      await _maybeCompact(collection);
      return;
    }
    for (final name in _sinks.keys.toList(growable: false)) {
      await _sinks[name]?.flush();
      await _maybeCompact(name);
    }
  }

  /// Rewrites [collection] so the log holds exactly the live set.
  Future<void> compact(String collection) async {
    // Everything already accepted has to be on disk, or the rewrite below — which builds the new
    // log from what it reads — would drop it.
    await _drainWrites();
    final ring = _requireRing();
    await _ensureLoaded(collection);

    final target = paths.collectionLog(collection);
    final temporary = File('${target.path}.compacting');
    final sink = temporary.openWrite();
    try {
      for (final entry in _collections[collection]!.entries) {
        final sealed = Cipher.seal(
          engine: _engine,
          key: ring.databaseKey,
          plaintext: utf8.encode(jsonEncode(entry.value)),
          aad: Cipher.recordAad(collection, entry.key),
        );
        // The id must be framed alongside the ciphertext, or the reader cannot
        // reconstruct the associated data and every record is discarded.
        sink.add(_frame(sealed, id: entry.key));
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    await _sinks.remove(collection)?.close();
    // One rename, and no delete first.
    //
    // This used to delete the live log and *then* rename the replacement over it.
    // Those are two separate operations, so a crash or a power loss in between
    // left no `<collection>.log` at all: the only surviving copy would be the
    // ignored `.compacting` file, `_ensureLoaded` would find nothing, and the whole
    // collection — every message, contact and attachment record in it — would be
    // gone. The comment above claimed the opposite of what the code did.
    //
    // `File.rename` replaces an existing target on every platform DarkFlow
    // targets (verified on Windows, which is the one that could plausibly differ),
    // so the delete was both unnecessary and the source of the hazard.
    await temporary.rename(target.path);
    _appendedBytes[collection] = 0;
    _logSizes[collection] = await target.length();
  }

  // ------------------------------------------------------------- internals

  MasterKeyRing _requireRing() {
    final ring = _ring;
    if (ring == null) {
      throw StateError('The vault is locked; call open() with a master key ring first.');
    }
    return ring;
  }

  Future<void> _ensureLoaded(String collection) async {
    if (_collections.containsKey(collection)) return;
    _requireRing();

    final live = <String, Map<String, dynamic>>{};
    final file = paths.collectionLog(collection);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      var offset = 0;
      while (offset + 8 <= bytes.length) {
        if (bytes[offset] != _magic[0] ||
            bytes[offset + 1] != _magic[1] ||
            bytes[offset + 2] != _magic[2] ||
            bytes[offset + 3] != _magic[3]) {
          // A torn write at the tail: stop rather than guess.
          break;
        }
        final length =
            ByteData.sublistView(bytes, offset + 4, offset + 8).getUint32(0, Endian.little);
        final start = offset + 8;
        final end = start + length;
        if (length < 2 || end > bytes.length) break;
        offset = end;

        // payload = [formatVersion][idLength][id…][sealed…]
        final payload = Uint8List.sublistView(bytes, start, end);
        final idLength = payload[1];
        if (2 + idLength >= payload.length) continue;
        // Decoded as UTF-8, matching `_frame`, which writes the id with
        // `utf8.encode`. `String.fromCharCodes` maps each byte to a code point, so
        // any id containing a non-ASCII character came back different — and since
        // the id is part of the record's associated data, the rebuilt AAD no longer
        // matched the one used to seal and an intact record was dropped as
        // unauthentic. All ids in use today are ASCII, which is what kept this
        // quiet.
        final id = utf8.decode(payload.sublist(2, 2 + idLength));
        final sealed = Uint8List.sublistView(payload, 2 + idLength);

        final decoded = _tryDecode(sealed, collection, id);
        if (decoded == null) continue;
        if (decoded['_deleted'] == true) {
          live.remove(id);
        } else {
          live[id] = decoded;
        }
      }
      _logSizes[collection] = bytes.length;
      _appendedBytes[collection] = 0;
    } else {
      _logSizes[collection] = 0;
      _appendedBytes[collection] = 0;
    }

    _collections[collection] = live;
  }

  /// Opens one record, or returns null when it is not authentic for this
  /// collection — a swapped or truncated record is skipped, never guessed at.
  Map<String, dynamic>? _tryDecode(Uint8List sealed, String collection, String id) {
    final ring = _ring;
    if (ring == null) return null;
    try {
      final clear = Cipher.open(
        engine: _engine,
        key: ring.databaseKey,
        sealed: sealed,
        aad: Cipher.recordAad(collection, id),
      );
      final decoded = jsonDecode(utf8.decode(clear));
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } on Object {
      return null;
    }
  }

  Future<void> _append(
    String collection,
    String id,
    Map<String, dynamic> record,
    MasterKeyRing ring,
  ) async {
    final sealed = Cipher.seal(
      engine: _engine,
      key: ring.databaseKey,
      plaintext: utf8.encode(jsonEncode(record)),
      aad: Cipher.recordAad(collection, id),
    );
    await _appendRaw(collection, sealed, id: id);
  }

  /// Writes one record, one at a time per collection.
  ///
  /// ## Why the queue exists
  ///
  /// An `IOSink` accepts one stream at a time. Calling `add` while a previous `add`'s flush is
  /// still in flight throws `Bad state: StreamSink is bound to a stream`, and the record is lost —
  /// not delayed, not retried, gone.
  ///
  /// Two writes for the same collection really do overlap in this application. A single handshake
  /// writes a contact and a conversation, and `_rememberPeer` awaits the first before starting
  /// the second only when nothing else is happening; a handshake arriving while the user sends a
  /// message writes the message *and* the conversation beside it. This was found by
  /// `test/features/conversation_race_test.dart`, and it explains the reported symptom better than
  /// anything else did: the contact was created in memory, the write that would have made it
  /// survive threw, and it appeared in the list only after the next launch reloaded storage —
  /// "on the PC the contact only appears after a restart".
  ///
  /// Serialising per collection rather than globally matters: the collections are separate files,
  /// and the seal and frame work above this can stay parallel.
  final Map<String, Future<void>> _writeQueue = <String, Future<void>>{};

  Future<void> _appendRaw(String collection, Uint8List sealed, {String? id}) {
    // A write that arrives after the vault started closing is refused rather than queued. There
    // is no sink left for it that is not about to be closed, and attempting it produced the same
    // lost-record failure this queue exists to prevent.
    if (_closed) {
      return Future<void>.error(
        StateError('the vault is closing; the record was not written'),
      );
    }

    final frame = _frame(sealed, id: id);
    // Chained, not awaited inline: the next write waits for this one to finish, and a failure is
    // not allowed to poison the queue for everything after it.
    final queued = (_writeQueue[collection] ?? Future<void>.value())
        .then((_) => _writeFrame(collection, frame))
        .catchError((Object error) {
      // Swallowed here so one failed record does not block the collection for ever. The caller
      // still sees its own failure, because `_writeFrame` threw inside the chain it awaits.
      logStorage('a record could not be written', detail: '$error');
    });
    _writeQueue[collection] = queued;
    return queued;
  }

  Future<void> _writeFrame(String collection, Uint8List frame) async {
    final sink = await _sinkFor(collection);
    sink.add(frame);
    _appendedBytes[collection] = (_appendedBytes[collection] ?? 0) + frame.length;
    // Flush every record rather than relying on a later close.
    //
    // `IOSink` buffers, so without this a message written a moment before the
    // process dies is simply gone — which is exactly what happened: the account
    // record sat in the buffer and the log on disk stayed empty. The cost is one
    // small write per record, and a messenger that loses the last thing you
    // wrote is worse than one that writes a few extra times.
    await sink.flush();
  }

  Future<IOSink> _sinkFor(String collection) async {
    final existing = _sinks[collection];
    if (existing != null) return existing;
    await paths.recordsDirectory.create(recursive: true);
    final sink = paths.collectionLog(collection).openWrite(mode: FileMode.append);
    _sinks[collection] = sink;
    return sink;
  }

  /// `magic | payloadLength | version | idLength | id | sealed`.
  ///
  /// The id travels in the clear next to the ciphertext. It is a random 128-bit
  /// value that is not secret — it is already an index in memory — and having
  /// it here is what lets the id be bound into the record's associated data
  /// without the reader having to guess.
  Uint8List _frame(Uint8List sealed, {String? id}) {
    final idBytes = id == null ? Uint8List(0) : Uint8List.fromList(utf8.encode(id));
    if (idBytes.length > 255) {
      throw ArgumentError.value(id, 'id', 'record ids must fit in 255 bytes');
    }
    final payloadLength = 2 + idBytes.length + sealed.length;
    final out = Uint8List(8 + payloadLength);
    out.setRange(0, 4, _magic);
    ByteData.sublistView(out, 4, 8).setUint32(0, payloadLength, Endian.little);
    out[8] = 0x01;
    out[9] = idBytes.length;
    out.setRange(10, 10 + idBytes.length, idBytes);
    out.setRange(10 + idBytes.length, out.length, sealed);
    return out;
  }

  Future<void> _maybeCompact(String collection) async {
    final live = _collections[collection];
    if (live == null || live.isEmpty) return;
    final appended = _appendedBytes[collection] ?? 0;
    final onDisk = _logSizes[collection] ?? 0;
    // Compact once the log holds twice the data that is actually alive.
    final liveEstimate = live.length * 512;
    if (appended > 64 * 1024 && (onDisk + appended) > liveEstimate * 2) {
      await compact(collection);
    }
  }
}
