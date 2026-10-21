import 'package:darkflow/src/app/app_controller.dart';
import 'package:darkflow/src/data/vault_store.dart';
import 'package:darkflow/src/design/design.dart';
import 'package:darkflow/src/features/settings/microphone_screen.dart';
import 'package:darkflow/src/features/settings/widgets/microphone_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:io';

/// Choosing the recording input, and the stored choice surviving a restart.
///
/// The picker is fed its device list rather than asking a plugin, so these run
/// without an audio device — which is the point: the interesting behaviour is what
/// the screen does with the list, and what happens when the list is empty or the
/// platform refuses to produce one.
void main() {
  Widget host(Widget child) => MaterialApp(theme: AppTheme.build(), home: child);

  /// Opens a screen and lets it finish reading its device list.
  ///
  /// No surface size is forced here, and that is deliberate: an earlier version of
  /// this helper widened the window to hide a two-pixel overflow in the picker. The
  /// overflow was real, in the loading row, and hiding it would have shipped it.
  Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(host(screen));
    await tester.pumpAndSettle();
  }

  group('the picker offers the devices it is given', () {
    testWidgets('every device is listed, with the chosen one marked',
        (tester) async {
      String? chosen;
      await tester.pumpWidget(host(Scaffold(
        body: MicrophonePicker(
          devices: const <MicrophoneOption>[
            MicrophoneOption(id: 'mic-a', label: 'Headset microphone'),
            MicrophoneOption(id: 'mic-b', label: 'Built-in array'),
          ],
          selectedId: 'mic-b',
          onSelected: (String? id) => chosen = id,
        ),
      )));

      expect(find.text('Headset microphone'), findsOneWidget);
      expect(find.text('Built-in array'), findsOneWidget);

      await tester.tap(find.text('Headset microphone'));
      expect(chosen, 'mic-a');
    });

    testWidgets('the system default is always offered', (tester) async {
      // Without it there is no way back to the default after picking a device,
      // which is exactly the mistake a user needs to undo.
      String? chosen = 'unset';
      await tester.pumpWidget(host(Scaffold(
        body: MicrophonePicker(
          devices: const <MicrophoneOption>[
            MicrophoneOption(id: 'mic-a', label: 'Headset microphone'),
          ],
          selectedId: 'mic-a',
          onSelected: (String? id) => chosen = id,
        ),
      )));

      expect(find.byKey(const Key('microphone-system-default')), findsOneWidget);
      await tester.tap(find.byKey(const Key('microphone-system-default')));
      expect(chosen, isNull, reason: 'null means "let the system choose"');
    });

    testWidgets('a platform without a device list says so instead of showing one',
        (tester) async {
      // Android and iOS route the microphone themselves. An empty picker reads as
      // a bug; a sentence explains it.
      await tester.pumpWidget(host(Scaffold(
        body: MicrophonePicker(
          devices: const <MicrophoneOption>[],
          selectedId: null,
          onSelected: (_) {},
        ),
      )));

      expect(find.textContaining('chooses the microphone itself'), findsOneWidget);
      expect(find.byKey(const Key('microphone-system-default')), findsNothing);
    });

    testWidgets('the list can be re-read, for a device plugged in later',
        (tester) async {
      var refreshes = 0;
      await tester.pumpWidget(host(Scaffold(
        body: MicrophonePicker(
          devices: const <MicrophoneOption>[],
          selectedId: null,
          onSelected: (_) {},
          onRefresh: () => refreshes++,
        ),
      )));

      await tester.tap(find.text('Look again'));
      expect(refreshes, 1);
    });

    testWidgets('a device whose label is missing shows its identifier',
        (tester) async {
      // A blank row would be unselectable in practice: nothing to read, nothing to
      // aim at.
      await tester.pumpWidget(host(Scaffold(
        body: MicrophonePicker(
          devices: const <MicrophoneOption>[
            MicrophoneOption(id: '@device_raw_1', label: '@device_raw_1'),
          ],
          selectedId: null,
          onSelected: (_) {},
        ),
      )));
      expect(find.text('@device_raw_1'), findsOneWidget);
    });
  });

  group('the screen', () {
    testWidgets('reads the devices and shows them', (tester) async {
      await pumpScreen(tester, MicrophoneScreen(
        selectedId: 'mic-b',
        onSelected: (_) {},
        listDevices: () async => const <MicrophoneOption>[
          MicrophoneOption(id: 'mic-a', label: 'Headset microphone'),
          MicrophoneOption(id: 'mic-b', label: 'Built-in array'),
        ],
      ));

      expect(find.text('Headset microphone'), findsOneWidget);
      expect(find.text('Built-in array'), findsOneWidget);
    });

    testWidgets('picking one reports it and marks it', (tester) async {
      String? chosen;
      await pumpScreen(tester, MicrophoneScreen(
        selectedId: null,
        onSelected: (String? id) => chosen = id,
        listDevices: () async => const <MicrophoneOption>[
          MicrophoneOption(id: 'mic-a', label: 'Headset microphone'),
        ],
      ));

      await tester.tap(find.text('Headset microphone'));
      await tester.pump();
      expect(chosen, 'mic-a');
    });

    testWidgets('a platform failure is reported, not shown as an empty list',
        (tester) async {
      // "No microphones" and "the device list could not be read" are different
      // problems and only one is worth the user acting on.
      await pumpScreen(tester, MicrophoneScreen(
        selectedId: null,
        onSelected: (_) {},
        listDevices: () async => throw StateError('channel unavailable'),
      ));

      expect(find.textContaining('could not be read'), findsOneWidget);
      expect(find.textContaining('channel unavailable'), findsOneWidget);
    });
  });

  group('the choice is remembered', () {
    late Directory sandbox;
    late AppController controller;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('df-mic-');
      final paths = VaultPaths(sandbox);
      await paths.ensureCreated();
      controller = AppController(paths: paths);
      await controller.bootstrap();
      await controller.createAccount(
        displayName: 'Owner',
        about: '',
        password: 'a test passphrase',
      );
    });

    tearDown(() async {
      await controller.lock();
      controller.dispose();
      try {
        if (sandbox.existsSync()) await sandbox.delete(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    });

    test('it defaults to the system device', () {
      expect(controller.settings.microphoneId, isNull);
    });

    test('setting one survives a lock and unlock', () async {
      await controller.setMicrophone('mic-a');
      expect(controller.settings.microphoneId, 'mic-a');

      await controller.lock();
      await controller.unlockWithPassword('a test passphrase');
      expect(controller.settings.microphoneId, 'mic-a',
          reason: 'a device chosen once must still be chosen after a restart');
    });

    test('going back to the system default clears it', () async {
      await controller.setMicrophone('mic-a');
      await controller.setMicrophone(null);
      expect(controller.settings.microphoneId, isNull);

      await controller.lock();
      await controller.unlockWithPassword('a test passphrase');
      expect(controller.settings.microphoneId, isNull);
    });
  });
}
