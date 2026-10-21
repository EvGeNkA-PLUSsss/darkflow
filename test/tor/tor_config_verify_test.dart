import 'dart:io';

import 'package:darkflow/src/data/models/tor_settings.dart';
import 'package:darkflow/src/tor/tor_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// The generated configuration is checked by the daemon itself before it is used.
///
/// ## What this is for
///
/// Tor has no partial start. A file it cannot parse makes it log three lines, end with
/// "Reading config failed--see warnings above", and exit — after which the application shows a
/// bootstrap stuck at 0% with that sentence as its only explanation. That was reported, and the
/// user's recovery was to delete the account.
///
/// `--verify-config` asks the daemon the question *before* it becomes the reason nothing works.
/// These tests run the real `tor.exe` when one is present, so they check the behaviour against
/// the program that actually decides, not against a description of it.
void main() {
  /// The staged Tor runtime, which is where the release build keeps it.
  File? findTor() {
    const candidates = <String>[
      r'build\windows\x64\runner\Release\tor\tor.exe',
      r'build\windows\x64\runner\Profile\tor\tor.exe',
    ];
    for (final path in candidates) {
      final file = File(path);
      if (file.existsSync()) return file;
    }
    return null;
  }

  late Directory root;
  late Directory data;
  late Directory hidden;
  late File tor;
  late int socksPort;
  late int controlPort;

  /// A port the operating system says is free.
  ///
  /// Not zero: `SocksPort 0` is a valid *torrc* value meaning "pick one", but it is not a valid
  /// value in a file handed to `--verify-config`, which rejected the whole configuration and
  /// made three tests fail for a reason that had nothing to do with what they check.
  Future<int> freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('df-verify-');
    data = Directory('${root.path}${Platform.pathSeparator}data')..createSync();
    hidden = Directory('${root.path}${Platform.pathSeparator}hs')..createSync();
    tor = findTor() ?? File('');
    socksPort = await freePort();
    controlPort = await freePort();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String buildTorrc(TorSettings settings) => TorConfig.build(
        settings: settings,
        dataDirectory: data,
        hiddenServiceDirectory: hidden,
        socksPort: socksPort,
        controlPort: controlPort,
        cookieAuthFile: '${root.path}${Platform.pathSeparator}cookie',
        onionServiceTargetPort: 12345,
      );

  /// Runs `--verify-config` the way `TorManager` does, and returns its combined output.
  Future<({int code, String output})> verify(String torrc) async {
    final file = File('${root.path}${Platform.pathSeparator}torrc')
      ..writeAsStringSync(torrc);
    final result = await Process.run(
      tor.path,
      <String>['--verify-config', '-f', file.path],
      workingDirectory: root.path,
    );
    return (code: result.exitCode, output: '${result.stdout}\n${result.stderr}');
  }

  group('against the real daemon', () {
    test('a good configuration is accepted and says nothing about bridges', () async {
      if (!tor.existsSync()) {
        markTestSkipped('no staged tor.exe; run tool/stage_tor_runtime.ps1 first');
        return;
      }

      final result = await verify(buildTorrc(TorSettings(
        customBridges: 'obfs4 192.0.2.10:443 '
            '47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 cert=abcdEFGH12345678',
        mode: BridgeMode.obfs4,
      )));

      expect(result.code, 0, reason: 'the generated file has to be usable: ${result.output}');
      expect(result.output, isNot(contains('deprecated')),
          reason: 'the options Tor 0.4.9 warns about must not be written');
      expect(result.output, isNot(contains('Bridge line did not parse')));
    });

    test('a malformed line never reaches the file', () async {
      // The recovery path. `TorConfig.build` drops a line it knows Tor will refuse, so the
      // daemon accepts the rest and the application is not left with no network at all.
      if (!tor.existsSync()) {
        markTestSkipped('no staged tor.exe');
        return;
      }

      final torrc = buildTorrc(TorSettings(
        customBridges: 'webtunnel https://example.com/abc AAAA',
        mode: BridgeMode.webTunnel,
      ));

      expect(torrc, isNot(contains('Bridge webtunnel https://example.com/abc AAAA')));
      expect(torrc, contains('Ignored, because Tor will not start while it is present'));
      // Every line was bad, so bridges are off and the rest of the file still stands.
      expect(torrc, contains('UseBridges 0'));
      expect(torrc, contains('HiddenServiceDir'));

      final result = await verify(torrc);
      expect(result.code, 0,
          reason: 'dropping the bad line must leave a file Tor accepts: ${result.output}');
    });

    test('the file Tor would refuse is the one that used to be written', () async {
      // Proof that the check is not theoretical: written the old way, the daemon refuses, and
      // the reason it gives is the sentence in the report.
      if (!tor.existsSync()) {
        markTestSkipped('no staged tor.exe');
        return;
      }

      final torrc = buildTorrc(TorSettings(
        customBridges: 'webtunnel https://example.com/abc AAAA',
        mode: BridgeMode.webTunnel,
      ))
          // Put the bad line back and turn bridges on, reproducing exactly what the previous
          // build wrote. The ignored-line comments are removed with it so the only thing being
          // tested is the line itself.
          .replaceFirst('UseBridges 0', 'UseBridges 1')
          .split('\n')
          .where((String line) =>
              !line.startsWith('## Ignored') && !line.startsWith('## The fingerprint'))
          .join('\n')
          .replaceFirst(
            'UseBridges 1',
            'Bridge webtunnel https://example.com/abc AAAA\nUseBridges 1',
          );

      final result = await verify(torrc);
      expect(result.code, isNot(0), reason: 'this is the configuration that broke reports');
      expect(result.output, contains('Reading config failed'),
          reason: 'and this is the only explanation the user was given');
      expect(result.output, contains('Bridge line did not parse'),
          reason: 'while the sentence that names the cause is in the same output');
    });
  });
}
