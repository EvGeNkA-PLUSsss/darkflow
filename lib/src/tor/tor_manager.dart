import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/models/tor_settings.dart';
import '../app/log_book.dart';
import 'bridge_line.dart';
import 'tor_config.dart';
import 'tor_control.dart';import 'tor_paths.dart';

/// The four milestones the Tor Connection screen shows.
///
/// Tor reports about a dozen internal bootstrap tags. Exposing all of them
/// would be noise; collapsing them into these four gives an honest answer to
/// the only question a user has, which is "is it working, and if not, where is
/// it stuck?".
enum TorStage {
  /// Loading configuration, starting the daemon.
  starting,

  /// Reaching the network — through a bridge, if one is configured. This is
  /// where a censored network fails.
  connecting,

  /// Building a circuit and fetching a consensus.
  establishing,

  /// Ready to send and receive.
  connected,

  /// Something went wrong; [TorStatus.error] explains what.
  failed,

  /// Deliberately not running: the user stopped it, or it has not been started
  /// yet.
  ///
  /// This exists because a stop used to be recorded as `starting` with the word
  /// "Stopped" in the summary, and [TorStatus.label] maps `starting` to
  /// "Starting…" whatever the summary says — so the Settings row reported
  /// "Starting…" for as long as the user left the daemon off, which is the one
  /// thing that was definitely not happening.
  stopped,
}

/// A snapshot of the Tor manager, suitable for rendering directly.
@immutable
class TorStatus {
  const TorStatus({
    this.stage = TorStage.starting,
    this.progress = 0,
    this.summary = '',
    this.onionAddress,
    this.socksPort,
    this.controlPort,
    this.torVersion,
    this.error,
    this.warning,
    this.usingBridges = false,
    this.bootstrapSeconds,
  });

  final TorStage stage;

  /// 0..1, straight from Tor's own bootstrap progress.
  final double progress;

  /// Tor's own summary line, kept verbatim for the diagnostics area.
  final String summary;

  /// The account's onion address once the service is published.
  final String? onionAddress;

  final int? socksPort;
  final int? controlPort;
  final String? torVersion;
  /// Set only when Tor has actually stopped: a non-zero exit, or a control-port
  /// failure. Anything the daemon is still working through belongs in
  /// [warning], because a screen that declares failure at 10% and offers Retry
  /// is lying about what is happening.
  final String? error;

  /// A bootstrap line Tor sent at WARN level while continuing.
  ///
  /// These are routine — "Failed to find node for hop #1" is a WARN and Tor
  /// simply builds another circuit — so this is shown for information and never
  /// flips the screen into its failed state.
  final String? warning;

  final bool usingBridges;
  final int? bootstrapSeconds;

  bool get isConnected => stage == TorStage.connected;
  bool get isRunning =>
      stage != TorStage.failed &&
      stage != TorStage.starting &&
      stage != TorStage.stopped;

  /// True when the daemon was stopped deliberately, as opposed to never started.
  bool get isStopped => stage == TorStage.stopped;

  /// The step list the connection screen renders.
  List<TorStage> get order => const <TorStage>[
        TorStage.starting,
        TorStage.connecting,
        TorStage.establishing,
        TorStage.connected,
      ];

  /// A one-line status for the Settings row.
  String get label => switch (stage) {
        TorStage.starting => 'Starting…',
        TorStage.connecting => usingBridges ? 'Connecting via bridge…' : 'Connecting…',
        TorStage.establishing => 'Building circuit…',
        TorStage.connected => 'Connected',
        TorStage.failed => 'Not connected',
        TorStage.stopped => 'Not running',
      };

  TorStatus copyWith({
    TorStage? stage,
    double? progress,
    String? summary,
    String? onionAddress,
    int? socksPort,
    int? controlPort,
    String? torVersion,
    String? error,
    String? warning,
    bool clearError = false,
    bool clearWarning = false,
    bool? usingBridges,
    int? bootstrapSeconds,
  }) {
    return TorStatus(
      stage: stage ?? this.stage,
      progress: progress ?? this.progress,
      summary: summary ?? this.summary,
      onionAddress: onionAddress ?? this.onionAddress,
      socksPort: socksPort ?? this.socksPort,
      controlPort: controlPort ?? this.controlPort,
      torVersion: torVersion ?? this.torVersion,
      error: clearError ? null : (error ?? this.error),
      warning: clearWarning ? null : (warning ?? this.warning),
      usingBridges: usingBridges ?? this.usingBridges,
      bootstrapSeconds: bootstrapSeconds ?? this.bootstrapSeconds,
    );
  }
}

/// Starts, supervises and talks to the Tor daemon.
///
/// DarkFlow ships Tor rather than asking the user to install it, because a
/// censorship-circumvention tool that depends on a second app store listing is
/// one takedown away from being useless. That makes this class responsible for
/// the whole lifecycle: unpacking the binaries, generating a torrc that matches
/// the user's bridge choice, publishing the account's onion service from the
/// account's own identity key, and translating Tor's control-port chatter into
/// something the UI can show.
class TorManager extends ChangeNotifier {
  TorManager({
    required Directory rootDirectory,
    required this.serviceTargetPort,
    TorBinaryLocator? locator,
  })  : _root = rootDirectory,
        _locator = locator ?? TorBinaryLocator();

  final Directory _root;

  /// The loopback port the onion service forwards to. It comes from the peer
  /// server, so the two can never disagree about where inbound traffic lands.
  final int serviceTargetPort;

  final TorBinaryLocator _locator;

  Process? _process;
  TorControlClient? _control;
  StreamSubscription<TorControlEvent>? _eventSubscription;
  StreamSubscription<String>? _processOutput;
  StreamSubscription<String>? _processError;
  final List<String> _log = <String>[];
  final StreamController<String> _logStream = StreamController<String>.broadcast();

  TorStatus _status = const TorStatus();
  TorSettings _settings = const TorSettings();
  bool _stopping = false;

  /// Bumped whenever a start attempt is superseded — by a stop, by a retry or by
  /// another start.
  ///
  /// An attempt is a long-lived async routine: it launches a process, retries the
  /// control port, then polls for up to two minutes. Without a token, an attempt
  /// that has been overtaken keeps writing: pressing "Disconnect Tor" while the
  /// control port is still being retried made the *stop* close the client, the
  /// in-flight attempt's `protocolInfo()` throw, and its catch handler overwrite
  /// the clean "Stopped" with a red failure quoting an internal exception. Retry
  /// had the same shape from the other side, with the older attempt writing
  /// `failed` over a connection that was working.
  int _generation = 0;

  /// True once [dispose] has run, which happens while a final [stop] is still in
  /// flight: that stop must not notify listeners that are already gone.
  bool _eventsClosed = false;

  static const int _maxLogLines = 400;

  TorStatus get status => _status;
  TorSettings get settings => _settings;

  /// Recent daemon output, for the diagnostics panel.
  List<String> get log => List<String>.unmodifiable(_log);
  Stream<String> get logStream => _logStream.stream;

  /// True when the bundled Tor runtime was found.
  bool get hasBundledTor => _locator.isSupported;

  /// True once the daemon has been launched.
  ///
  /// The connection screen distinguishes "not started yet" from "started and
  /// still working": the first offers a Connect button, the second does not.
  bool get isStarted => _process != null;

  /// Restarts the daemon. This is what the "Retry" action on the connection
  /// screen calls after a failed bootstrap.
  Future<void> restart() async {
    await stop();
    await _startInternal();
  }

  /// Starts Tor with the current settings, unless it is already running.
  Future<void> start() async {
    if (_process != null) return;
    await _startInternal();
  }

  /// Stops the daemon and waits for it to exit.
  Future<void> stop() async {
    // Before anything else, so an attempt that is still in flight can tell that
    // it has been superseded and stays quiet. See [_generation].
    _generation++;
    _stopping = true;
    try {
      final control = _control;
      // Whether Tor was actually told to leave. Without a signal it has no reason
      // to exit, so waiting for it is pure dead time.
      final signalled = control != null && control.isConnected;
      if (signalled) {
        try {
          // SIGNAL SHUTDOWN lets Tor close its circuits politely and flush its
          // state, which makes the next start much faster.
          await control.signal('SHUTDOWN');
        } on Object {
          // Fall through to killing the process.
        }
      }

      await _eventSubscription?.cancel();
      _eventSubscription = null;
      await _control?.close();
      _control = null;
      await _processOutput?.cancel();
      _processOutput = null;
      await _processError?.cancel();
      _processError = null;

      final process = _process;
      if (process != null) {
        // Nothing will make a daemon that was never signalled exit on its own, so
        // asking it to go is the honest first step. The eight-second grace period
        // is still granted — it is what lets a signalled Tor flush — but it is no
        // longer spent waiting for an event that cannot happen, which is what made
        // pressing Disconnect during a bridge retry hang the UI for eight seconds
        // and then SIGKILL the daemon without it ever being asked to stop.
        if (!signalled) process.kill();
        try {
          await process.exitCode.timeout(const Duration(seconds: 8));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode;
        }
      }
      _process = null;
    } finally {
      // In a `finally`, because it used to be the last statement: a throw from any
      // of the cancellations above left `_stopping` true for the rest of the
      // session, and the exit handler then ignored every subsequent failure —
      // including real ones.
      _stopping = false;
      // Only while there is still someone to tell: `dispose` schedules a stop, and
      // notifying listeners on a disposed [ChangeNotifier] throws — which turned
      // "the app shut down" into an unhandled error the moment anything awaited the
      // shutdown.
      if (!_eventsClosed) {
        _setStatus(const TorStatus(stage: TorStage.stopped, summary: 'Stopped'));
      }
    }
  }

  /// Replaces the bridge configuration and applies it.
  ///
  /// A change of transport cannot be applied to a running daemon — the
  /// `ClientTransportPlugin` lines only take effect at startup — so this
  /// restarts Tor. A change of bridge *lines* alone could be applied with
  /// `SETCONF`, and Tor does that without dropping the circuits it already has.
  Future<void> applySettings(TorSettings next) async {
    final previous = _settings;
    _settings = next;
    _notify();

    if (_process == null) return;

    final transportChanged = previous.mode != next.mode ||
        previous.usesBridges != next.usesBridges ||
        previous.extraConfig != next.extraConfig;
    if (transportChanged) {
      await stop();
      await _startInternal();
      return;
    }

    final control = _control;
    if (control == null || !control.isConnected) return;
    try {
      await control.setConf(<String, List<String>>{
        'Bridge': next.bridgeLines.map((line) {
          final withoutKeyword = line.startsWith('Bridge ') ? line.substring(7) : line;
          return withoutKeyword;
        }).toList(growable: false),
        'UseBridges': <String>[next.usesBridges ? '1' : '0'],
      });
      await control.signal('RELOAD');
    } on TorControlException catch (error) {
      _log.add('SETCONF failed: ${error.message}');
      _logStream.add('SETCONF failed: ${error.message}');
    }
  }

  /// Checks that Tor's SOCKS port is accepting connections.
  ///
  /// The connection screen uses this to tell "the daemon is up" apart from "the
  /// daemon is up and has a circuit", which is the difference between waiting
  /// and configuring a bridge.
  Future<bool> isSocksReachable() async {
    final port = _status.socksPort;
    if (port == null) return false;
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 3),
      );
      socket.destroy();
      return true;
    } on Object {
      return false;
    }
  }

  @override
  void dispose() {
    _eventsClosed = true;
    unawaited(stop());
    unawaited(_logStream.close());
    super.dispose();
  }

  // ------------------------------------------------------------- internals

  /// Feeds the daemon's output to the diagnostics log.
  ///
  /// `allowMalformed` is the point. `utf8.decoder` is strict, and Tor's console
  /// output on Windows is written in the local code page — which Tor then makes
  /// worse by logging its own paths, so a Cyrillic user name is enough to produce a
  /// byte that is not valid UTF-8. A strict decoder throws on it, the transformer
  /// re-emits that as a stream error, and with no `onError` the error is unhandled:
  /// a red console failure in debug and a lost log line in release, on exactly the
  /// machine this project is developed on.
  StreamSubscription<String> _drain(Stream<List<int>> stream) => stream
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .listen(
        _appendLog,
        onError: (Object error) => _appendLog('tor output error: $error'),
      );

  Future<void> _startInternal() async {
    final generation = ++_generation;
    /// True once a stop, a retry or another start has overtaken this attempt.
    bool stale() => generation != _generation;

    final startedAt = DateTime.now();
    _log.clear();
    _setStatus(const TorStatus(stage: TorStage.starting, summary: 'Starting the Tor daemon…'));

    try {
      if (!_locator.isSupported) {
        throw const TorBinaryMissingException(
          'Tor cannot run on this platform from inside the app.',
        );
      }

      final torExecutable = await _locator.torExecutable();
      final transportPaths = await _locator.transportPaths();
      final runtimeDirectory = await _locator.runtimeDirectory();

      final dataDirectory = Directory(
        '${_root.path}${Platform.pathSeparator}tor${Platform.pathSeparator}data',
      );
      final hiddenServiceDirectory = Directory(
        '${_root.path}${Platform.pathSeparator}tor${Platform.pathSeparator}onion',
      );
      final cookieFile =
          File('${_root.path}${Platform.pathSeparator}tor${Platform.pathSeparator}control_auth_cookie');

      await dataDirectory.create(recursive: true);
      await hiddenServiceDirectory.create(recursive: true);

      // Tor refuses to start when the hidden-service directory is group- or
      // world-readable, and a directory created with the usual 022 umask is 0755
      // — so on Linux, macOS and Android the daemon exited immediately with
      // "Directory … is group-readable, but we are not configured to allow that".
      // Windows ignores the mode, which is why this was invisible in the build
      // that was tested, and the helper written for it (`hardenPermissions`) was
      // referenced nowhere.
      await HiddenServiceKeys.hardenPermissions(hiddenServiceDirectory);
      await HiddenServiceKeys.hardenPermissions(dataDirectory);

      // Tor owns the hidden-service key pair.
      //
      // Writing the key files ourselves would be the natural way to make the
      // onion address a pure function of the account's identity key, and that
      // was the first design. It does not work: given a secret-key file holding
      // a standard Ed25519 key (`seed || publicKey`, which is what ref10 and
      // libsodium produce), Tor derives a *different* public key and refuses to
      // start with "hs_ed25519_public_key does not match hs_ed25519_secret_key".
      //
      // That was measured rather than assumed. `tool/smoke_tor.dart` reproduces
      // it, shows Tor reusing the seed byte-for-byte while publishing a
      // different public key, and `test/crypto/sha3_test.dart` pins the RFC 8032
      // vector proving this project's Ed25519 is standard. The disagreement is
      // in Tor's expected layout, not in the derivation here.
      //
      // Letting Tor generate the pair removes the ambiguity: it writes
      // `hs_ed25519_secret_key`, `hs_ed25519_public_key` and `hostname` itself,
      // and the address read back from `hostname` is by definition the one the
      // service is reachable at. The cost is that the address is known only
      // after Tor has started once, which the account model already allows.
      if (_settings.enableOnionService) {
        await hiddenServiceDirectory.create(recursive: true);
        debugPrint('Tor: the daemon will publish its own hidden service');
      }

      // Any daemon left over from a previous run is stopped first.
      //
      // Tor refuses to share a `DataDirectory`, and it cannot bind a port another process is
      // holding. An orphan — from a crashed build, a force-killed application, or a second copy of
      // DarkFlow — therefore makes this start fail in a way that looks like a network problem: the
      // daemon exits, or it starts and every circuit goes nowhere.
      //
      // Run before the reserved ports and before the daemon, because both of those are what the
      // orphan would be holding.
      await _stopOrphanedDaemons();
      // **before the daemon is spawned**.
      //
      // ## The two halves, and why both are needed
      //
      // The original bug was that the port number was obtained and then forgotten: `_freePort`
      // bound a socket, closed it, and returned the number, leaving the port free for as long as
      // it took to write `torrc` and start the process. Anything could take it in that window,
      // including this object's own second call — which is how SOCKS and control could come back
      // identical, and why a daemon could start and answer on nothing.
      //
      // The first attempt at a fix held the sockets for the whole start-up. That is worse and was
      // caught by `test/integration/tor_manager_test.dart` against the real daemon:
      //
      //     [warn] Could not bind to 127.0.0.1:55808: Address already in use [WSAEADDRINUSE]
      //     [warn] Failed to parse/validate config: Failed to bind one of the listener ports.
      //     [err]  Reading config failed--see warnings above.
      //
      // A held socket *is* a conflicting bind. Tor cannot take a port that somebody else is
      // listening on, so reserving the port made the daemon refuse to start at all — strictly
      // worse than the race being fixed.
      //
      // So the reservation is used for what it can actually provide: two calls that cannot
      // return the same number, because the first is still held while the second is made. Then
      // the ports are handed over, and the remaining exposure is the gap between these closes
      // and the daemon's own binds — microseconds, against a window that used to include writing
      // a file and spawning a process.
      final socksPort = _settings.socksPort == 0 ? await _reservePort() : _settings.socksPort;
      final controlPort = _settings.controlPort == 0
          ? await _reservePort(excluding: <int>{socksPort})
          : _settings.controlPort;
      logTor('ports: socks=$socksPort control=$controlPort '
          '(settings socks=${_settings.socksPort} control=${_settings.controlPort})');
      _releaseReserved();
      // Tor looks for these next to the daemon; naming them explicitly means a
      // packaging change cannot silently disable country-based path rules.
      final geoIp = File('${runtimeDirectory.path}${Platform.pathSeparator}geoip');
      final geoIpV6 = File('${runtimeDirectory.path}${Platform.pathSeparator}geoip6');

      final torrc = TorConfig.build(
        settings: _settings,
        dataDirectory: dataDirectory,
        hiddenServiceDirectory: hiddenServiceDirectory,
        socksPort: socksPort,
        controlPort: controlPort,
        cookieAuthFile: cookieFile.path,
        onionServiceTargetPort: serviceTargetPort,
        transportPaths: transportPaths,
        geoIpFile: geoIp.existsSync() ? geoIp.path : null,
        geoIpV6File: geoIpV6.existsSync() ? geoIpV6.path : null,
        // Ties the daemon's lifetime to this process. See the note in
        // TorConfig: an orphaned daemon keeps the DataDirectory lock and makes
        // every later launch fail with "another Tor process is running".
        owningProcessId: pid,
      );
      final torrcFile = File(
        '${_root.path}${Platform.pathSeparator}tor${Platform.pathSeparator}torrc',
      );
      await torrcFile.writeAsString(torrc, flush: true);

      // Built before the verification below, because the daemon needs the same environment in
      // both cases — the pluggable transports are separate programs found through it.
      final environment = <String, String>{
        ...Platform.environment,
        if (!Platform.isWindows)
          'LD_LIBRARY_PATH': runtimeDirectory.path,
      };

      // Ask Tor whether it would accept this file, before making it the reason nothing works.
      //
      // The daemon's own refusal is nearly useless to the user: it prints three lines to a log
      // the application cannot show, ends with "Reading config failed--see warnings above", and
      // exits. That message — with a bootstrap stuck at 0% and no way to tell a bad
      // configuration from a network problem — is what was reported, and the only recovery the
      // user found was to delete the account.
      //
      // `--verify-config` parses and exits without starting anything, so its complaint is about
      // the configuration alone. It costs a few hundred milliseconds and it runs on a file that
      // was just written from settings the user can edit, which is exactly the situation where
      // a precise reason is worth that cost.
      //
      // A verification that cannot be run at all is not treated as a failure: an older daemon
      // without the flag, or a process that cannot be spawned, must not become a reason the
      // application refuses to connect. The daemon is started regardless and its own error
      // handling takes over.
      final objection = await _verifyConfig(
        torExecutable,
        torrcFile,
        environment,
        runtimeDirectory,
      );
      if (objection != null) {
        _appendLog('Tor rejected the generated configuration: $objection');
        _setStatus(_status.copyWith(stage: TorStage.failed, error: objection));
        return;
      }

      _log.add('starting $torExecutable');
      _log.add('torrc written to ${torrcFile.path}');
      logTor(
        'starting the daemon',
        detail: 'exe $torExecutable\n'
            'runtime ${runtimeDirectory.path}\n'
            'data ${dataDirectory.path}\n'
            'torrc ${torrcFile.path}',
      );
      _setStatus(
        _status.copyWith(
          socksPort: socksPort,
          controlPort: controlPort,
          usingBridges: _settings.usesBridges,
        ),
      );

      final process = await Process.start(
        torExecutable,
        <String>['-f', torrcFile.path],
        workingDirectory: runtimeDirectory.path,
        environment: environment,
        runInShell: false,
      );
      _process = process;

      _processOutput = _drain(process.stdout);
      _processError = _drain(process.stderr);

      // A daemon that exits on its own is almost always a configuration error,
      // and Tor's own message is far more useful than anything this code could
      // invent. `Log notice file` sends that message to the data directory
      // rather than to stdout, so the file is read here — otherwise the UI can
      // only say "exited with code 1", which tells the user nothing.
      unawaited(process.exitCode.then((code) async {
        if (_stopping) return;
        _appendLog('tor exited with code $code');
        final reason = await _lastErrorFrom(dataDirectory) ??
            _lastErrorLine() ??
            'Tor exited with code $code.';
        // The handle is cleared so `isStarted` stops claiming a process that is
        // gone. Without this the connection screen kept offering Disconnect for a
        // dead daemon, `applyTorSettings` kept believing one was running, and the
        // bootstrap wait loop polled a port that could never answer until its
        // two-minute deadline — and then replaced this precise, actionable reason
        // with the generic "Tor could not reach the network, configure a bridge",
        // sending the user off to configure bridges for a torrc mistake.
        if (identical(_process, process)) _process = null;
        _setStatus(
          _status.copyWith(stage: TorStage.failed, error: reason),
        );
      }));

      await _attachControl(controlPort: controlPort, cookieFile: cookieFile);
      _setStatus(_status.copyWith(torVersion: await _control?.version()));

      // Hand the reserved ports to Tor now that it is listening on them.
      //
      // The wait is here, before the long bootstrap, because the ports are what every other
      // part of the application depends on: the mesh dials `socksPort` and the onion service
      // forwards to the peer server. Releasing too early would put back the race that reserving
      // them removes; releasing never would break the next start.
      await _awaitListeners(socksPort, controlPort);

      // Tor writes `hostname` as soon as the service keys exist, which happens
      // during startup rather than when a circuit is built, so this normally
      // succeeds even on a network that cannot reach the Tor network at all.
      //
      // Started rather than awaited. The wait inside is minutes long in the case it now
      // covers, and awaiting it here would hold up the circuit wait below — so the
      // connection screen would sit at its first progress step with no indication that
      // anything was happening. The status is updated when the address arrives, which is
      // what the interface listens to.
      if (_settings.enableOnionService) {
        unawaited(_publishOwnAddress(hiddenServiceDirectory));
      }

      // Waiting for the daemon to settle also gives the process-exit handler a
      // chance to fire, so a torrc mistake surfaces here rather than as a
      // mysterious hang.
      await _waitForCircuit(
        startedAt: startedAt,
        stale: stale,
        // The daemon has already given its verdict.
        //
        // A process that exited has had its reason read out of Tor's own log and
        // written to the status by the exit handler, and that message names a
        // concrete cause. Overwriting it with the deadline's generic advice throws
        // away the only useful thing on the screen.
        ended: () => _status.stage == TorStage.failed,
      );
    } on TorBinaryMissingException catch (error) {
      if (stale()) return;
      _setStatus(_status.copyWith(stage: TorStage.failed, error: error.message));
    } on Object catch (error) {
      _appendLog('failed to start: $error');
      // A superseded attempt says nothing.
      //
      // Its failure is the *consequence* of whatever replaced it — the stop that
      // closed its control client, or the retry that took over — and reporting it
      // wrote a red screen with an internal exception over a state the user had
      // just asked for.
      if (stale()) return;
      _setStatus(_status.copyWith(stage: TorStage.failed, error: '$error'));
    }
  }

  Future<void> _attachControl({
    required int controlPort,
    required File cookieFile,
  }) async {
    final client = TorControlClient();
    _control = client;

    // Tor takes a moment to open the control port after the process starts.
    var lastError = '';
    for (var attempt = 0; attempt < 60; attempt++) {
      try {
        await client.connect(port: controlPort);
        lastError = '';
        break;
      } on TorControlException catch (error) {
        lastError = error.message;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (_stopping || _process == null || _status.stage == TorStage.failed) {
        throw TorControlException('Tor stopped while connecting: $lastError');
      }
    }
    if (!client.isConnected) {
      throw TorControlException('the Tor control port never opened: $lastError');
    }

    final info = await client.protocolInfo();
    final methods = (info['METHODS'] ?? '').split(',');
    if (methods.contains('COOKIE') || methods.contains('SAFECOOKIE')) {
      final path = info['COOKIEFILE'] ?? cookieFile.path;
      final file = File(path);
      Uint8List? cookie;
      for (var attempt = 0; attempt < 20; attempt++) {
        if (await file.exists()) {
          cookie = await file.readAsBytes();
          if (cookie.isNotEmpty) break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await client.authenticate(method: 'COOKIE', cookie: cookie);
    } else if (methods.contains('NULL')) {
      await client.authenticate(method: 'NULL');
    } else {
      await client.authenticate(
        method: 'HASHEDPASSWORD',
        password: _hashedPasswordFromTorrc(),
      );
    }

    await client.setEvents(<String>['STATUS_CLIENT', 'NOTICE', 'WARN', 'ERR']);
    _eventSubscription = client.events.listen(_onEvent);
  }

  /// Pulls the password out of a user-supplied `HashedControlPassword` line.
  String _hashedPasswordFromTorrc() {
    for (final line in _settings.extraConfig.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.startsWith('HashedControlPassword ')) {
        return trimmed.substring('HashedControlPassword '.length).trim();
      }
    }
    return '';
  }

  void _onEvent(TorControlEvent event) {
    _appendLog('${event.keyword} ${event.body}');
    // `contains`, not `startsWith`.
    //
    // The control port puts the severity between the keyword and the payload —
    // `650 STATUS_CLIENT NOTICE BOOTSTRAP PROGRESS=45 …` — so the body this
    // receives is `NOTICE BOOTSTRAP PROGRESS=45 …` and a `startsWith` test never
    // matched. Every live bootstrap event was therefore dropped on the floor and
    // the progress bar was driven only by the start-up poll, which stops as soon
    // as it returns: a later re-bootstrap, or a stall after the first circuit, left
    // the screen frozen on a stale number while the control port knew exactly what
    // was happening.
    if (event.keyword == 'STATUS_CLIENT' && event.body.contains('BOOTSTRAP')) {
      final phase = TorBootstrapPhase.parse(event.body);
      if (phase != null) _applyBootstrapPhase(phase);
      return;
    }
    if (event.keyword == 'STATUS_CLIENT' && event.body.contains('CIRCUIT_ESTABLISHED')) {
      _setStatus(_status.copyWith(stage: TorStage.connected, progress: 1));
    }
  }

  void _applyBootstrapPhase(TorBootstrapPhase phase) {
    final stage = switch (phase.tag) {
      'starting' || 'conn_pt' => TorStage.starting,
      'conn_done' || 'handshake' || 'handshake_done' => TorStage.connecting,
      'request_descriptors' || 'loading_status' || 'enough_dir_info' => TorStage.establishing,
      'circuit_create' || 'done' => phase.isDone ? TorStage.connected : TorStage.establishing,
      _ => _status.stage,
    };
    _setStatus(
      _status.copyWith(
        stage: stage,
        progress: phase.fraction,
        summary: phase.summary,
        // A WARN here is advisory. Tor sends them while it is still working —
        // a relay that could not be reached, a node that could not be found,
        // both of which it routes around. Treating them as failure is what made
        // a healthy 10% bootstrap look broken and offer a Retry.
        //
        // `WARNING=` is preferred over `SUMMARY=`: the summary only restates how
        // far Tor got, which the progress bar already says, while the warning
        // names the reason. Showing the summary printed the same sentence under
        // the heading twice and hid the part worth reading.
        warning: phase.warning
            ? (phase.warningMessage ?? phase.summary)
            : null,
        clearWarning: !phase.warning,
      ),
    );
  }

  /// Polls the control port until a circuit exists, so the UI can move on even
  /// if an event was missed while the connection was being authenticated.
  ///
  /// [stale] reports whether this attempt has been superseded, and [ended]
  /// whether the daemon has already produced a verdict of its own.
  ///
  /// Both matter for the same reason: without them a dead or replaced daemon was
  /// polled until the two-minute deadline, and the deadline's generic "Tor could
  /// not reach the network, configure a bridge" then overwrote the daemon's own,
  /// specific and actionable message — a torrc mistake was reported as
  /// censorship, and the user was sent to the bridge screen to fix it.
  Future<void> _waitForCircuit({
    required DateTime startedAt,
    required bool Function() stale,
    required bool Function() ended,
  }) async {
    final deadline = DateTime.now().add(
      Duration(seconds: _settings.connectionTimeoutSeconds),
    );
    while (DateTime.now().isBefore(deadline)) {
      if (_stopping || _process == null || stale() || ended()) return;
      final client = _control;
      if (client != null && client.isConnected) {
        final phase = await client.bootstrapPhase();
        if (stale() || ended()) return;
        if (phase != null) _applyBootstrapPhase(phase);
        if (await client.isCircuitEstablished()) {
          if (stale()) return;
          _setStatus(
            _status.copyWith(
              stage: TorStage.connected,
              progress: 1,
              summary: 'Connection established',
              clearError: true,
              bootstrapSeconds: DateTime.now().difference(startedAt).inSeconds,
            ),
          );
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    if (stale() || ended()) return;
    _setStatus(
      _status.copyWith(
        stage: TorStage.failed,
        error: _status.usingBridges
            ? 'Tor could not reach the network through the configured bridges. '
                'Try a different transport, or paste fresh bridge lines.'
            : 'Tor could not reach the network. This usually means the network '
                'blocks Tor — configure a bridge.',
      ),
    );
  }

  /// Asks the daemon whether it would accept the configuration, without starting it.
  ///
  /// ## What this prevents
  ///
  /// Tor has no partial start. A configuration it cannot parse — one malformed bridge line is
  /// enough — makes it print three lines to a log file, end with
  ///
  /// ```
  /// [err] Reading config failed--see warnings above.
  /// ```
  ///
  /// and exit. The application then showed a bootstrap stuck at 0% with that sentence as its
  /// only explanation, and the user's recovery was to delete the account and start over.
  ///
  /// `--verify-config` parses the file and exits without touching the network, so its output is
  /// about the configuration alone and nothing else. Whatever it objects to is filtered through
  /// the same rule the daemon's own log uses — see [_lastErrorLine] — so the sentence the user
  /// reads names a cause rather than pointing at warnings they cannot see.
  ///
  /// Returns null when the configuration is accepted, and **also** when the check could not be
  /// run at all. An older daemon without the flag, or a machine where the process cannot be
  /// spawned, must not become a reason the application refuses to connect.
  Future<String?> _verifyConfig(
    String executable,
    File torrcFile,
    Map<String, String> environment,
    Directory runtimeDirectory,
  ) async {
    ProcessResult result;
    try {
      result = await Process.run(
        executable,
        <String>['--verify-config', '-f', torrcFile.path],
        workingDirectory: runtimeDirectory.path,
        environment: environment,
        runInShell: false,
      ).timeout(const Duration(seconds: 20));
    } on Object catch (error) {
      // Not fatal by design: the daemon below will produce its own verdict.
      _appendLog('could not pre-check the configuration: $error');
      return null;
    }

    if (result.exitCode == 0) return null;

    final output = '${result.stdout}\n${result.stderr}'.trim();
    if (output.isEmpty) {
      return 'Tor refused the generated configuration and did not say why (exit code '
          '${result.exitCode}).';
    }

    // Fed through the same reader the daemon's log goes through, so a line that names no cause
    // — "see warnings above" — is skipped in favour of one that does.
    final saved = List<String>.from(_log);
    try {
      _log
        ..clear()
        ..addAll(output.split('\n'));
      final reason = _lastErrorLine();
      // The offending bridge line, when one of the configured lines is what Tor refused. This
      // is the difference between "the configuration is wrong" and knowing which line to
      // delete, and it is computed rather than guessed.
      final bridge = _bridgeConfigProblem();
      if (bridge != null) return bridge;
      return reason ??
          'Tor refused the generated configuration. It said: '
              '${output.split('\n').last.trim()}';
    } finally {
      _log
        ..clear()
        ..addAll(saved);
    }
  }

  /// Adopts the address Tor publishes for this device's onion service.
  ///
  /// ## Why this waits as long as it does
  ///
  /// It used to give up after ten seconds — forty attempts of 250 ms — and say nothing.
  /// If Tor had not written the file by then, which is ordinary when the daemon is busy
  /// bootstrapping or starting slowly, the address was never adopted. Everything downstream
  /// depends on it: `AppController._publishAddressAndConfigureMesh` returns early while the
  /// address is null, so the mesh is never configured, so no handshake is ever attempted,
  /// so a newly added contact shows "waiting for the first handshake" indefinitely. The
  /// only queue was a log line nobody reads.
  ///
  /// Two minutes, and a second attempt if the first runs out: the file usually appears in
  /// well under a second, and the case being covered is the slow one. When it truly never
  /// appears the status says so, because a user staring at "waiting for a handshake" needs
  /// to know the problem is local and what it is.
  Future<void> _publishOwnAddress(Directory hiddenServiceDirectory) async {
    final hostnameFile = File(
      '${hiddenServiceDirectory.path}${Platform.pathSeparator}${HiddenServiceKeys.hostnameFileName}',
    );

    for (var round = 0; round < 2; round++) {
      for (var attempt = 0; attempt < 240; attempt++) {
        if (_stopping || _process == null) return;
        if (await hostnameFile.exists()) {
          final address = (await hostnameFile.readAsString()).trim();
          if (address.isNotEmpty) {
            _appendLog('published onion service at $address');
            logTor('published onion service',
                detail: 'address ${shortenOnion(address)}');
            _setStatus(_status.copyWith(onionAddress: address));
            return;
          }
        }
        // A second round only makes sense if the daemon is still running; the check at
        // the top of the loop covers that.
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (round == 0) {
        _appendLog('Tor has not written a hostname file yet; still waiting');
      }
    }

    // Reported rather than logged, because it is the difference between "your contact is
    // not answering" and "this device has no address for anyone to answer".
    _appendLog('Tor did not write a hostname file; the onion service is not available');
    if (!_stopping && _process != null) {
      _setStatus(_status.copyWith(
        error: 'Tor did not publish an address for this device, so nobody can reach it '
            'and no message can be delivered. The onion service may be disabled or '
            'Tor may not have started properly.',
      ));
    }
  }

  /// A port held open by this object, so nothing else can take it before Tor does.
  final List<ServerSocket> _reserved = <ServerSocket>[];

  /// Stops any Tor daemon that is not this application's.
  ///
  /// ## Why this is not merely tidy
  ///
  /// A daemon that outlives the application keeps two things the next start needs: the
  /// `DataDirectory` lock and its listener ports. Tor cannot share the first and cannot bind the
  /// second, so the new daemon either refuses to start or starts without the ports it was told to
  /// use — and the user sees a connection that never establishes rather than an error naming the
  /// cause.
  ///
  /// The usual orphan is a build that was force-killed: `__OwningControllerProcess` handles a
  /// clean exit, but nothing can run when the process is destroyed outright. A second copy of
  /// DarkFlow does the same thing without a crash.
  ///
  /// ## How
  ///
  /// The control port is the supported way. `TorControlClient` already knows how to authenticate
  /// with the cookie Tor writes into the data directory.
  ///
  /// Never throws and never reports a hard failure. A start that cannot clean up should still try
  /// to start: refusing to launch because an old daemon could not be reached would turn a
  /// recoverable state into a dead application.
  Future<void> _stopOrphanedDaemons() async {
    // ## Why the port check below is not the whole job
    //
    // `controlPort` is zero by default, and the daemon then picks a port of its own. So on the
    // ordinary configuration there is no fixed port to look for, and a leftover daemon cannot be
    // found by connecting to one. It is found by name instead, which is what the user asked for
    // and what actually solves their problem: the orphan holds the data directory, and the daemon
    // that follows refuses to start.
    //
    // The name is the daemon this application ships, so this ends the copies DarkFlow started and
    // not a Tor Browser the user is running — that one is `firefox.exe` with a different image, or
    // `tor.exe` under a path this build did not place. The risk of a false positive is stated
    // rather than hidden: on Windows the match is on the image name, and the paths are recorded in
    // the log so an unexpected kill is visible.
    await _killStrayDaemonsByImageName();

    final controlPort = _settings.controlPort;
    if (controlPort == 0) return;

    final client = TorControlClient();
    try {
      await client.connect(port: controlPort);
    } on Object {
      // Nothing is listening, which is the ordinary case and the one that wants.
      await client.close();
      return;
    }

    try {
      final info = await client.protocolInfo();
      final methods = (info['METHODS'] ?? '').split(',');
      final cookiePath = info['COOKIEFILE'];

      // Ownership is decided by the cookie file. A daemon this account started wrote one; a
      // foreign one did not, and halting a process the application does not own is not its
      // business.
      final cookie = cookiePath != null && File(cookiePath).existsSync()
          ? await File(cookiePath).readAsBytes()
          : null;
      if (methods.contains('COOKIE') || methods.contains('SAFECOOKIE')) {
        await client.authenticate(method: 'COOKIE', cookie: cookie);
      } else if (methods.contains('NULL')) {
        await client.authenticate(method: 'NULL');
      }

      if (cookie == null) {
        _appendLog(
          'a Tor daemon is already on control port $controlPort and was not started by this '
          'account; it may be holding the data directory',
        );
        logTor('a foreign Tor daemon holds the pinned control port; leaving it alone');
        await client.close();
        return;
      }

      final pid = await client.getInfo('process/pid');
      _appendLog('stopping the Tor daemon left over from a previous run (pid $pid)');
      logTor('stopping an orphaned Tor daemon from a previous run', detail: 'pid $pid');
      await client.signal('HALT');
      await client.close();

      // The daemon releases its directory and its ports on the way out, and a bind taken while it
      // is still shutting down fails. Short and bounded, and it only happens when there really was
      // something to stop.
      await Future<void>.delayed(const Duration(milliseconds: 500));
    } on Object catch (error) {
      // Recorded, not raised: the daemon below reports its own problems with better words.
      await client.close();
      _appendLog('could not stop the previous Tor daemon: $error');
      logTor('could not stop the previous Tor daemon', detail: '$error');
    }
  }

  /// Ends every `tor` process the operating system can see, before this one starts.
  ///
  /// ## Why by name
  ///
  /// The control port is the supported way to ask a daemon to stop, and it is used below when a
  /// port is pinned. It cannot help in the default configuration, where the daemon picks its own
  /// port: there is nothing fixed to connect to, and the orphan is invisible to the application
  /// while being fatal to the start that follows it. It holds the `DataDirectory` lock, so the new
  /// daemon exits with "another Tor process is running with the same data directory", and the user
  /// sees a connection that never comes up.
  ///
  /// So the fallback is the operating system's own process listing. It is blunt, and it is what the
  /// user asked for after hitting exactly this: a stray daemon surviving a force-killed build and
  /// breaking the next one.
  ///
  /// ## Scope
  ///
  /// Windows only, and deliberately so. On Android the daemon is not a separate process at all —
  /// it is `libtor.so` loaded into this application's process, so there is nothing to kill and
  /// nothing that can outlive the application. On Linux and macOS the same `killall` would be
  /// possible, but the shipped builds for this project are Windows and Android, and an untested
  /// branch that kills processes by name is worse than no branch.
  ///
  /// Never throws. A start that could not tidy up should still try to start.
  Future<void> _killStrayDaemonsByImageName() async {
    if (!Platform.isWindows) return;

    try {
      final result = await Process.run(
        'tasklist',
        <String>['/FI', 'IMAGENAME eq tor.exe', '/FO', 'CSV', '/NH'],
        runInShell: false,
      ).timeout(const Duration(seconds: 10));

      final output = '${result.stdout}';
      // `tasklist` prints "INFO: No tasks are running..." rather than an empty list when there is
      // nothing to find, so the count is taken from the lines that actually look like a task.
      final pids = <String>[
        for (final line in output.split('\n'))
          if (line.toLowerCase().contains('tor.exe'))
            if (RegExp(r'"(\d+)"').firstMatch(line) case final match?)
              match.group(1)!,
      ];
      if (pids.isEmpty) {
        logTor('no leftover Tor daemon found');
        return;
      }

      logTor(
        'ending leftover Tor daemons before starting',
        detail: 'pids ${pids.join(', ')}',
      );
      _appendLog('ending ${pids.length} leftover Tor daemon(s): ${pids.join(', ')}');

      for (final pid in pids) {
        await Process.run(
          'taskkill',
          <String>['/F', '/PID', pid],
          runInShell: false,
        ).timeout(const Duration(seconds: 10));
      }

      // The port and the directory lock are released as the processes die, and a bind taken during
      // that is refused. Short, and only after something was actually ended.
      await Future<void>.delayed(const Duration(milliseconds: 500));
    } on Object catch (error) {
      // Recorded rather than raised: the daemon below will fail with its own message if the orphan
      // really is in the way, and that message is better than anything invented here.
      _appendLog('could not look for leftover Tor daemons: $error');
      logTor('could not look for leftover Tor daemons', detail: '$error');
    }
  }

  /// Binds a free loopback port and keeps the socket, so the port cannot be taken.
  ///
  /// The socket is released by [_releaseReserved] once Tor has claimed the ports. Callers must
  /// not use this to probe for a port and then close it — that is the race this exists to
  /// remove.
  ///
  /// [excluding] guards against the operating system handing back a port already reserved here,
  /// which it is entitled to do with `SO_REUSEADDR` semantics on some platforms.
  Future<int> _reservePort({Set<int> excluding = const <int>{}}) async {
    for (var attempt = 0; attempt < 8; attempt++) {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      if (excluding.contains(port) ||
          _reserved.any((ServerSocket held) => held.port == port)) {
        await socket.close();
        continue;
      }
      _reserved.add(socket);
      return port;
    }
    throw StateError('Could not reserve a free loopback port after several attempts.');
  }

  /// Hands the reserved ports to Tor.
  ///
  /// Called once the daemon is listening. The sockets are closed rather than kept: holding one
  /// that Tor also wants would make Tor's own bind fail on platforms without port sharing.
  void _releaseReserved() {
    for (final socket in _reserved) {
      // Not awaited: this runs where a delay would hold up the status the user is watching, and
      // a socket close that fails is collected by the operating system anyway.
      unawaited(socket.close().catchError((Object _) => socket));
    }
    _reserved.clear();
  }

  /// Waits until Tor is listening on both ports, and says so in the log.
  ///
  /// ## This is a check, not a handover
  ///
  /// The ports were released before the daemon was spawned — holding them made Tor refuse to
  /// start with `Address already in use`. What is left here is the verification that the numbers
  /// written into `torrc` are the numbers something is actually answering on, which is the
  /// failure this whole line of work began with: a report showing
  /// `Connection refused ... port = 52024` while Tor was listening on `39883`.
  ///
  /// Bounded, and a timeout is not an error. A daemon that never opens its listener is reported
  /// by the bootstrap wait with a better message than a timeout here could invent, and the caller
  /// must not be blocked by a check.
  Future<void> _awaitListeners(int socksPort, int controlPort) async {
    for (var attempt = 0; attempt < 60; attempt++) {
      if (_stopping || _process == null) return;
      if (await _isListening(socksPort) && await _isListening(controlPort)) {
        logTor('Tor is listening on socks=$socksPort control=$controlPort');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    // Recorded, not thrown. The mesh will report the failure per contact when it dials, and the
    // log now carries the port it was given — which is what made this undiagnosable before.
    logTor(
      'Tor did not open its listeners within 15s',
      detail: 'expected socks=$socksPort control=$controlPort · '
          'socks listening=${await _isListening(socksPort)} · '
          'control listening=${await _isListening(controlPort)}',
    );
  }

  /// True when something accepts a connection on the loopback port.
  Future<bool> _isListening(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 300),
      );
      socket.destroy();
      return true;
    } on Object {
      return false;
    }
  }

  void _appendLog(String line) {
    if (line.trim().isEmpty) return;
    _log.add(line);
    if (_log.length > _maxLogLines) {
      _log.removeRange(0, _log.length - _maxLogLines);
    }
    if (!_logStream.isClosed) _logStream.add(line);
  }

  /// Tor's last complaint, which is a better error message than anything the
  /// app could synthesise.
  ///
  /// ## Not simply "the last line with [warn] or [err]"
  ///
  /// That is what it used to be, and for a configuration Tor cannot parse it produced the
  /// worst possible answer. Tor ends such a start with three lines:
  ///
  /// ```
  /// [warn] Failed to parse/validate config: Bridge line did not parse. See logs for details.
  /// [err]  Reading config failed--see warnings above.
  /// ```
  ///
  /// Reading backwards, the first match is the `[err]` — the one line that names no cause
  /// at all, and that refers the reader to warnings which are not shown anywhere. That is
  /// the message the user reported, and it is why the failure looked unexplained.
  ///
  /// So the search prefers a line that actually says something over the generic summary:
  /// the first complaint found that is not Tor's own pointer to other lines. Only when
  /// there is nothing else does the pointer get used.
  String? _lastErrorLine() {
    const generic = <String>[
      'Reading config failed',
      'see warnings above',
      'See logs for details',
    ];

    String? fallback;
    String? specific;

    for (final line in _log.reversed) {
      if (!line.contains('[err]') && !line.contains('[warn]')) continue;
      final index = line.indexOf(']');
      final message = index >= 0 ? line.substring(index + 1).trim() : line.trim();
      if (message.isEmpty) continue;

      // A configuration that would not parse is the case worth spending effort on, because
      // it is the one where the daemon does not start at all and the user has no way to
      // guess which line is at fault.
      if (message.contains('Failed to parse') || message.contains('Bridge line did not parse')) {
        final bridges = _bridgeConfigProblem();
        if (bridges != null) return bridges;
        return '$message ${_bridgeLinesHint()}';
      }

      if (generic.any(message.contains)) {
        // Kept only in case nothing better exists.
        fallback ??= message;
        continue;
      }
      // Some warnings are Tor being chatty about its own defaults — a relative GeoIPFile,
      // a control port with no authentication while the daemon is still starting — and
      // showing one of those as the reason for a failed start would be actively
      // misleading.
      if (_isIncidentalWarning(message)) continue;
      specific = message;
      break;
    }

    return specific ?? fallback;
  }

  /// Names the bridge line that Tor refused, when one of the configured lines is at fault.
  ///
  /// This is the difference between "Bridge line did not parse" and knowing which line to
  /// delete. The check runs against the lines that are actually in the settings, so it
  /// describes the user's own configuration rather than a guess.
  String? _bridgeConfigProblem() {
    final lines = _settings.bridgeLines;
    if (lines.isEmpty) return null;

    for (final line in lines) {
      final problem = bridgeLineProblem(line);
      if (problem != null) {
        return 'A bridge line could not be used, and Tor will not start until it is '
            'corrected or removed. $problem';
      }
    }
    return null;
  }

  /// The next step, for a bridge Tor refused without DarkFlow being able to say which.
  String _bridgeLinesHint() => _settings.bridgeLines.isEmpty
      ? ''
      : 'Tor will not start while any configured bridge line is malformed. Check the '
          'lines under Tor bridge settings, or remove them and connect directly.';

  /// True for warnings that describe Tor's own defaults rather than a failure.
  ///
  /// These appear on every single start, successful ones included, so they cannot be the
  /// reason a start failed even when they are the last thing in the log.
  static bool _isIncidentalWarning(String message) {
    const incidental = <String>[
      'is relative and will resolve to',
      'ControlPort is open, but no authentication method has been configured',
      'Tor can\'t help you if you use it wrong',
      'is deprecated; use',
      // The bridge this complaint is about is not necessarily the one that failed, and the
      // specific "Bridge line did not parse" that follows it is the actionable one.
      'Key digest for Bridge is wrong length',
    ];
    return incidental.any(message.contains);
  }

  /// Reads the tail of Tor's own log file and returns its last warning or
  /// error.
  ///
  /// This is what turns an opaque "exited with code 1" into a sentence the user
  /// can act on, such as the data-directory lock conflict that an orphaned
  /// daemon causes.
  Future<String?> _lastErrorFrom(Directory dataDirectory) async {
    final file = File(
      '${dataDirectory.path}${Platform.pathSeparator}notices.log',
    );
    try {
      if (!await file.exists()) return null;
      final lines = await file.readAsLines();
      for (final line in lines.reversed.take(40)) {
        if (line.contains('[err]')) {
          final index = line.indexOf('[err]');
          return line.substring(index + 5).trim();
        }
      }
      for (final line in lines.reversed.take(40)) {
        if (line.contains('[warn]')) {
          final index = line.indexOf('[warn]');
          return line.substring(index + 6).trim();
        }
      }
    } on Object {
      // A log that cannot be read is not itself worth reporting.
    }
    return null;
  }

  void _setStatus(TorStatus next) {
    _status = next;
    _notify();
  }

  /// [notifyListeners] for code that can outlive the manager.
  ///
  /// Two things reach `_setStatus` after `dispose` is entirely possible: the
  /// control-port event stream, which is cancelled asynchronously, and the
  /// process-exit handler installed with `unawaited`. Neither checked anything,
  /// so a Tor event landing during shutdown crashed on
  /// "A TorManager was used after being disposed" — the same defect that made
  /// the test suite look flaky until the message was actually read.
  void _notify() {
    if (_eventsClosed) return;
    notifyListeners();
  }
}

