import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A reply to a control-port command.
///
/// Tor answers with a numeric status, an optional space-separated body, and for
/// multi-line replies, a list of lines each carrying its own status.
class TorControlReply {
  const TorControlReply({required this.status, required this.lines});

  /// 250 for success, 5xx for failure, 6xx for an asynchronous event.
  final int status;

  /// The raw reply lines, without the trailing status code.
  final List<String> lines;

  bool get isOk => status >= 200 && status < 300;

  /// The body of a single-line reply, e.g. `OK` for `250 OK`.
  String get value => lines.isEmpty ? '' : lines.first;

  /// Parses a `KEY=VALUE` body, tolerating quoted values and multiple keys.
  Map<String, String> get keyValues {
    final out = <String, String>{};
    for (final line in lines) {
      final match = RegExp(r'^([A-Za-z0-9_/.-]+)=(.*)$').firstMatch(line);
      if (match != null) {
        out[match.group(1)!] = _unquote(match.group(2)!);
      }
    }
    return out;
  }

  static String _unquote(String value) {
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      return value.substring(1, value.length - 1).replaceAll(r'\"', '"');
    }
    return value;
  }

  @override
  String toString() => 'TorControlReply($status, ${lines.join(' | ')})';
}

/// An asynchronous notification pushed by Tor on the control connection.
class TorControlEvent {
  const TorControlEvent({required this.keyword, required this.body});

  /// `STATUS_CLIENT`, `NOTICE`, `WARN`, `ERR`, `NEWCONSENSUS`, …
  final String keyword;

  /// Everything after the keyword, e.g. `BOOTSTRAP PROGRESS=45 TAG=conn_or …`.
  final String body;

  /// The `KEY=VALUE` pairs carried by status events.
  Map<String, String> get fields {
    final out = <String, String>{};
    for (final token in body.split(' ')) {
      final index = token.indexOf('=');
      if (index > 0) {
        out[token.substring(0, index)] = TorControlReply._unquote(token.substring(index + 1));
      }
    }
    return out;
  }

  String? field(String name) => fields[name];

  @override
  String toString() => '$keyword $body';
}

/// Thrown when Tor rejects a command or the connection drops.
class TorControlException implements Exception {
  const TorControlException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => 'TorControlException(${status ?? '-'}): $message';
}

/// A client for Tor's control port.
///
/// The control port is how DarkFlow learns how far the bootstrap has got, which
/// guards were chosen, and whether the onion service has been published. It is
/// also how the app tells Tor to reload its configuration when the user picks a
/// different bridge — without restarting the daemon and losing the circuits it
/// already built.
///
/// Commands are serialised: Tor's control protocol answers in order, so sending
/// concurrently without a queue would mismatch replies.
class TorControlClient {
  TorControlClient({this.host = '127.0.0.1'});

  final String host;

  Socket? _socket;
  StreamSubscription<String>? _subscription;
  final List<_PendingCommand> _pending = <_PendingCommand>[];
  final StreamController<TorControlEvent> _events =
      StreamController<TorControlEvent>.broadcast();

  _ReplyBuilder? _reply;
  bool _authenticated = false;
  bool _closed = false;

  /// Asynchronous notifications from Tor.
  Stream<TorControlEvent> get events => _events.stream;

  bool get isConnected => _socket != null && !_closed;
  bool get isAuthenticated => _authenticated;

  /// Opens the control connection. Does not authenticate.
  Future<void> connect({required int port, Duration timeout = const Duration(seconds: 10)}) async {
    if (_socket != null) return;
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      _closed = false;
      _subscription = socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLine, onError: _onSocketError, onDone: _onSocketDone, cancelOnError: false);
    } on SocketException catch (error) {
      throw TorControlException('cannot reach the Tor control port on $host:$port — $error');
    }
  }

  /// Asks Tor which authentication methods it accepts and where its cookie is.
  ///
  /// `PROTOCOLINFO` is answered before authentication, which is exactly what
  /// makes it useful.
  Future<Map<String, String>> protocolInfo() async {
    final reply = await send('PROTOCOLINFO 1');
    final info = <String, String>{};
    for (final line in reply.lines) {
      if (line.startsWith('AUTH ')) {
        for (final token in line.substring(5).split(' ')) {
          final index = token.indexOf('=');
          if (index > 0) {
            info[token.substring(0, index)] = TorControlReply._unquote(token.substring(index + 1));
          }
        }
      } else if (line.startsWith('VERSION ')) {
        for (final token in line.substring(8).split(' ')) {
          final index = token.indexOf('=');
          if (index > 0) {
            info[token.substring(0, index)] = TorControlReply._unquote(token.substring(index + 1));
          }
        }
      }
    }
    return info;
  }

  /// Authenticates with a null, password or cookie credential.
  ///
  /// Sends nothing when [method] is `NULL`, because a control port configured
  /// with `CookieAuthentication 0` and no password accepts commands straight
  /// away.
  Future<void> authenticate({
    required String method,
    String? password,
    Uint8List? cookie,
  }) async {
    if (_authenticated) return;
    final command = switch (method.toUpperCase()) {
      'NULL' => 'AUTHENTICATE',
      'HASHEDPASSWORD' => 'AUTHENTICATE ${_quote(password ?? '')}',
      'COOKIE' || 'SAFECOOKIE' => cookie == null
          ? 'AUTHENTICATE'
          : 'AUTHENTICATE ${_hex(cookie)}',
      _ => 'AUTHENTICATE',
    };
    final reply = await send(command);
    if (!reply.isOk) {
      throw TorControlException(
        'authentication failed: ${reply.lines.join(' ')}',
        status: reply.status,
      );
    }
    _authenticated = true;
  }

  /// Subscribes to the events the app cares about.
  ///
  /// `STATUS_CLIENT` carries `BOOTSTRAP` and `CIRCUIT_ESTABLISHED`, which is
  /// what drives the Tor Connection screen.
  Future<void> setEvents(List<String> eventNames) async {
    final reply = await send('SETEVENTS ${eventNames.join(' ')}');
    if (!reply.isOk) {
      throw TorControlException('SETEVENTS failed: ${reply.lines.join(' ')}', status: reply.status);
    }
  }

  /// `GETINFO` for one key.
  Future<String> getInfo(String key) async {
    final reply = await send('GETINFO $key');
    if (!reply.isOk) {
      throw TorControlException('GETINFO $key failed: ${reply.lines.join(' ')}', status: reply.status);
    }
    for (final line in reply.lines) {
      if (line.startsWith('$key=')) return TorControlReply._unquote(line.substring(key.length + 1));
    }
    return reply.value;
  }

  /// `GETINFO` for several keys at once, with an optional short timeout.
  ///
  /// Tor's `GETINFO` honours a millisecond timeout suffix (`GETINFO key/1`), and
  /// DarkFlow uses it so a slow consensus fetch cannot freeze the UI.
  Future<Map<String, String>> getInfoMap(List<String> keys, {int? timeoutMs}) async {
    if (keys.isEmpty) return <String, String>{};
    final suffix = timeoutMs == null ? '' : '/$timeoutMs';
    final reply = await send('GETINFO ${keys.map((key) => '$key$suffix').join(' ')}');
    final out = <String, String>{};
    for (final line in reply.lines) {
      final index = line.indexOf('=');
      if (index > 0) {
        out[line.substring(0, index)] = TorControlReply._unquote(line.substring(index + 1));
      }
    }
    return out;
  }

  /// The current bootstrap progress as a fraction in `0..1`, or null when Tor
  /// has not reported one yet.
  Future<TorBootstrapPhase?> bootstrapPhase() async {
    try {
      final raw = await getInfo('status/bootstrap-phase');
      return TorBootstrapPhase.parse(raw);
    } on TorControlException {
      return null;
    }
  }

  /// True once at least one circuit is usable.
  Future<bool> isCircuitEstablished() async {
    try {
      final raw = await getInfo('status/circuit-established');
      return raw.trim() == '1';
    } on TorControlException {
      return false;
    }
  }

  /// The `Tor` version string reported by `GETINFO version`.
  Future<String> version() async {
    final raw = await getInfo('version');
    return raw.startsWith('Tor ') ? raw.substring(4) : raw;
  }

  /// Sends `SIGNAL` to the daemon (`RELOAD`, `HUP`, `SHUTDOWN`, `DUMP`).
  Future<void> signal(String name) async {
    final reply = await send('SIGNAL $name');
    if (!reply.isOk) {
      throw TorControlException('SIGNAL $name failed: ${reply.lines.join(' ')}', status: reply.status);
    }
  }

  /// Replaces the bridge configuration at runtime.
  ///
  /// `SETCONF` is applied atomically: either the whole new configuration is
  /// accepted or the old one stays in force, so a bad bridge line cannot leave
  /// Tor in a half-configured state.
  Future<void> setConf(Map<String, List<String>> values) async {
    final buffer = StringBuffer('SETCONF');
    values.forEach((key, list) {
      if (list.isEmpty) {
        buffer.write(' $key');
      } else {
        for (final value in list) {
          buffer.write(' $key=${_quoteIfNeeded(value)}');
        }
      }
    });
    final reply = await send(buffer.toString());
    if (!reply.isOk) {
      throw TorControlException(
        'SETCONF failed: ${reply.lines.join(' ')}',
        status: reply.status,
      );
    }
  }

  /// Sends a raw command and waits for its reply.
  Future<TorControlReply> send(String command) async {
    final socket = _socket;
    if (socket == null || _closed) {
      throw const TorControlException('not connected to the Tor control port');
    }
    final pending = _PendingCommand(command);
    _pending.add(pending);
    socket.write('$command\r\n');
    await socket.flush();
    return pending.completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(pending);
        // Anything half-accumulated belongs to the command that timed out.
        //
        // Replies are matched in order, so a partially built multi-line reply left
        // here would swallow the *next* command's first lines and then complete
        // that command's future with the previous command's status and body — a
        // `PROTOCOLINFO` that stalled made the following `GETINFO` answer with the
        // wrong data, and a stale status could make a successful command look
        // failed.
        _reply = null;
        throw TorControlException('timed out waiting for a reply to "$command"');
      },
    );
  }

  /// Closes the connection. Pending commands fail.
  Future<void> close() async {
    _closed = true;
    _authenticated = false;
    await _subscription?.cancel();
    _subscription = null;
    for (final pending in _pending) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          const TorControlException('the control connection was closed'),
        );
      }
    }
    _pending.clear();
    await _socket?.close();
    _socket?.destroy();
    _socket = null;
    if (!_events.isClosed) await _events.close();
  }

  // ------------------------------------------------------------- internals

  void _onLine(String line) {
    if (line.isEmpty) return;

    // Asynchronous events start with 6xx and are not replies to anything.
    if (line.length >= 3 && line[0] == '6') {
      final rest = line.length > 3 ? line.substring(4) : '';
      final space = rest.indexOf(' ');
      final keyword = space < 0 ? rest : rest.substring(0, space);
      _events.add(TorControlEvent(keyword: keyword, body: space < 0 ? '' : rest.substring(space + 1)));
      return;
    }

    if (_pending.isEmpty) return;
    final builder = _reply ??= _ReplyBuilder();
    builder.add(line);
    if (builder.isComplete) {
      _reply = null;
      final pending = _pending.removeAt(0);
      if (!pending.completer.isCompleted) {
        pending.completer.complete(builder.build());
      }
    }
  }

  void _onSocketError(Object error) {
    // A broken control connection is a *closed* one.
    //
    // Only the clean-FIN path used to set `_closed`, so a socket that died on an
    // error left `isConnected` reporting true and `_socket` non-null. Nothing
    // throws locally when writing to a dead socket, so every later command queued
    // into it and failed only after its full thirty-second timeout: `stop()` sat
    // for half a minute on SIGNAL SHUTDOWN, and the bootstrap wait loop spent
    // thirty seconds per poll calling a port that could never answer and then
    // declared the daemon failed although it was healthy — a false failure screen
    // that no retry could clear, only a restart.
    _closed = true;
    _reply = null;
    for (final pending in _pending) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(TorControlException('control connection error: $error'));
      }
    }
    _pending.clear();
  }

  void _onSocketDone() {
    _closed = true;
    _onSocketError('the daemon closed the connection');
  }

  static String _quote(String value) => '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  static String _quoteIfNeeded(String value) =>
      value.contains(' ') || value.contains('"') ? _quote(value) : value;

  static String _hex(Uint8List bytes) {
    final out = StringBuffer();
    for (final byte in bytes) {
      out.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }
}

/// `status/bootstrap-phase` in structured form.
class TorBootstrapPhase {
  const TorBootstrapPhase({
    required this.progress,
    required this.tag,
    required this.summary,
    this.severity = 'NOTICE',
    this.warning = false,
    this.warningMessage,
  });

  /// 0..100, as reported by Tor.
  final int progress;

  /// Tor's internal tag: `starting`, `conn_pt`, `conn_done`, `handshake`,
  /// `handshake_done`, `request_descriptors`, `loading_status`,
  /// `enough_dir_info`, `circuit_create`, `done`.
  final String tag;

  final String summary;
  final String severity;
  final bool warning;

  /// The text of Tor's `WARNING=` field, when it sent one.
  ///
  /// This is the field that explains a stuck bootstrap, and it is easy to miss:
  /// a warning line also carries `SUMMARY=`, which merely restates where Tor got
  /// to ("Connected to a relay"). Showing the summary in the danger colour
  /// printed the same sentence twice and hid the sentence that mattered — the
  /// one naming the reason.
  final String? warningMessage;

  double get fraction => (progress / 100).clamp(0.0, 1.0);
  bool get isDone => tag == 'done' || progress >= 100;

  /// A `KEY=value` or `KEY="quoted value"` pair.
  ///
  /// The quoted form has to be matched as a whole: Tor sends
  /// `SUMMARY="Connected to a relay"`, and splitting on spaces first turns that
  /// into four tokens whose first is `SUMMARY="Connected`. The trailing quote
  /// then never matches, the opening one survives, and the connection screen
  /// displays `"Connected` — which is exactly the truncated text that shipped.
  static final RegExp _fieldPattern =
      RegExp(r'([A-Za-z_]+)=(?:"([^"]*)"|(\S+))');

  /// The severity keyword that opens a NOTICE/WARN/ERR line.
  static final RegExp _severityPattern = RegExp(r'^\s*([A-Z]+)\b');

  /// Parses `NOTICE BOOTSTRAP PROGRESS=45 TAG=conn_or SUMMARY="…"`.
  static TorBootstrapPhase? parse(String raw) {
    if (raw.trim().isEmpty) return null;

    final fields = <String, String>{};
    for (final match in _fieldPattern.allMatches(raw)) {
      fields[match.group(1)!] = match.group(2) ?? match.group(3) ?? '';
    }

    final severity = _severityPattern.firstMatch(raw)?.group(1);
    final warning = severity == 'WARN' || severity == 'ERR';

    final progress = int.tryParse(fields['PROGRESS'] ?? '');
    final tag = fields['TAG'];
    if (progress == null || tag == null) return null;

    return TorBootstrapPhase(
      progress: progress,
      tag: tag,
      summary: fields['SUMMARY'] ?? '',
      severity: severity ?? 'NOTICE',
      warning: warning,
      warningMessage: fields['WARNING'],
    );
  }

  @override
  String toString() => '[$progress%] $tag — $summary';
}

class _PendingCommand {
  _PendingCommand(this.command);

  final String command;
  final Completer<TorControlReply> completer = Completer<TorControlReply>();
}

/// Assembles a multi-line reply, including `250+` data blocks.
class _ReplyBuilder {
  _ReplyBuilder();

  final List<String> lines = <String>[];
  int? _status;
  bool _inDataBlock = false;
  bool _done = false;

  bool get isComplete => _done;

  void add(String line) {
    if (_inDataBlock) {
      if (line == '.') {
        _inDataBlock = false;
        _done = true;
      } else {
        lines.add(line.startsWith('..') ? line.substring(1) : line);
      }
      return;
    }

    if (line.length < 4) {
      _status ??= 250;
      _done = true;
      return;
    }

    final status = int.tryParse(line.substring(0, 3));
    if (status == null) return;
    _status = status;
    final separator = line[3];
    final body = line.substring(4);

    switch (separator) {
      case '-':
        lines.add(body);
      case '+':
        lines.add(body);
        _inDataBlock = true;
      case ' ':
      default:
        if (body.isNotEmpty) lines.add(body);
        _done = true;
    }
  }

  TorControlReply build() => TorControlReply(status: _status ?? 250, lines: lines);
}
