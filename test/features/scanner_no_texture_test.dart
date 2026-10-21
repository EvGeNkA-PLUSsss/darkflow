import 'package:darkflow/src/features/auth/qr_scanner_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// What a controller reports when the platform never gives it a texture.
///
/// This is the one shape of failure the screen cannot otherwise see. `CameraPreview` renders an
/// empty `SizedBox` when the method channel has no texture id, so the plugin's own placeholder is
/// not shown — `isInitialized` is true — and no exception is raised. The result is a black rectangle
/// with nothing on it, which is what was reported from a phone while the desktop build was fine.
///
/// These tests pin what a caller *can* observe in that state, so the screen has something to branch
/// on rather than guessing.
void main() {
  testWidgets('a controller whose start never reports a texture has no size',
      (tester) async {
    const channel = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'state') return 2; // authorized
      if (call.method == 'request') return true;
      if (call.method == 'start') {
        // The shape the plugin expects, with no usable size — which is what a missing texture
        // looks like from Dart.
        return <String, dynamic>{
          'numberOfCameras': 1,
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

    final controller = MobileScannerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MobileScanner(controller: controller, onDetect: (BarcodeCapture _) {}),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    // The point of the test: whatever the plugin says about being initialized, a preview with no
    // size cannot be showing anything.
    final value = controller.value;

    // A texture-less preview renders an empty box, so the screen must not treat "initialized" as
    // "visible". Either the size is empty, or the plugin reported an error — one of the two has to
    // hold, or the screen would have nothing to branch on.
    final emptySize = value.size.width <= 0 || value.size.height <= 0;
    final failed = value.error != null;
    expect(emptySize || failed, isTrue,
        reason: 'a controller with no texture must be distinguishable from a working one, or the '
            'screen shows a black rectangle with nothing to say');
  });

  testWidgets('the screen never leaves an unexplained black rectangle', (tester) async {
    // What the screen does with the state above: with no size and no preview, it draws its own
    // explanation instead of asking the plugin for a picture it cannot produce. Before this the
    // preview area was asked for a texture that did not exist, and `CameraPreview` answered with an
    // empty box — the black rectangle, with no error and nothing written on it.
    const channel = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'state') return 2;
      if (call.method == 'request') return true;
      if (call.method == 'start') {
        return <String, dynamic>{
          'numberOfCameras': 1,
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

    await tester.pumpWidget(MaterialApp(home: QrScannerScreen(onScanned: (_) {})));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));

    // Something has to be written on the screen: a reason, or the statement that the camera never
    // reported that it started. A bare rectangle is the failure this whole line of work is about.
    final explained = find.textContaining('Reason:').evaluate().isNotEmpty ||
        find.textContaining('never reported that it started').evaluate().isNotEmpty ||
        find.textContaining('could not be started').evaluate().isNotEmpty ||
        find.textContaining('not allowed to use the camera').evaluate().isNotEmpty ||
        find.textContaining('Starting the camera').evaluate().isNotEmpty;
    expect(explained, isTrue,
        reason: 'the preview area must always say something, or a user cannot tell a broken '
            'camera from a slow one');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the explanation is drawn under the preview, not instead of it', (tester) async {
    // The invariant, rather than one branch of it.
    //
    // `CameraPreview` renders an empty `SizedBox` when the method channel has no texture, so a
    // preview can draw *nothing* without failing. Nothing on the Dart side detects that state
    // reliably — the first attempt used `isRunning`, which is not set the way that guard assumed,
    // and it would have replaced the ordinary spinner with an error on every launch.
    //
    // The layout answers it without detecting anything: the explanation is a sibling *before* the
    // preview in the stack, so the preview is painted over it. A working preview covers it, and a
    // preview that draws nothing lets it show. This checks that order, which is the property that
    // makes the outcome certain.
    await tester.pumpWidget(MaterialApp(home: QrScannerScreen(onScanned: (_) {})));
    await tester.pump();

    // The stack that holds the camera area: the one containing the scan frame, which is always
    // present and is not a scanner.
    final stackFinder = find.ancestor(
      of: find.textContaining('Starting the camera'),
      matching: find.byType(Stack),
    );
    expect(stackFinder, findsWidgets,
        reason: 'the explanation has to be on screen at all');

    final stack = tester.widget<Stack>(stackFinder.first);
    final previewAt = stack.children.indexWhere(
      (Widget child) => child.runtimeType.toString().contains('MobileScanner'),
    );
    final explanationAt = stack.children.indexWhere(
      (Widget child) => child.runtimeType.toString().contains('CameraStarting'),
    );

    expect(explanationAt, greaterThanOrEqualTo(0),
        reason: 'the explanation is a direct child of the camera stack');
    if (previewAt >= 0 && explanationAt >= 0) {
      expect(explanationAt, lessThan(previewAt),
          reason: 'the explanation must be drawn before the preview, so a preview that draws '
              'nothing cannot hide it — that ordering is the whole fix');
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
}
