import 'dart:io';
import 'dart:typed_data';

import '../crypto/onion_address.dart';
import '../data/models/tor_settings.dart';
import 'bridge_line.dart';

/// Renders the `torrc` DarkFlow hands to the daemon.
///
/// Everything is generated rather than shipped, so the ports, data directory
/// and hidden-service keys always match the running installation, and so the
/// bridge configuration can be rewritten atomically when the user changes it.
abstract final class TorConfig {
  /// The comment banner written at the top of every generated torrc.
  static const String header =
      '## DarkFlow — generated torrc. Edits are overwritten on every start.';

  /// Builds the configuration file contents.
  ///
  /// [transportPaths] maps a pluggable-transport name (`obfs4`, `snowflake`,
  /// `webtunnel`, `meek`) to the absolute path of the client binary that
  /// implements it.
  static String build({
    required TorSettings settings,
    required Directory dataDirectory,
    required Directory hiddenServiceDirectory,
    required int socksPort,
    required int controlPort,
    required String cookieAuthFile,
    required int onionServiceTargetPort,
    Map<String, String> transportPaths = const <String, String>{},
    String? geoIpFile,
    String? geoIpV6File,
    int? owningProcessId,
  }) {
    final buffer = StringBuffer()
      ..writeln(header)
      ..writeln()

      // ------------------------------------------------------------ storage
      ..writeln('DataDirectory ${_quote(dataDirectory.path)}')
      ..writeln('AvoidDiskWrites 1')
      ..writeln('SafeLogging 1')
      ..writeln('Log notice file ${_quote('${dataDirectory.path}${Platform.pathSeparator}notices.log')}')
      ..writeln()

      // ----------------------------------------------------------- listeners
      // A SOCKS port with isolation would break connection reuse for the
      // long-lived peer connections, so plain SOCKS5 is used.
      ..writeln('SocksPort 127.0.0.1:$socksPort')
      ..writeln('ControlPort 127.0.0.1:$controlPort')
      ..writeln('CookieAuthentication 1')
      ..writeln('CookieAuthFile ${_quote(cookieAuthFile)}')
      ..writeln();

    // Tor exits on its own when this process dies.
    //
    // Without it, a daemon outlives a crashed or force-killed app and keeps the
    // DataDirectory lock. The next launch then fails with
    // "another Tor process is running with the same data directory … Exiting",
    // which is exactly what happened before this line existed. The double
    // underscore marks the option as controller-only, which is what this is.
    if (owningProcessId != null) {
      buffer
        ..writeln('__OwningControllerProcess $owningProcessId')
        ..writeln();
    }

    // Tor reads these to map relays to countries. Without them, country-based
    // entry and exit rules silently do nothing, which is worse than failing
    // loudly, so the bundled copies are always named explicitly rather than
    // left to be discovered by luck in the data directory.
    if (geoIpFile != null && geoIpFile.isNotEmpty) {
      buffer.writeln('GeoIPFile ${_quote(geoIpFile)}');
    }
    if (geoIpV6File != null && geoIpV6File.isNotEmpty) {
      buffer.writeln('GeoIPv6File ${_quote(geoIpV6File)}');
    }
    if (geoIpFile != null || geoIpV6File != null) {
      buffer.writeln();
    }

    // -------------------------------------------------------------- bridges
    //
    // Bridges are used if and only if there are bridge lines.
    //
    // `UseBridges 1` with no `Bridge` lines is not a usable configuration: Tor
    // starts, finds nothing to connect to, and the user stares at a bootstrap
    // that never moves. Equally, `UseBridges 0` while the box is full of lines
    // is worse — it silently ignores an explicit instruction. The lines are the
    // deciding fact, not the preset dropdown, which is what the earlier
    // `settings.usesBridges &&` did wrong.
    final hasBridgeLines = settings.bridgeLines.isNotEmpty;
    if (hasBridgeLines) {
      // The lines that will actually be written.
      //
      // Computed before anything is emitted, because `UseBridges` has to follow what
      // survived rather than what was configured. Writing `UseBridges 1` with every line
      // dropped is the very state this file's own comment calls unusable: Tor starts, finds
      // nothing to connect to, and the user watches a bootstrap that never moves.
      final usable = <String>[];
      final ignored = <String, String>{};
      for (final line in settings.bridgeLines) {
        final problem = bridgeLineProblem(line);
        if (problem == null) {
          usable.add(line);
        } else {
          ignored[line] = problem;
        }
      }

      if (usable.isEmpty) {
        // Nothing usable survived, so the honest configuration is a direct connection.
        // Leaving `UseBridges 1` here would strand the user on a dead bootstrap — Tor starts,
        // finds nothing to connect to, and the progress bar never moves.
        //
        // Not an early return: the onion service and the rest of the file still have to be
        // written, and skipping them would leave the account with no address at all, which
        // is a far worse failure than the one being fixed.
        buffer
          ..writeln('## Every configured bridge line was unusable, so bridges are off.')
          ..writeln('## Fix or remove them under Tor bridge settings.')
          ..writeln('UseBridges 0')
          ..writeln();
        for (final entry in ignored.entries) {
          buffer
            ..writeln('## Ignored, because Tor will not start while it is present:')
            ..writeln('## ${entry.value}');
        }
      } else {
        // `UseBridges 1`, and nothing else.
        //
        // There used to be two more lines here: the deprecated
        // `ClientBootstrapConsensus*DownloadSchedule` pair. See the note in the history —
        // Tor 0.4.9 warns about both, their values were Tor's own defaults, and the warning
        // read like the cause of a failure it had nothing to do with.
        buffer.writeln('UseBridges 1');

        // Register the transports the chosen preset actually needs, plus any that appear in
        // hand-written bridge lines.
        final needed = <String>{...settings.requiredTransports};
        for (final line in usable) {
          final transport = _transportOf(line);
          if (transport != null) needed.add(transport);
        }
        for (final transport in needed) {
          final path = transportPaths[transport];
          if (path == null || path.isEmpty) continue;
          buffer.writeln('ClientTransportPlugin $transport exec ${_quote(path)}');
        }

        // Malformed lines are dropped rather than written.
        //
        // This is the recovery path, and it matters more than the validation on the settings
        // screen. A line saved by an older build — or by a paste the user has already
        // forgotten — cannot be stopped from being stored, and while it is in the
        // configuration Tor refuses to start *at all*: `tor.exe` exits 1 with "Reading config
        // failed--see warnings above" and the application has no network. The reported
        // symptom was exactly that, and the only way out the user found was to delete the
        // account.
        //
        // Dropping one bad line means the rest of the configuration still runs. The reason is
        // written as a comment so nothing is lost silently.
        for (final line in usable) {
          buffer.writeln(line.startsWith('Bridge ') ? line : 'Bridge $line');
        }
        for (final entry in ignored.entries) {
          buffer
            ..writeln('## Ignored, because Tor will not start while it is present:')
            ..writeln('## ${entry.value}');
        }
        buffer.writeln();
      }
    } else {
      buffer
        ..writeln('UseBridges 0')
        ..writeln();
    }

    // ------------------------------------------------------- onion service
    if (settings.enableOnionService) {
      buffer
        ..writeln('HiddenServiceDir ${_quote(hiddenServiceDirectory.path)}')
        ..writeln('HiddenServiceVersion 3')
        // The virtual port peers dial. Port 80 is what the rest of the mesh
        // expects, and 443-looking traffic survives more middleboxes.
        ..writeln('HiddenServicePort ${settings.virtualPort} 127.0.0.1:$onionServiceTargetPort')
        // Keep the introduction points stable so peers can reach us after a
        // restart without waiting for a fresh descriptor to propagate.
        ..writeln('HiddenServiceMaxStreams 64')
        ..writeln('HiddenServiceMaxStreamsCloseCircuit 0')
        ..writeln();
    }

    // ------------------------------------------------------- miscellaneous
    if (settings.strictNodes) {
      buffer.writeln('StrictNodes 1');
    }
    // Tor's own bandwidth accounting is unnecessary on a client and would
    // throttle file transfers.
    buffer
      ..writeln('BandwidthRate 5 MB')
      ..writeln('BandwidthBurst 10 MB')
      ..writeln('ConnectionPadding 1')
      ..writeln('ReducedConnectionPadding 0');

    final extra = settings.extraConfig.trim();
    if (extra.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## user-supplied configuration')
        ..writeln(extra);
    }

    return buffer.toString();
  }

  /// Extracts the transport name from a `Bridge obfs4 …` line.
  static String? _transportOf(String line) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return null;
    // `parts.first == 'Bridge'` was case-sensitive, and torrc keywords are not.
    // Given `bridge obfs4 1.2.3.4:443 …` the transport was therefore read as
    // "bridge", no `ClientTransportPlugin` line was written, and the emitted line
    // became `Bridge bridge obfs4 …` — so Tor had a bridge it could not speak to
    // and the bootstrap stalled at 10% with the screen insisting a bridge was
    // configured.
    final index = parts.first.toLowerCase() == 'bridge' ? 1 : 0;
    if (index >= parts.length) return null;
    final transport = parts[index].toLowerCase();
    if (transport.contains(':')) return null; // a plain IP:port bridge
    return transport;
  }

  /// Quotes a value for torrc when it contains characters Tor would otherwise
  /// split on. Windows paths routinely contain spaces.
  static String _quote(String value) {
    if (!value.contains(' ') && !value.contains('\t')) return value;
    return '"${value.replaceAll(r'\', r'\\')}"';
  }
}

/// Writes and validates the Ed25519 key material behind a v3 onion service.
///
/// The account's identity key *is* the hidden-service key. That is what makes
/// "your onion address is your username" true: the address is derived from the
/// same key that signs messages, so a peer who knows the address already knows
/// the identity it should be talking to.
abstract final class HiddenServiceKeys {
  /// Tor's fixed-size key file header.
  static const int headerLength = 32;

  /// `== ed25519v1-secret: type0 ==` followed by NUL padding to 32 bytes.
  static final Uint8List secretHeader = _header('== ed25519v1-secret: type0 ==');

  /// `== ed25519v1-public: type0 ==` followed by NUL padding to 32 bytes.
  static final Uint8List publicHeader = _header('== ed25519v1-public: type0 ==');

  static const String secretFileName = 'hs_ed25519_secret_key';
  static const String publicFileName = 'hs_ed25519_public_key';
  static const String hostnameFileName = 'hostname';

  /// Writes the three files Tor expects into [directory].
  ///
  /// [secretKey] is the 64-byte Ed25519 secret key in libsodium's layout
  /// (`seed || publicKey`), which is byte-for-byte what Tor stores.
  static Future<String> write({
    required Directory directory,
    required Uint8List secretKey,
    required Uint8List publicKey,
  }) async {
    if (secretKey.length != 64) {
      throw ArgumentError.value(
        secretKey.length,
        'secretKey',
        'an Ed25519 secret key is 64 bytes (32-byte seed followed by the public key)',
      );
    }
    if (publicKey.length != 32) {
      throw ArgumentError.value(
        publicKey.length,
        'publicKey',
        'an Ed25519 public key is 32 bytes',
      );
    }
    await directory.create(recursive: true);

    final onionAddress = OnionAddress.fromPublicKey(publicKey);

    await _writeBytes(
      File('${directory.path}${Platform.pathSeparator}$secretFileName'),
      Uint8List.fromList(<int>[...secretHeader, ...secretKey]),
    );
    await _writeBytes(
      File('${directory.path}${Platform.pathSeparator}$publicFileName'),
      Uint8List.fromList(<int>[...publicHeader, ...publicKey]),
    );
    await File('${directory.path}${Platform.pathSeparator}$hostnameFileName')
        .writeAsString('$onionAddress\n');

    return onionAddress;
  }

  /// Reads back the key files, returning the public key they describe.
  static Future<Uint8List?> readPublicKey(Directory directory) async {
    final file = File('${directory.path}${Platform.pathSeparator}$publicFileName');
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.length < headerLength + 32) return null;
    return Uint8List.fromList(bytes.sublist(headerLength, headerLength + 32));
  }

  /// True when the directory already holds a usable key pair.
  static Future<bool> exists(Directory directory) async {
    final secret = File('${directory.path}${Platform.pathSeparator}$secretFileName');
    final public = File('${directory.path}${Platform.pathSeparator}$publicFileName');
    return await secret.exists() && await public.exists();
  }

  /// Rewrites the file permissions on POSIX systems so Tor accepts the key.
  ///
  /// Tor refuses to start when the hidden-service directory is group- or
  /// world-accessible. Windows has no equivalent check.
  static Future<void> hardenPermissions(Directory directory) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', <String>['700', directory.path]);
    } on ProcessException {
      // Best effort: Tor will report a clearer error if it still objects.
    }
  }

  static Future<void> _writeBytes(File file, Uint8List bytes) async {
    await file.writeAsBytes(bytes, flush: true);
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', <String>['600', file.path]);
    } on ProcessException {
      // Ignored for the same reason as above.
    }
  }

  static Uint8List _header(String prefix) {
    final bytes = Uint8List(headerLength);
    final encoded = prefix.codeUnits;
    bytes.setRange(0, encoded.length, encoded);
    // The remaining bytes stay zero, matching Tor's own padding.
    return bytes;
  }
}
