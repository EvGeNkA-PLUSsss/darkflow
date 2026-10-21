import 'dart:io';

import 'package:darkflow/src/tor/tor_paths.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where the Tor runtime is looked for.
///
/// A small surface with a large consequence: if the lookup looks in the wrong
/// place, the app installs, opens, and then reports that Tor is missing the first
/// time somebody presses Connect. It moved once already — from a Flutter asset to
/// a directory beside the executable — for a reason worth keeping: Flutter copies
/// every declared asset directory into every platform's build, so a 119 MB Windows
/// runtime declared that way travelled inside the Android APK.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('darkflow-torpaths-');
    // `getApplicationSupportDirectory` is a platform channel and has no
    // implementation under `flutter test`. The asset fallback calls it, so a
    // plausible directory is supplied for every test that reaches that path.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => sandbox.path,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (sandbox.existsSync()) await sandbox.delete(recursive: true);
  });

  /// An empty bundle, standing in for a build that declares no Tor assets.
  ///
  /// That is what a current build looks like: the runtime is beside the
  /// executable, and the asset fallback exists only for a build that predates the
  /// move.
  AssetBundle emptyBundle() => _EmptyBundle();

  Directory torDir() => Directory(
        '${sandbox.path}${Platform.pathSeparator}${TorBinaryLocator.runtimeDirectoryName}',
      );

  TorBinaryLocator locator() => TorBinaryLocator(
        bundle: emptyBundle(),
        executableDirectory: sandbox,
      );

  group('the runtime is found beside the executable', () {
    test('is supported on this platform', () {
      // Windows, Linux, macOS and Android all ship a runtime; iOS does not.
      expect(TorBinaryLocator().isSupported, Platform.isIOS ? isFalse : isTrue);
    });

    test('runtimeDirectory points at <executable dir>/tor', () async {
      torDir().createSync(recursive: true);
      final directory = await locator().runtimeDirectory();
      expect(directory.path, torDir().path);
    });

    test('torExecutable resolves the daemon when it is present', () async {
      torDir().createSync(recursive: true);
      // The name differs by platform, and so does the lookup.
      final binaryName = Platform.isWindows ? 'tor.exe' : 'tor';
      File('${torDir().path}${Platform.pathSeparator}$binaryName').writeAsStringSync('stub');

      expect(
        await locator().torExecutable(),
        '${torDir().path}${Platform.pathSeparator}$binaryName',
      );
    });

    test('a missing daemon names the directory that was searched', () async {
      // The executable bits matter: "Tor is missing" with no path is
      // unactionable on somebody else's machine. The directory exists but the
      // binary is not in it, which is what a partly-copied runtime looks like.
      torDir().createSync(recursive: true);
      await expectLater(
        locator().torExecutable(),
        throwsA(
          isA<TorBinaryMissingException>().having(
            (TorBinaryMissingException e) => e.toString(),
            'message',
            contains(torDir().path),
          ),
        ),
      );
    });

    test('transportPaths is empty for a runtime directory with no binaries',
        () async {
      torDir().createSync(recursive: true);
      // On Android the lookup goes through the native library channel and needs a
      // platform that answers it, so this covers the desktop path only.
      if (Platform.isAndroid) return;
      expect(await locator().transportPaths(), isEmpty);
    });
  });

  group('the asset fallback', () {
    test('an undeclared asset becomes a TorBinaryMissingException', () async {
      // `rootBundle.loadString` throws a plain Flutter error for an asset the
      // build does not declare, which says nothing about Tor and nothing about
      // what to do. The locator has to translate that into its own type; this
      // asserts the translation rather than the wording.
      //
      // No `tor/` directory exists here, so the fallback is what runs.
      expect(torDir().existsSync(), isFalse);
      Object? thrown;
      try {
        await locator().runtimeDirectory();
      } on Object catch (error) {
        thrown = error;
      }
      expect(thrown, isA<TorBinaryMissingException>());
    });
  });

  group('transport discovery', () {
    test('maps binary names to the names torrc uses', () {
      // torrc's ClientTransportPlugin lines are keyed by these, so a mismatch
      // means a bridge line naming a transport Tor was never told about.
      expect(TorBinaryLocator.normaliseTransportName('obfs4proxy'), 'obfs4');
      expect(TorBinaryLocator.normaliseTransportName('snowflake-client'), 'snowflake');
      expect(TorBinaryLocator.normaliseTransportName('webtunnel-client'), 'webtunnel');
      expect(TorBinaryLocator.normaliseTransportName('meek-client'), 'meek');
      expect(TorBinaryLocator.normaliseTransportName('conjure-client'), 'conjure');
      // The unified transport keeps its own name, because torrc names it directly.
      expect(TorBinaryLocator.normaliseTransportName('lyrebird'), 'lyrebird');
      // And a Windows file name loses its extension first.
      expect(TorBinaryLocator.normaliseTransportName('lyrebird.exe'), 'lyrebird');
    });

    test('every known transport binary is listed', () {
      expect(
        TorBinaryLocator.transports,
        containsAll(<String>[
          'obfs4proxy',
          'lyrebird',
          'snowflake-client',
          'webtunnel-client',
          'meek-client',
          'conjure-client',
        ]),
      );
    });
  });
}

/// An [AssetBundle] with nothing in it, which is what a build that keeps its Tor
/// runtime beside the executable looks like.
class _EmptyBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    throw FlutterError('Unable to load asset: $key');
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    throw FlutterError('Unable to load asset: $key');
  }
}
