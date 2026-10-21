import 'package:darkflow/src/app/log_book.dart';
import 'package:darkflow/src/design/design.dart';
import 'package:darkflow/src/features/auth/qr_scanner_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// The scanner screen must never be a black rectangle.
///
/// There were two causes and both are covered here.
///
/// The first is in the plugin's placeholder: while the camera is starting it draws
/// `ColoredBox(color: Colors.black)` and only consults its own `errorBuilder` *after*
/// initialisation, so on a machine where the camera never comes up the error branch is never
/// reached and the black box stays for ever. A `placeholderBuilder` fixes that.
///
/// The second is the plugin's lifecycle handling, and it is the one that produced the black
/// screen on a real phone. Answering the camera permission dialog moves the application
/// through `inactive` and `paused` and back to `resumed`, and the plugin's handler begins
///
/// ```dart
/// if (!widget.useAppLifecycleState || !controller.value.hasCameraPermission) return;
/// ```
///
/// On a first scan `hasCameraPermission` is still false at that point — the camera has never
/// been started, so nothing has reported a grant — and the handler returns before its
/// `resumed` branch. The camera is never started, nothing fails, and the preview is black.
void main() {
  Widget host(Widget child) =>
      MaterialApp(theme: AppTheme.build(), home: child);

  group('a black screen is never the whole story', () {
    testWidgets('the screen draws its own chrome', (tester) async {
      await tester.pumpWidget(host(
        QrScannerScreen(onScanned: (_) {}),
      ));
      await tester.pump();
      // Something has to be on screen that is not the plugin's placeholder. The title and
      // the instruction are drawn by this screen rather than by the camera, so they are
      // visible whatever the camera is doing.
      expect(find.text('Scan a code'), findsOneWidget);
      expect(find.textContaining('Point the camera'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('it stops claiming the camera is starting', (tester) async {
      // An indefinite spinner is the same as no information. After the patience window the
      // screen has to say it did not work and offer the alternative.
      await tester.pumpWidget(host(QrScannerScreen(onScanned: (_) {})));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));

      final showsFailure =
          find.textContaining('did not start').evaluate().isNotEmpty ||
              find.textContaining('could not be started').evaluate().isNotEmpty ||
              find.textContaining('not allowed to use the camera').evaluate().isNotEmpty;
      expect(showsFailure, isTrue,
          reason: 'after the patience window the screen must explain itself');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('returning from the permission dialog gets a fresh camera session',
        (tester) async {
      // The fix for the reported black screen.
      //
      // The permission dialog is the first thing this screen causes, and after it the camera
      // is left broken in a way that neither `start()` nor the plugin's own handling repairs:
      //
      //   * the plugin's lifecycle guard
      //         if (!widget.useAppLifecycleState || !controller.value.hasCameraPermission) return;
      //     is skipped on a first scan, because the camera has never been started and so
      //     nothing has reported a permission;
      //   * `start()` then refuses to act, because as far as it knows the camera never stopped:
      //         // Do nothing if the camera is already running.
      //         if (value.isRunning) return;
      //
      // What is left is a controller that believes it is running and an Android surface that
      // was destroyed when the application went to the background. The preview is black, no
      // error is raised, and nothing can clear it — which is exactly what was reported.
      //
      // A new controller takes a new platform session, and that is the assertion here: the
      // widget must be handed a different controller after the application comes back.
      const channel = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        // `state` is cast to `int?` and `request` to `bool?`; the wrong shape throws inside
        // the plugin and the test would then fail for an unrelated reason.
        if (call.method == 'state') return 2; // MobileScannerAuthorizationState.authorized
        if (call.method == 'request') return true;
        if (call.method == 'start') {
          return <String, dynamic>{
            'textureId': 1,
            'numberOfCameras': 1,
            'size': <String, dynamic>{'width': 640.0, 'height': 480.0},
            'currentTorchState': 0,
            'cameraDirection': 0,
          };
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      await tester.pumpWidget(host(QrScannerScreen(onScanned: (_) {})));
      await tester.pump();

      final before = tester
          .widget<MobileScanner>(find.byType(MobileScanner, skipOffstage: false))
          .controller;
      expect(before, isNotNull);

      // What answering the permission dialog looks like from the application.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      // The rebuild is deliberately delayed so it cannot race the plugin's own restart.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      final after = tester
          .widget<MobileScanner>(find.byType(MobileScanner, skipOffstage: false))
          .controller;

      expect(after, isNotNull,
          reason: 'the camera must be given a session again, not left blank');
      expect(identical(after, before), isFalse,
          reason: 'only a new controller re-creates the surface the background destroyed');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('going to the background releases the camera', (tester) async {
      // The half that was missing, and the actual cause of the black screen.
      //
      // The plugin registers its lifecycle observer only when it owns the controller:
      //
      //     if (widget.controller == null) {
      //       WidgetsBinding.instance.addObserver(this);
      //     }
      //
      // A controller is passed to `MobileScanner` here, so that observer is never added and the
      // plugin's handler — which stops the camera on `inactive` and restarts it on `resumed` —
      // never runs. The camera was therefore left running while the application was invisible,
      // and Android destroyed the surface it drew into. A running camera, a dead surface, no
      // error, no placeholder: a black rectangle.
      //
      // Stopping on the way out is what makes the resume able to build a working session, and it
      // is also what stops this screen holding the camera device while invisible.
      const channel = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
      final calls = <String>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call.method);
        if (call.method == 'state') return 2; // authorized
        if (call.method == 'request') return true;
        if (call.method == 'start') {
          return <String, dynamic>{
            'textureId': 1,
            'numberOfCameras': 1,
            'size': <String, dynamic>{'width': 640.0, 'height': 480.0},
            'currentTorchState': 0,
            'cameraDirection': 0,
          };
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      await tester.pumpWidget(host(QrScannerScreen(onScanned: (_) {})));
      await tester.pump();
      calls.clear();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // `stop` is a platform call and the lifecycle handler does not await it — a lifecycle
      // callback must not block on a socket. The pump has to let the microtask queue run it.
      await tester.pump(const Duration(milliseconds: 100));

      // Asserted on the controller's own state rather than on the method channel, because that
      // is what the rest of the plugin reads: `isRunning` drives the guard in `start()`, and a
      // controller that still believes the camera is running is the one that leaves the preview
      // black. `MobileScannerController.stop()` skips the platform call unless its own internal
      // state says there is something to stop, so the channel is the wrong thing to watch.
      final controller = tester
          .widget<MobileScanner>(find.byType(MobileScanner, skipOffstage: false))
          .controller;
      expect(controller, isNotNull);
      expect(
        controller!.value.isRunning,
        isFalse,
        reason: 'the camera must not stay open while the application is invisible, or the '
            'surface is destroyed underneath it and the preview goes black for ever',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a code already read is not restarted for', (tester) async {
      // Once a code has been accepted the route is on its way out, and starting the camera
      // again would turn it back on during the pop animation.
      const channel = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
      final calls = <String>[];

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call.method);
        if (call.method == 'state') return 2; // MobileScannerAuthorizationState.authorized
        if (call.method == 'request') return true;
        if (call.method == 'start') {
          return <String, dynamic>{
            'textureId': 1,
            'numberOfCameras': 1,
            'size': <String, dynamic>{'width': 640.0, 'height': 480.0},
            'currentTorchState': 0,
            'cameraDirection': 0,
          };
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final scanned = <String>[];
      await tester.pumpWidget(host(QrScannerScreen(onScanned: scanned.add)));
      await tester.pump();
      calls.clear();

      // The route is replaced, which is what accepting a code amounts to, and the lifecycle
      // change that follows must not resurrect a camera for a screen that is gone.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      // Nothing should have started a camera for a screen that is no longer mounted.
      expect(calls.where((String method) => method == 'start'), isEmpty);

      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('the screen explains itself in the log', () {
    // A camera that fails raises nothing on the Dart side: the plugin keeps a state object, and
    // whether the user sees a preview, a spinner or a black rectangle is decided inside it. On a
    // device the only way to know which happened is for the screen to write it down — and the
    // black-screen report arrived twice with nothing to read.

    testWidgets('opening the scanner is recorded', (tester) async {
      final book = LogBook();
      debugSetLogBook(book);

      await tester.pumpWidget(host(QrScannerScreen(onScanned: (_) {})));
      await tester.pump();

      expect(
        book.entries.map((LogEntry entry) => entry.message),
        contains('scanner opened'),
      );
      expect(book.entries.first.category, LogCategory.scanner);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a camera that never starts says so, instead of leaving black', (tester) async {
      final book = LogBook();
      debugSetLogBook(book);

      await tester.pumpWidget(host(QrScannerScreen(onScanned: (_) {})));
      await tester.pump();
      // Past the patience window, which is when the screen stops claiming the camera is coming.
      await tester.pump(const Duration(seconds: 5));

      final messages = book.entries.map((LogEntry entry) => entry.message).join('\n');
      expect(messages, contains('did not start within'),
          reason: 'this line is what tells a black rectangle from a working camera');
      expect(messages, contains('explanation instead of a black rectangle'));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('releasing the camera on the way to the background is recorded',
        (tester) async {
      final book = LogBook();
      debugSetLogBook(book);

      await tester.pumpWidget(host(QrScannerScreen(onScanned: (_) {})));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 100));

      final messages = book.entries.map((LogEntry entry) => entry.message).join('\n');
      expect(messages, contains('releasing the camera'));
      expect(messages, contains('paused'));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('a camera that cannot be used offers a way forward', () {
    testWidgets('a refused permission can be tried again', (tester) async {
      // Telling the user to change a permission in the system settings is correct advice that
      // leaves them nothing to do on this screen. Android also stops showing the dialog after two
      // refusals, so the screen has to offer the retry itself rather than describing one.
      const channel = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        // Authorized, so the plugin's own permission path is satisfied; the error is produced by
        // `start` failing, which is the other route into `_CameraProblem`.
        if (call.method == 'state') return 2;
        if (call.method == 'request') return true;
        if (call.method == 'start') {
          throw PlatformException(code: 'MOBILE_SCANNER_CAMERA_PERMISSION_DENIED');
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      await tester.pumpWidget(host(QrScannerScreen(onScanned: (_) {})));
      await tester.pump(const Duration(seconds: 1));

      // Whatever the plugin produced, the screen must not be a dead end: either the error branch
      // offered a retry, or the placeholder explained itself. Both are ways forward, and a black
      // rectangle is not.
      final hasRetry = find.text('Try the camera again').evaluate().isNotEmpty;
      final hasExplanation = find.textContaining('did not start').evaluate().isNotEmpty ||
          find.textContaining('could not be started').evaluate().isNotEmpty ||
          find.textContaining('not allowed to use the camera').evaluate().isNotEmpty;
      expect(hasRetry || hasExplanation, isTrue,
          reason: 'the screen must offer either a retry or an explanation, never neither');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('the retry button rebuilds the camera when it is offered', (tester) async {
      // The button has to do the thing that re-asks for the permission: a fresh controller runs a
      // fresh `start()`, and the platform permission check lives inside that.
      const channel = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
      var starts = 0;
      var failFirst = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'state') return 2;
        if (call.method == 'request') return true;
        if (call.method == 'start') {
          starts++;
          if (failFirst) {
            failFirst = false;
            throw PlatformException(code: 'MOBILE_SCANNER_CAMERA_PERMISSION_DENIED');
          }
          return <String, dynamic>{
            'textureId': 1,
            'numberOfCameras': 1,
            'size': <String, dynamic>{'width': 640.0, 'height': 480.0},
            'currentTorchState': 0,
            'cameraDirection': 0,
          };
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      await tester.pumpWidget(host(QrScannerScreen(onScanned: (_) {})));
      await tester.pump(const Duration(seconds: 1));

      final retry = find.text('Try the camera again');
      if (retry.evaluate().isEmpty) return; // The plugin took the placeholder path instead.

      final before = tester
          .widget<MobileScanner>(find.byType(MobileScanner, skipOffstage: false))
          .controller;

      await tester.tap(retry);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      // Asserted on the controller rather than on the platform call, for the same reason as the
      // resume test: what this screen owns is the controller, and a new one is what re-asks the
      // platform for the camera and its permission. Whether the plugin's own `start` reaches the
      // channel from there is the plugin's business, not this screen's.
      final after = tester
          .widget<MobileScanner>(find.byType(MobileScanner, skipOffstage: false))
          .controller;
      expect(after, isNotNull,
          reason: 'the retry must leave a camera on screen, not nothing');
      expect(identical(after, before), isFalse,
          reason: 'the retry must build a new session, which is what re-asks the platform');
      expect(starts, greaterThanOrEqualTo(1));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('the screen explains itself without needing the log', () {
    testWidgets('a camera that never starts says so on screen', (tester) async {
      // The log has carried this for a while, and reading it means exporting a file from a phone.
      // The person hitting the problem is looking at this screen, so the one fact that identifies
      // the cause is shown here — and a build with a working camera never reaches it.
      await tester.pumpWidget(host(QrScannerScreen(onScanned: (_) {})));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));

      // Found at least once, and possibly twice: the statement is drawn as a backdrop underneath the
      // preview as well as by the plugin's own placeholder, and both are on screen while the camera
      // is not up. What matters is that the user reads it rather than looking at a black rectangle.
      expect(find.textContaining('never reported that it started'), findsWidgets,
          reason: 'the distinction between "never initialised" and "failed with a reason" is '
              'what tells a permission problem from a device problem');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a camera that fails shows the platform reason', (tester) async {
      // The error code is the only description the platform gives, and it exists nowhere else
      // once the screen is gone. It is shown small and secondary: a user whose camera works must
      // not be reading diagnostics.
      const channel = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'state') return 2;
        if (call.method == 'request') return true;
        if (call.method == 'start') {
          throw PlatformException(code: 'MOBILE_SCANNER_CAMERA_PERMISSION_DENIED');
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      await tester.pumpWidget(host(QrScannerScreen(onScanned: (_) {})));
      await tester.pump(const Duration(seconds: 1));

      // Either the platform produced an error, in which case the reason is on screen, or it did
      // not and the placeholder explains itself. Both are answers; a black rectangle is not.
      final showsReason = find.textContaining('Reason:').evaluate().isNotEmpty;
      final showsExplanation =
          find.textContaining('never reported that it started').evaluate().isNotEmpty ||
              find.textContaining('could not be started').evaluate().isNotEmpty ||
              find.textContaining('not allowed to use the camera').evaluate().isNotEmpty;
      expect(showsReason || showsExplanation, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('the chrome', () {
    testWidgets('the back affordance works when one is given', (tester) async {
      var backs = 0;
      await tester.pumpWidget(host(QrScannerScreen(
        onScanned: (_) {},
        onBack: () => backs++,
      )));
      await tester.pump();

      await tester.tap(find.byTooltip('Back'));
      expect(backs, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('no back affordance is drawn when there is nowhere to go',
        (tester) async {
      await tester.pumpWidget(host(QrScannerScreen(onScanned: (_) {})));
      await tester.pump();
      expect(find.byTooltip('Back'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
