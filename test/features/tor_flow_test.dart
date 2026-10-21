import 'package:darkflow/src/data/models/tor_settings.dart';
import 'package:darkflow/src/design/design.dart';
import 'package:darkflow/src/features/tor/tor_bridge_settings_screen.dart';
import 'package:darkflow/src/features/tor/tor_connection_screen.dart';
import 'package:darkflow/src/features/tor/widgets/bootstrap_step_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Both of these screens shipped a control that looked live but did nothing —
/// a "Next" that applied the choice without leaving, and a primary action that
/// was disabled in the one state where the user most needed it. These tests
/// exist so that cannot come back unnoticed.
void main() {
  Widget host(Widget child) => MaterialApp(
        theme: AppTheme.build(),
        home: child,
      );

  group('bridge settings', () {
    const presets = <BridgePreset>[
      BridgePreset(
        id: 'obfs4',
        label: 'obfs4',
        mode: BridgeMode.obfs4,
        description: 'Looks like nothing in particular.',
        bridges: <String>[],
      ),
      BridgePreset(
        id: 'webtunnel',
        label: 'WebTunnel',
        mode: BridgeMode.webTunnel,
        description: 'Looks like ordinary HTTPS.',
        bridges: <String>[],
      ),
    ];

    testWidgets('the presets are rendered', (tester) async {
      await tester.pumpWidget(host(const TorBridgeSettingsScreen(
        presets: presets,
        selectedMode: BridgeMode.automatic,
        initialBridges: '',
        onApply: _ignoreApply,
      )));

      expect(find.text('Tor Bridge Settings'), findsOneWidget);
      expect(find.text('Presets'), findsOneWidget);
      expect(find.text('obfs4'), findsOneWidget);
      expect(find.text('WebTunnel'), findsOneWidget);
      expect(find.text('Manual Configuration'), findsOneWidget);
    });

    testWidgets('picking a preset then Next commits it and leaves', (tester) async {
      BridgeMode? appliedMode;
      var left = 0;

      await tester.pumpWidget(host(TorBridgeSettingsScreen(
        presets: presets,
        selectedMode: BridgeMode.automatic,
        initialBridges: '',
        onApply: (mode, bridges) {
          appliedMode = mode;
        },
        onBack: () => left++,
      )));

      await tester.tap(find.text('WebTunnel'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      // The bug was that only the first of these happened.
      expect(appliedMode, BridgeMode.webTunnel, reason: 'the choice must be applied');
      expect(left, 1, reason: 'Next must also close the screen');
    });

    testWidgets('Next leaves even with no onApply side effect visible', (tester) async {
      var left = 0;
      await tester.pumpWidget(host(TorBridgeSettingsScreen(
        presets: presets,
        selectedMode: BridgeMode.obfs4,
        initialBridges: 'Bridge obfs4 192.0.2.10:443 47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 cert=abcdEFGH12345678 iat-mode=0',
        onApply: _ignoreApply,
        onBack: () => left++,
      )));

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(left, 1);
    });

    testWidgets('choosing a preset does not erase pasted bridge lines',
        (tester) async {
      // The order people actually work in: paste the addresses, then pick the
      // transport they belong to. Every shipped preset carries no addresses, and
      // tapping one used to blank the box — so the paste vanished, torrc got no
      // `Bridge` lines at all, and the app silently connected directly.
      const pasted = 'webtunnel https://example.com/abc 47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 url=https://example.com/abc';
      BridgeMode? appliedMode;
      var appliedBridges = '';

      await tester.pumpWidget(host(TorBridgeSettingsScreen(
        presets: presets,
        selectedMode: BridgeMode.automatic,
        initialBridges: pasted,
        onApply: (mode, bridges) {
          appliedMode = mode;
          appliedBridges = bridges;
        },
      )));

      await tester.tap(find.text('WebTunnel'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(appliedMode, BridgeMode.webTunnel, reason: 'the transport must switch');
      expect(
        appliedBridges,
        pasted,
        reason: 'the pasted addresses must survive choosing a transport',
      );
    });

    testWidgets('a malformed bridge line cannot be committed', (tester) async {
      // A bad line does not degrade the connection, it stops Tor from starting at all —
      // `tor.exe` exits 1 with "Reading config failed--see warnings above", and the only way
      // out is to find and remove the line. Since the app cannot show Tor's warnings next to
      // the field, it must not write a configuration that is certain to fail.
      var applied = 0;
      var left = 0;
      await tester.pumpWidget(host(TorBridgeSettingsScreen(
        presets: presets,
        selectedMode: BridgeMode.webTunnel,
        // Four characters where Tor requires forty.
        initialBridges: 'webtunnel https://example.com/abc AAAA',
        onApply: (BridgeMode _, String _) => applied++,
        onBack: () => left++,
      )));

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(applied, 0, reason: 'a configuration that stops Tor must not be saved');
      expect(left, 0, reason: 'and the screen stays so the line can be corrected');
      expect(find.textContaining('40'), findsOneWidget,
          reason: 'the reason has to be on screen, not only in a log');
    });

    testWidgets('a corrected line can then be committed', (tester) async {
      // The other half: the guard must not trap the user on the screen.
      var applied = 0;
      var left = 0;
      await tester.pumpWidget(host(TorBridgeSettingsScreen(
        presets: presets,
        selectedMode: BridgeMode.webTunnel,
        initialBridges: 'webtunnel https://example.com/abc AAAA',
        onApply: (BridgeMode _, String _) => applied++,
        onBack: () => left++,
      )));

      await tester.enterText(
        find.byType(TextField).first,
        'webtunnel https://example.com/abc '
        '47B2E1F5C3D8A96B0E4F1C2D3A5B6C7D8E9F0A12 url=https://example.com/abc',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(applied, 1);
      expect(left, 1);
    });

    testWidgets('the back arrow is hidden when the caller says so', (tester) async {
      await tester.pumpWidget(host(TorBridgeSettingsScreen(
        presets: presets,
        selectedMode: BridgeMode.automatic,
        initialBridges: '',
        showBackAffordance: false,
        onApply: _ignoreApply,
        onBack: () {},
      )));

      // Only "Next" is present; there is no second navigation control.
      expect(find.byIcon(Icons.arrow_back_ios_new), findsNothing);
      expect(find.text('Next'), findsOneWidget);
    });
  });

  group('connection screen', () {
    const steps = <BootstrapStep>[
      BootstrapStep(label: 'Initializing connection…'),
      BootstrapStep(label: 'Connecting to bridge…'),
      BootstrapStep(label: 'Establishing secure circuit…'),
      BootstrapStep(label: 'Connection established!'),
    ];

    testWidgets('nothing attempted yet invites a Connect', (tester) async {
      var connected = 0;
      await tester.pumpWidget(host(TorConnectionScreen(
        progress: 0,
        steps: steps,
        onConnect: () => connected++,
      )));

      expect(find.text('Connect to Tor Network'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);

      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(connected, 1);
    });

    testWidgets('in flight shows a disabled Next, as the mockup does', (tester) async {
      await tester.pumpWidget(host(const TorConnectionScreen(
        progress: 0.1,
        steps: steps,
      )));

      expect(find.text('Connecting to Tor Network'), findsOneWidget);
      expect(find.text('Next'), findsOneWidget);
      // No Connect button once an attempt is under way.
      expect(find.text('Connect'), findsNothing);
    });

    testWidgets('a failure offers Retry rather than a dead end', (tester) async {
      var retried = 0;
      await tester.pumpWidget(host(TorConnectionScreen(
        progress: 0,
        steps: steps,
        errorText: 'another Tor process is running with the same data directory',
        onRetry: () => retried++,
      )));

      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(retried, 1);
    });

    testWidgets('a warning while Tor is still working does not offer Retry',
        (tester) async {
      // Tor warns about relays it simply routes around — "Failed to find node
      // for hop #1" is a WARN and the bootstrap carries on. Treating those as
      // failure put a Retry button on a perfectly healthy 10% bootstrap.
      await tester.pumpWidget(host(const TorConnectionScreen(
        progress: 0.1,
        steps: steps,
        warningText: 'Failed to find node for hop #1 of our path',
      )));

      expect(find.text('Retry'), findsNothing);
      expect(find.textContaining('Failed to find node'), findsOneWidget);
      // It is still presented as an attempt in progress.
      expect(find.text('Next'), findsOneWidget);
    });

    testWidgets('there is no way to skip Tor setup', (tester) async {
      // The skip button was removed on request. It is one shared gate, so this
      // covers the phone and the desktop at once.
      await tester.pumpWidget(host(TorConnectionScreen(
        progress: 0,
        steps: steps,
        errorText: 'Tor exited with code 1.',
        onRetry: () {},
      )));

      expect(find.text('Retry'), findsOneWidget);
      expect(find.textContaining('without connecting'), findsNothing);
      expect(find.textContaining('Skip'), findsNothing);
    });

    testWidgets('a running daemon can be interrupted', (tester) async {
      var stopped = 0;
      await tester.pumpWidget(host(TorConnectionScreen(
        progress: 0.1,
        steps: steps,
        onDisconnect: () => stopped++,
      )));

      expect(find.text('Disconnect Tor'), findsOneWidget);
      await tester.tap(find.text('Disconnect Tor'));
      await tester.pumpAndSettle();
      expect(stopped, 1);
    });

    testWidgets('nothing to stop means no Disconnect button', (tester) async {
      // Before Tor is started there is nothing to interrupt, so the control is
      // absent rather than inert.
      await tester.pumpWidget(host(TorConnectionScreen(
        progress: 0,
        steps: steps,
        onConnect: () {},
      )));

      expect(find.text('Disconnect Tor'), findsNothing);
      expect(find.text('Connect'), findsOneWidget);
    });

    testWidgets('once connected the primary becomes Continue', (tester) async {
      var continued = 0;
      await tester.pumpWidget(host(TorConnectionScreen(
        progress: 1,
        steps: steps,
        connected: true,
        onNext: () => continued++,
      )));

      expect(find.text('Connected to Tor Network'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(continued, 1);
    });

    testWidgets('the diagnostic line appears only when there is something to say',
        (tester) async {
      await tester.pumpWidget(host(const TorConnectionScreen(
        progress: 0,
        steps: steps,
      )));
      expect(find.textContaining('Backend:'), findsNothing);

      await tester.pumpWidget(host(const TorConnectionScreen(
        progress: 0,
        steps: steps,
        backendName: 'cryptography 2.9.0 · pure Dart',
        socksPort: 9050,
      )));
      expect(find.textContaining('SOCKS: 127.0.0.1:9050'), findsOneWidget);
    });
  });
}

void _ignoreApply(BridgeMode mode, String bridges) {}
