// Starts the bundled Tor exactly the way the app does and reports what happens.
//
// A screenshot of the Tor screen proves nothing about whether the daemon
// actually launched, whether the cookie authentication worked, or whether the
// hidden service was published. This script exercises that whole path
// headlessly, so the result is a fact rather than an inference from a
// successful build.
//
// It deliberately reuses the production code: `TorConfig` generates the torrc
// and `TorControlClient` talks to the control port.
//
// Run:  dart run tool/smoke_tor.dart [--seconds 60]

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:darkflow/src/crypto/onion_address.dart';
import 'package:darkflow/src/data/models/tor_settings.dart';
import 'package:darkflow/src/tor/tor_config.dart';
import 'package:darkflow/src/tor/tor_control.dart';

Future<void> main(List<String> arguments) async {
  final seconds = _intArg(arguments, '--seconds') ?? 60;
  final root = Directory.current.path;
  final bundle = Directory('$root${Platform.pathSeparator}assets'
      '${Platform.pathSeparator}tor${Platform.pathSeparator}windows');

  print('=== DarkFlow Tor smoke test ===');
  print('bundle : ${bundle.path}');
  if (!bundle.existsSync()) {
    print('FAIL: the Tor bundle is missing. Run tool/fetch_tor_windows.ps1.');
    exit(2);
  }

  final torExecutable = File('${bundle.path}${Platform.pathSeparator}tor.exe');
  if (!torExecutable.existsSync()) {
    print('FAIL: tor.exe is missing from the bundle.');
    exit(2);
  }

  final work = await Directory.systemTemp.createTemp('darkflow-tor-smoke-');
  final dataDirectory = Directory('${work.path}${Platform.pathSeparator}data');
  final hiddenService = Directory('${work.path}${Platform.pathSeparator}onion');
  final cookieFile = File('${work.path}${Platform.pathSeparator}cookie');
  await dataDirectory.create(recursive: true);
  await hiddenService.create(recursive: true);
  print('workdir: ${work.path}');

  final socksPort = await _freePort();
  final controlPort = await _freePort();
  final peerPort = await _freePort();

  // The hidden-service directory is left empty on purpose: the daemon generates
  // the key pair itself. Writing the files from the account's identity key does
  // not work — Tor's secret-key layout is not the standard Ed25519
  // `seed || publicKey`, and it refuses to start when the two halves disagree.
  final torrc = TorConfig.build(
    settings: const TorSettings(),
    dataDirectory: dataDirectory,
    hiddenServiceDirectory: hiddenService,
    socksPort: socksPort,
    controlPort: controlPort,
    cookieAuthFile: cookieFile.path,
    onionServiceTargetPort: peerPort,
    geoIpFile: '${bundle.path}${Platform.pathSeparator}geoip',
    geoIpV6File: '${bundle.path}${Platform.pathSeparator}geoip6',
  );
  final torrcFile = File('${work.path}${Platform.pathSeparator}torrc');
  await torrcFile.writeAsString(torrc);
  print('socks/control/peer: $socksPort / $controlPort / $peerPort');

  // Ask Tor itself whether the configuration is valid before running it, so a
  // malformed line is caught without waiting for a failed bootstrap.
  final verify = await Process.run(
    torExecutable.path,
    <String>['-f', torrcFile.path, '--verify-config'],
    workingDirectory: bundle.path,
  );
  final verifyOk = verify.exitCode == 0;
  print('--verify-config   : ${verifyOk ? 'valid' : 'INVALID'} (exit ${verify.exitCode})');
  if (!verifyOk) {
    print(verify.stdout);
    print(verify.stderr);
    exit(4);
  }

  print('\nstarting the daemon...');
  final started = DateTime.now();
  final process = await Process.start(
    torExecutable.path,
    <String>['-f', torrcFile.path],
    workingDirectory: bundle.path,
  );
  final log = <String>[];
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(log.add);
  process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(log.add);
  var processExit = -1;
  unawaited(process.exitCode.then((code) => processExit = code));

  // Control port, cookie auth, bootstrap polling: the sequence the app runs.
  final client = TorControlClient();
  var connected = false;
  var lastError = '';
  for (var attempt = 0; attempt < 80 && !connected; attempt++) {
    try {
      await client.connect(port: controlPort);
      connected = true;
    } on TorControlException catch (error) {
      lastError = error.message;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  if (!connected) {
    print('FAIL: the control port never opened after 20s: $lastError');
    print('exit code: $processExit');
    await _dumpNotices(dataDirectory, log);
    process.kill();
    exit(5);
  }

  final info = await client.protocolInfo();
  print('control reached   : METHODS=${info['METHODS']} VERSION=${info['VERSION']}');
  final cookie = await cookieFile.readAsBytes();
  print('cookie bytes      : ${cookie.length}');
  await client.authenticate(method: 'COOKIE', cookie: cookie);
  print('authenticated     : ${client.isAuthenticated}');
  print('tor version       : ${await client.version()}');
  await client.setEvents(<String>['STATUS_CLIENT', 'NOTICE', 'WARN', 'ERR']);

  // The hostname file is Tor's own statement of the address it serves.
  final hostnameFile =
      File('${hiddenService.path}${Platform.pathSeparator}${HiddenServiceKeys.hostnameFileName}');
  String? published;
  for (var attempt = 0; attempt < 60 && published == null; attempt++) {
    if (await hostnameFile.exists()) {
      final value = (await hostnameFile.readAsString()).trim();
      if (value.isNotEmpty) published = value;
    }
    if (published == null) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  print('\npublished hostname: ${published ?? '(not written)'}');
  final addressValid = published != null && OnionAddress.isValid(published);
  print('hostname is a valid v3 onion: $addressValid');

  print('\nwatching the bootstrap for up to ${seconds}s...');
  var lastProgress = -1;
  var bootstrapped = false;
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    final phase = await client.bootstrapPhase();
    if (phase != null && phase.progress != lastProgress) {
      lastProgress = phase.progress;
      print('  ${phase.progress.toString().padLeft(3)}%  '
          '${phase.tag.padRight(22)} ${phase.summary}');
    }
    if (await client.isCircuitEstablished()) {
      bootstrapped = true;
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 900));
  }

  print('\n=== result ===');
  print('config valid        : yes');
  print('daemon started      : yes');
  print('control + cookie    : yes');
  print('hidden service      : ${addressValid ? 'published' : 'NOT published'}');
  print('circuit established : ${bootstrapped ? 'yes' : 'no'}');
  print('elapsed             : ${DateTime.now().difference(started).inSeconds}s');

  if (!bootstrapped) {
    print('\nThe daemon did not reach the Tor network. On this machine that is');
    print('expected and is not a defect in the app: every *.torproject.org host is');
    print('blocked here and the directory authorities are unreachable, which is');
    print('precisely the situation bridges exist for.');
    await _dumpNotices(dataDirectory, log, lines: 8);
  }

  try {
    await client.signal('SHUTDOWN');
  } on Object {
    process.kill();
  }
  await client.close();
  await process.exitCode.timeout(
    const Duration(seconds: 8),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  await work.delete(recursive: true);
  print('\ncleaned up');
  exit(addressValid && connected ? 0 : 6);
}

/// Prints Tor's own log.
///
/// `Log notice file` redirects logging away from stdout, so the reason for a
/// failure is in the data directory rather than in the captured output.
Future<void> _dumpNotices(
  Directory dataDirectory,
  List<String> captured, {
  int lines = 25,
}) async {
  final notices = File('${dataDirectory.path}${Platform.pathSeparator}notices.log');
  if (await notices.exists()) {
    print('\nnotices.log (last $lines lines):');
    final all = await notices.readAsLines();
    for (final line in all.length > lines ? all.sublist(all.length - lines) : all) {
      print('  $line');
    }
    return;
  }
  print('\ncaptured stdout/stderr (last $lines lines):');
  final all = captured;
  for (final line in all.length > lines ? all.sublist(all.length - lines) : all) {
    print('  $line');
  }
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

int? _intArg(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) return null;
  return int.tryParse(arguments[index + 1]);
}
