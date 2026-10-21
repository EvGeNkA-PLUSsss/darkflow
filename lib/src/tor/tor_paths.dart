import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Raised when the bundled Tor runtime cannot be found or made executable.
class TorBinaryMissingException implements Exception {
  const TorBinaryMissingException(this.message, {this.remedy});

  final String message;
  final String? remedy;

  @override
  String toString() => remedy == null ? message : '$message\n$remedy';
}

/// Locates the Tor daemon and its pluggable transports.
///
/// DarkFlow ships Tor rather than requiring the user to install it, because a
/// censorship-circumvention tool that depends on a second app store listing is
/// one takedown away from being useless. That means the binaries have to be
/// found in three very different places:
///
///  * **Windows / Linux / macOS** — a `tor` directory beside the executable,
///    placed there by the build (`tool/stage_tor_runtime.ps1`). A filesystem
///    directory rather than a Flutter asset, for the reason below.
///  * **Android** — the platform forbids executing anything from the app's
///    writable data directory, so the same binaries are packaged as
///    `jniLibs/lib*.so` and executed straight out of the read-only
///    `nativeLibraryDir`.
///  * **iOS** — unavailable by design; the app falls back to a user-supplied
///    proxy or reports that Tor cannot start.
///
/// ## Why the desktop runtime is not a Flutter asset
///
/// It used to be: `assets/tor/windows/` was declared in pubspec.yaml and unpacked
/// into the application support directory on first run. That cannot be made to
/// work. Flutter copies every declared asset directory into every build on every
/// platform — there is no conditional syntax in pubspec and no Gradle exclusion
/// for Flutter assets — so a 119 MB Windows runtime travelled inside the Android
/// APK, where none of it can execute.
///
/// Leaving it undeclared is not an answer either: an undeclared directory is not
/// bundled at all, so the Windows build shipped without a Tor daemon and failed
/// the first time a user pressed Connect. Both of those were measured, not
/// assumed.
///
/// A directory beside the executable has neither problem. It is not part of the
/// asset bundle, so no Android build can pick it up, and nothing has to be
/// unpacked at startup, so the app does not copy 119 MB on first run.
class TorBinaryLocator {
  /// The bundle is only consulted for a build that predates the runtime move;
  /// [executableDirectory] is overridable so a test can point the lookup at a
  /// temporary directory instead of a real build output.
  TorBinaryLocator({AssetBundle? bundle, Directory? executableDirectory})
      : _bundle = bundle ?? rootBundle,
        // Assigned here rather than as an initialising formal so that callers
        // write `executableDirectory:` instead of `_executableDirectory:`.
        // ignore: prefer_initializing_formals
        _executableDirectory = executableDirectory;

  final AssetBundle _bundle;

  /// Overridable so a test can point the lookup at a temporary directory.
  final Directory? _executableDirectory;

  /// The directories that were unpacked during this run, so the work happens
  /// once per launch instead of per lookup.
  static final Map<String, Directory> _unpacked = <String, Directory>{};

  /// The transport binaries DarkFlow knows how to register.
  static const List<String> transports = <String>[
    'obfs4proxy',
    'lyrebird',
    'snowflake-client',
    'webtunnel-client',
    'meek-client',
    'conjure-client',
  ];

  /// The directory beside the executable that holds the runtime.
  static const String runtimeDirectoryName = 'tor';

  /// The asset folder name for the current platform, or null when unsupported.
  ///
  /// Only used by the legacy bundled-asset fallback; nothing declares these in
  /// pubspec any more. See [bundledAssetFolder].
  static String? get assetPlatformFolder {
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    return null;
  }

  /// The asset folder a build predating the runtime move would have used.
  static String? get bundledAssetFolder => assetPlatformFolder;

  /// True when this build can run a bundled Tor daemon.
  bool get isSupported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS || Platform.isAndroid;

  /// Absolute path to the Tor executable, unpacking it if necessary.
  Future<String> torExecutable() async {
    if (Platform.isAndroid) {
      return _androidBinary('tor');
    }
    final directory = await runtimeDirectory();
    return _requireFile(directory, Platform.isWindows ? 'tor.exe' : 'tor');
  }

  /// Absolute paths of every available pluggable transport, keyed by the name
  /// torrc uses in its `ClientTransportPlugin` lines.
  ///
  /// Where a transport has both a dedicated binary and the unified `lyrebird`,
  /// the dedicated one wins: it is the build the Tor Project ships for exactly
  /// that transport, and a failure is easier to attribute. `lyrebird` is the
  /// fallback, and is the only provider of obfs4 in current bundles — upstream
  /// stopped shipping a standalone `obfs4proxy` in 2023.
  Future<Map<String, String>> transportPaths() async {
    final out = <String, String>{};
    if (Platform.isAndroid) {
      // jniLibs naming: lib<name>.so.
      const aliases = <String, String>{
        'obfs4': 'obfs4proxy',
        'webtunnel': 'webtunnel-client',
        'snowflake': 'snowflake-client',
        'meek': 'meek-client',
        'conjure': 'conjure-client',
      };
      for (final entry in aliases.entries) {
        final path = await _tryAndroidBinary(entry.value);
        if (path != null) out[entry.key] = path;
      }
      final lyrebird = await _tryAndroidBinary('lyrebird');
      if (lyrebird != null) {
        out.putIfAbsent('obfs4', () => lyrebird);
      }
      return out;
    }

    final directory = await runtimeDirectory();
    final suffix = Platform.isWindows ? '.exe' : '';

    String? pathOf(String base) {
      final file = File('${directory.path}${Platform.pathSeparator}$base$suffix');
      return file.existsSync() ? file.path : null;
    }

    final lyrebird = pathOf('lyrebird');
    for (final name in transports) {
      final path = pathOf(name);
      if (path == null) continue;
      final transport = normaliseTransportName(name);
      out[transport] = path;
    }
    // obfs4 has no dedicated binary in current Tor releases, so the unified
    // transport covers it.
    if (lyrebird != null) {
      out.putIfAbsent('obfs4', () => lyrebird);
    }
    return out;
  }

  /// Maps a binary file name to the transport name torrc expects.
  static String normaliseTransportName(String fileName) {
    final base = fileName.replaceAll('.exe', '');
    return switch (base) {
      'obfs4proxy' => 'obfs4',
      'snowflake-client' => 'snowflake',
      'webtunnel-client' => 'webtunnel',
      'meek-client' => 'meek',
      'conjure-client' => 'conjure',
      _ => base,
    };
  }

  /// The directory the Tor runtime lives in for this platform.
  ///
  /// On Android that is the read-only native library directory, where libtor.so
  /// and the transports were placed by Gradle — there is nothing to unpack and
  /// nothing writable about it.
  ///
  /// Everywhere else it is `tor/` beside the executable, which the build fills
  /// from `tor_runtime/<platform>/`. When that directory is absent the bundled
  /// assets are tried as a fallback, so a build produced before the runtime moved
  /// keeps working rather than regressing into a dead Connect button.
  ///
  /// The directory is also where `TorManager` looks for `geoip` and `geoip6`.
  /// Those are absent on Android, and that is fine: `GeoIPFile` is optional to
  /// Tor and only affects country lookups, so the manager passes null and the
  /// daemon starts regardless.
  Future<Directory> runtimeDirectory() async {
    if (Platform.isAndroid) {
      final directories = await _androidNativeLibraryDirectories();
      if (directories.isEmpty) {
        throw const TorBinaryMissingException(
          'Android did not report a native library directory.',
          remedy: 'This is an embedding failure rather than a missing file; '
              'the runtime channel is not answering.',
        );
      }
      return Directory(directories.first);
    }

    final beside = _directoryBesideExecutable();
    if (beside.existsSync()) return beside;

    try {
      return await _unpackAssets();
    } on TorBinaryMissingException {
      throw TorBinaryMissingException(
        'The Tor daemon was not found beside the application.',
        remedy: 'Expected it in ${beside.path}. A release is built with '
            'tool/release.ps1, which places it there. For a development run, '
            'stage it with tool/stage_tor_runtime.ps1 and copy the staged files '
            'into the build output directory.',
      );
    }
  }

  /// `tor/` next to the executable for this platform.
  Directory _directoryBesideExecutable() {
    final overridden = _executableDirectory;
    if (overridden != null) {
      return Directory(
        '${overridden.path}${Platform.pathSeparator}$runtimeDirectoryName',
      );
    }
    final executable = Platform.resolvedExecutable;
    final separator = executable.lastIndexOf(Platform.pathSeparator);
    final directory = separator > 0 ? executable.substring(0, separator) : '.';
    return Directory('$directory${Platform.pathSeparator}$runtimeDirectoryName');
  }

  /// Copies the platform's Tor assets into the application support directory.
  ///
  /// Runs once per process; subsequent calls return the cached directory.
  Future<Directory> _unpackAssets() async {
    final platformFolder = assetPlatformFolder;
    if (platformFolder == null) {
      throw TorBinaryMissingException(
        'There is no bundled Tor runtime for this platform.',
        remedy: Platform.isIOS
            ? 'On iOS, configure an external Tor proxy in Settings, or run DarkFlow '
                'on a desktop or Android device.'
            : null,
      );
    }

    final cached = _unpacked[platformFolder];
    if (cached != null && cached.existsSync()) return cached;

    final support = await getApplicationSupportDirectory();
    final destination = Directory('${support.path}${Platform.pathSeparator}tor');

    final String manifest;
    try {
      manifest = await _bundle.loadString('assets/tor/$platformFolder/MANIFEST.json');
    } on Object {
      // An asset the build does not declare, which is what a current build looks
      // like: the runtime ships beside the executable instead.
      //
      // Reported as "not bundled" rather than letting the raw bundle error escape,
      // because "Unable to load asset" from inside a file-system lookup says
      // nothing about what is actually wrong or what to do about it.
      throw TorBinaryMissingException(
        'No Tor runtime is bundled with this build for $platformFolder.',
      );
    }
    final names = _fileNamesFromManifest(manifest);
    if (names.isEmpty) {
      throw TorBinaryMissingException(
        'The bundled Tor runtime for $platformFolder is empty.',
      );
    }

    await destination.create(recursive: true);
    for (final name in names) {
      final assetKey = 'assets/tor/$platformFolder/$name';
      final target = File('${destination.path}${Platform.pathSeparator}$name');
      final bytes = await _bundle.load(assetKey);
      final data = bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
      // Skip the write when the file already matches, so a restart does not
      // rewrite 30 MB of binaries.
      if (target.existsSync() && target.lengthSync() == data.length) {
        await _ensureExecutable(target);
        continue;
      }
      await target.writeAsBytes(data, flush: true);
      await _ensureExecutable(target);
    }

    _unpacked[platformFolder] = destination;
    return destination;
  }

  /// Extracts the file list from the manifest the fetch script produces.
  static List<String> _fileNamesFromManifest(String manifest) {
    final names = <String>[];
    // A tiny hand-rolled scan keeps this class free of a JSON dependency at a
    // point where it runs before the app's services are up.
    final matches = RegExp(r'"name"\s*:\s*"([^"]+)"').allMatches(manifest);
    for (final match in matches) {
      final name = match.group(1);
      if (name != null && !name.contains('/') && !name.contains(r'\')) {
        names.add(name);
      }
    }
    return names;
  }

  Future<void> _ensureExecutable(File file) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', <String>['700', file.path]);
    } on ProcessException {
      // Tor will surface a clearer error if the bit really matters.
    }
  }

  String _requireFile(Directory directory, String name) {
    final file = File('${directory.path}${Platform.pathSeparator}$name');
    if (!file.existsSync()) {
      throw TorBinaryMissingException(
        'The bundled Tor daemon is missing from ${directory.path}.',
        remedy: 'Re-run the asset fetch script, or reinstall the application.',
      );
    }
    return file.path;
  }

  Future<String> _androidBinary(String name) async {
    final path = await _tryAndroidBinary(name);
    if (path == null) {
      throw TorBinaryMissingException(
        'The Tor native library ($name) was not found on disk.',
        remedy: 'This build packages it as lib$name.so and Android extracts it '
            'into the native library directory. The lookup saw: $_lastLookup',
      );
    }
    return path;
  }

  /// Android packages executables as `lib<name>.so` inside the read-only
  /// native library directory, which is the only place the platform allows an
  /// app to execute code from.
  Future<String?> _tryAndroidBinary(String name) async {
    final candidates = <String>['lib$name.so', 'lib${name.replaceAll('-', '_')}.so'];
    for (final directory in await _androidNativeLibraryDirectories()) {
      for (final candidate in candidates) {
        final file = File('$directory${Platform.pathSeparator}$candidate');
        if (file.existsSync()) return file.path;
      }
    }
    return null;
  }

  /// The channel `MainActivity` answers on.
  static const MethodChannel _runtimeChannel = MethodChannel('darkflow/runtime');

  /// Resolved once per process; the path never changes while the app runs.
  static List<String>? _nativeLibraryDirectories;

  /// What the last lookup saw, quoted in the error when a binary is missing.
  ///
  /// Without this the failure message says only that the library is not
  /// packaged, which is false — it is in the APK — and gives no way to tell a
  /// broken channel from a wrong path. On a build that only exists on someone
  /// else's phone, that difference is the whole diagnosis.
  static String _lastLookup = 'not attempted';

  /// Candidate directories that may hold the packaged executables.
  ///
  /// `ApplicationInfo.nativeLibraryDir` is the authoritative answer and is
  /// asked for directly, because it embeds a per-install hash that cannot be
  /// constructed. The directory of `Platform.resolvedExecutable` is kept as a
  /// fallback for an embedding that places the Dart executable beside them.
  Future<List<String>> _androidNativeLibraryDirectories() async {
    final cached = _nativeLibraryDirectories;
    if (cached != null) return cached;

    final directories = <String>[];
    Object? channelFailure;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final reported =
            await _runtimeChannel.invokeMethod<String>('nativeLibraryDir');
        if (reported != null && reported.isNotEmpty) {
          directories.add(reported);
          break;
        }
        channelFailure = 'returned ${reported ?? 'null'}';
      } on Object catch (error) {
        // A platform channel can be briefly unavailable while the engine is
        // still wiring plugins up, so one retry is worth the few milliseconds.
        channelFailure = error;
        if (attempt == 0) await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }

    final executable = Platform.resolvedExecutable;
    final separator = executable.lastIndexOf(Platform.pathSeparator);
    if (separator > 0) {
      final beside = executable.substring(0, separator);
      if (!directories.contains(beside)) directories.add(beside);
    }

    // And the file `MainActivity` writes from `onCreate`.
    //
    // It is written before the Flutter engine exists, so unlike the channel it
    // cannot miss the window in which plugins are not yet registered. Read
    // first because it is the more trustworthy of the two.
    Object? markerFailure;
    try {
      final support = await getApplicationSupportDirectory();
      final marker = File(
        '${support.path}${Platform.pathSeparator}native_library_dir',
      );
      if (await marker.exists()) {
        final reported = (await marker.readAsString()).trim();
        if (reported.isNotEmpty) {
          directories.remove(reported);
          directories.insert(0, reported);
        }
      } else {
        markerFailure = 'absent at ${marker.path}';
      }
    } on Object catch (error) {
      markerFailure = error;
    }

    // Cached only when something was found.
    //
    // Caching an empty answer makes the first lookup permanent: a channel that
    // was not ready yet would poison every later call, including the one made
    // minutes afterwards when the user finally presses Connect. That is a
    // transient failure turned into a permanent one.
    if (directories.isNotEmpty) _nativeLibraryDirectories = directories;

    _lastLookup = 'channel=$channelFailure, '
        'marker=$markerFailure, '
        'resolvedExecutable=$executable, '
        'tried=[${directories.join(', ')}]';
    return directories;
  }
}

/// A record of a binary that was located, used by the diagnostics screen.
@immutable
class TorRuntimeInfo {
  const TorRuntimeInfo({
    required this.torPath,
    required this.transports,
    required this.platformFolder,
  });

  final String? torPath;
  final Map<String, String> transports;
  final String? platformFolder;

  bool get isComplete => torPath != null;
}
