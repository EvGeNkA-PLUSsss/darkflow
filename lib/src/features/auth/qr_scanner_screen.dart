import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/log_book.dart';
import '../../design/design.dart';

/// Reads a `.onion` address out of a QR code with the camera.
///
/// This is the other half of the QR flow: one person shows their address, the other
/// scans it. Typing a 56-character base32 address by hand is the step that makes a
/// serverless messenger unusable in practice, so this is the primary way to add a
/// contact on a phone.
///
/// ## What it accepts
///
/// Anything a peer might plausibly present, because the scanner does not control
/// what is printed on the other screen:
///
///  * the bare address — `abcdef…xyz.onion` — which is what DarkFlow itself draws;
///  * an `http://` or `https://` form, which a browser or a printed card may carry;
///  * an `onion:` scheme;
///  * any of those with a trailing slash or query, which a copy from a URL bar
///    routinely brings along.
///
/// Anything else is refused with the text that was actually read. A scanner that
/// silently ignores an unrecognised code leaves the user pointing the camera at it
/// for ever with no idea why nothing happens.
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({required this.onScanned, this.onBack, super.key});

  /// Called with the extracted address once a code is read and recognised.
  ///
  /// The screen pops itself first, so the caller does not have to.
  final ValueChanged<String> onScanned;

  final VoidCallback? onBack;

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen>
    with WidgetsBindingObserver {
  /// The camera controller, replaced rather than restarted when the camera breaks.
  ///
  /// Nullable, and rebuilt by [_rebuildCamera], because a restart is not always enough —
  /// see the comment there.
  MobileScannerController? _controller = _newController();

  static MobileScannerController _newController() => MobileScannerController(
        // Only what is needed: a QR code is what a peer shows, and asking the camera to
        // decode every format costs frames on a phone.
        formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
        detectionSpeed: DetectionSpeed.noDuplicates,
      );

  /// Set once a code has been accepted, so a second frame from the same code cannot
  /// pop the route twice.
  bool _handled = false;

  String? _complaint;

  /// True once the camera has been "starting" long enough to be worth mentioning.
  ///
  /// The plugin's placeholder is shown while the camera initialises, and on a phone that
  /// is a fraction of a second. On a machine where it never initialises it is for ever, so
  /// the placeholder has to change its mind: an indefinite spinner is the same as no
  /// information.
  bool _cameraWaited = false;

  /// When the camera has not come up by this point, the screen stops pretending it will.
  static const Duration _cameraPatience = Duration(seconds: 4);

  /// How long to wait before assuming the plugin has forgotten to restart the camera.
  ///
  /// Long enough that a normal resume has already restarted it, so the retry below is a
  /// no-op in the ordinary case rather than a second start racing the plugin's own.
  static const Duration _resumeGrace = Duration(milliseconds: 350);

  Timer? _cameraTimer;
  Timer? _resumeTimer;

  /// Records what the screen is doing, because nothing else can see it.
  ///
  /// A camera that fails produces no exception on the Dart side — the plugin keeps a state
  /// object, and whether the preview is black, a spinner or an error message is decided inside
  /// it. The only way to know what happened on a device is for the screen to say: that it opened,
  /// that the camera started, that a code was read whole, or that the camera never came up. The
  /// last one is the case that was reported twice with no usable detail.
  void _log(String message, {String? detail}) {
    logScanner(message, detail: detail);
  }

  @override
  void initState() {
    super.initState();
    // The plugin's own lifecycle handling does not cover a controller it does not own.
    // See `didChangeAppLifecycleState`.
    WidgetsBinding.instance.addObserver(this);
    _log('scanner opened');
    _cameraTimer = Timer(_cameraPatience, () {
      if (!mounted) return;
      setState(() => _cameraWaited = true);
      // The one line that answers "was the screen black because the camera never started".
      _log(
        'the camera did not start within ${_cameraPatience.inSeconds}s; '
        'the screen is showing the explanation instead of a black rectangle',
      );
    });
  }

  /// Restarts the camera after the application comes back, because the plugin will not.
  /// ## The black screen, and the line that causes it
  ///
  /// The plugin registers its own lifecycle observer **only when it owns the controller**:
  ///
  /// ```dart
  /// if (widget.controller == null) {
  ///   WidgetsBinding.instance.addObserver(this);
  /// }
  /// ```
  ///
  /// A controller is passed to `MobileScanner` here, so that observer is never added and the
  /// plugin's `didChangeAppLifecycleState` — the one that stops the camera on `inactive` and
  /// restarts it on `resumed` — is never called at all. That last part matters: the earlier
  /// analysis of this bug assumed the handler ran and returned early on a permission guard. It
  /// does not run. The camera is simply left running while the application is in the background,
  /// and Android destroys the surface it was drawing into.
  ///
  /// What the user sees is a camera that reports itself as running, a surface that no longer
  /// exists, no error and no placeholder: a black rectangle. This screen therefore has to do the
  /// whole job itself — stop the camera when the application goes away, and take a fresh session
  /// when it comes back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Releasing the camera on the way out is not tidiness. Holding it while the application is
    // invisible keeps the device open, and on Android that contends with whatever else wants the
    // camera — including this screen's own rebuild, which then fails because the old session was
    // never given up.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _resumeTimer?.cancel();
      _resumeTimer = null;
      if (_handled) return;
      final controller = _controller;
      if (controller == null) return;
      _log('application went to ${state.name}; releasing the camera');
      unawaited(_stopCamera(controller));
      return;
    }

    if (state != AppLifecycleState.resumed) return;
    // Nothing to restore once a code has been read and the route is on its way out.
    if (_handled) return;
    _log('application resumed; a fresh camera session will be built');
    _resumeTimer?.cancel();
    _resumeTimer = Timer(_resumeGrace, () {
      if (!mounted || _handled) return;
      unawaited(_rebuildCamera());
    });
  }

  /// Stops a camera, ignoring a refusal.
  ///
  /// A stop that fails is not worth reporting: the session is being abandoned either way, and
  /// the rebuild on resume creates a new one. Reporting it would put an error about a camera
  /// nobody is looking at on a screen the user is about to return to.
  Future<void> _stopCamera(MobileScannerController controller) async {
    try {
      await controller.stop();
    } on Object {
      // Nothing useful to do; the controller is discarded next.
    }
  }

  /// Replaces the camera controller after the application comes back.
  ///
  /// ## Why replacing rather than restarting
  ///
  /// The camera is stopped on the way out (see [didChangeAppLifecycleState]), so `start()` on the
  /// same controller would in principle work. It is not relied on, for two reasons.
  ///
  /// The first is that the plugin's own handling never runs here — it only registers its
  /// observer when it owns the controller, and a controller is passed in. So the state of the
  /// controller across a background trip is this screen's responsibility, and the only state
  /// known to be recoverable is a fresh one.
  ///
  /// The second is what `start()` does with a controller it believes is running:
  ///
  /// ```dart
  /// // Do nothing if the camera is already running.
  /// if (value.isRunning) return;
  /// ```
  ///
  /// A platform session that died without the controller noticing leaves exactly that state —
  /// "running", with no surface — and `start()` then does nothing about it. Nothing fails, so
  /// `errorBuilder` is not called; `isInitialized` is true, so the placeholder is not shown
  /// either. A fresh controller takes a fresh session, which is the only thing known to
  /// re-create the surface.
  Future<void> _rebuildCamera() async {
    final previous = _controller;
    // Cleared before the new one is made, so `build` cannot hand the plugin a controller that
    // is being disposed.
    if (mounted) {
      setState(() => _controller = null);
    }
    try {
      await previous?.dispose();
    } on Object {
      // A controller that has already been disposed is the common case here and is not a
      // problem; anything else is reported by the new controller's own error state.
    }
    if (!mounted || _handled) return;
    setState(() {
      _controller = _newController();
      // The camera is being brought up again, so the "it did not start" message must not
      // already be on screen from the first attempt.
      _cameraWaited = false;
    });
    _cameraTimer?.cancel();
    _cameraTimer = Timer(_cameraPatience, () {
      if (mounted) setState(() => _cameraWaited = true);
    });
  }

  @override
  void dispose() {
    _cameraTimer?.cancel();
    _resumeTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // The `MobileScanner` widget disposes the controller in its own `dispose`, and
    // `MobileScannerController.dispose` returns early when it has already run, so this pair
    // is safe in either order. It is kept because a route can be popped without the widget
    // ever having been built — a push that is immediately removed — and then nothing else
    // would release the camera.
    unawaited(_controller?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.trim().isEmpty) continue;

      final address = OnionAddressParser.extract(raw);
      if (address == null) {
        // Reported, not ignored: the user is pointing the camera at something, and
        // silence gives them nothing to correct.
        _log(
          'a code was read but is not a DarkFlow address',
          detail: 'length=${raw.length} · format=${barcode.format.name}',
        );
        if (_complaint != raw) {
          setState(() => _complaint = raw);
        }
        return;
      }

      _handled = true;
      _log('a DarkFlow address was read', detail: shortenOnion(address));
      // Popped before reporting, so the caller's context is the one that was on
      // screen when it opened the scanner.
      Navigator.of(context).pop();
      widget.onScanned(address);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: widget.onBack == null
            ? null
            : IconButton(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                tooltip: 'Back',
              ),
        title: Text('Scan a code', style: AppTypography.h2),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  // Underneath the preview, always.
                  //
                  // `CameraPreview` renders an empty `SizedBox` when the method channel has no
                  // texture, so a camera that is "initialized" and drawing nothing produced a black
                  // rectangle with no error and no placeholder. Nothing on the Dart side can detect
                  // that state reliably — `isRunning` is not set the way the first attempt at this
                  // assumed — but the *layout* can answer it without detecting anything: a working
                  // preview covers what is behind it, and a preview that draws nothing does not.
                  //
                  // So this is not a placeholder any more, it is a backdrop. It costs one widget and
                  // it removes the possibility of an unexplained black area rather than guessing at
                  // the conditions that produce one.
                  _CameraStarting(waited: _cameraWaited),
                  if (_controller != null)
                    MobileScanner(
                      controller: _controller,
                      onDetect: _onDetect,
                      // Both of these are needed, and omitting the placeholder is what made
                      // the screen black in the first place.
                      //
                      // The plugin draws a plain `ColoredBox(color: Colors.black)` while the
                      // camera is starting, and its `errorBuilder` is only consulted *after*
                      // that. On a device where the camera never initialises — no camera at
                      // all, a permission the platform never answers, a plugin that cannot
                      // find its implementation — the black box stays for ever and the error
                      // branch is never reached.
                      placeholderBuilder: (BuildContext context) =>
                          _CameraStarting(waited: _cameraWaited),
                    errorBuilder: (BuildContext context, MobileScannerException error) {
                      // The code and its message are the only description of why the camera is
                      // unusable, and they exist nowhere else once the screen is gone.
                      _log(
                        'the camera reported an error',
                        detail: '${error.errorCode.name} · '
                            '${error.errorDetails?.message ?? 'no detail'}',
                      );
                      return _CameraProblem(
                        error: error,
                        // A retry can help for every failure except one: a controller that has
                        // been disposed is this screen tearing itself down, and rebuilding into
                        // that would start a camera nothing is watching.
                        onRetry: error.errorCode == MobileScannerErrorCode.controllerDisposed
                            ? null
                            : () => unawaited(_rebuildCamera()),
                      );
                    },
                    ),
                  const _ScanFrame(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppMetrics.screenPadding,
                16,
                AppMetrics.screenPadding,
                20,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    'Point the camera at the other person\'s code. It appears in '
                    'their profile, under “Show my code”.',
                    textAlign: TextAlign.center,
                    style: AppTypography.secondary,
                  ),
                  if (_complaint != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      'That code is not a DarkFlow address. It read: '
                      '“${_short(_complaint!)}”',
                      textAlign: TextAlign.center,
                      style: AppTypography.caption.copyWith(color: AppColors.danger),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Truncates a decoded string for display, so an unexpected code cannot push the
  /// window around with a paragraph.
  static String _short(String value) =>
      value.length <= 80 ? value : '${value.substring(0, 77)}…';
}

/// The four corners that tell the user where to aim.
class _ScanFrame extends StatelessWidget {
  const _ScanFrame();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Container(
          width: 240,
          height: 240,
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.accent, width: 2),
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}

/// What to show while the camera is starting.
///
/// The plugin's own placeholder is a black rectangle with nothing in it, which is
/// indistinguishable from a broken screen. This says what is happening, and after a few
/// seconds stops claiming it is about to happen — because on a platform with no camera it
/// never will, and a spinner that runs for ever is worse than an explanation.
class _CameraStarting extends StatelessWidget {
  const _CameraStarting({required this.waited});

  final bool waited;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.background,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (!waited) ...<Widget>[
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(AppColors.accent),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Starting the camera…',
                  textAlign: TextAlign.center,
                  style: AppTypography.secondary,
                ),
              ] else ...<Widget>[
                const Icon(
                  Icons.videocam_off_outlined,
                  size: 40,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(height: 14),
                Text(
                  'The camera did not start. If this device has one, check that '
                  'DarkFlow is allowed to use it; otherwise add the contact by '
                  'typing their address.',
                  textAlign: TextAlign.center,
                  style: AppTypography.secondary,
                ),
                // The distinction the log alone cannot give a user: the camera never initialised
                // at all, rather than having failed with a reason. That is what separates "the
                // permission was never granted" from "the platform refused to open the device",
                // and it is the first thing worth knowing about a black preview.
                const SizedBox(height: 18),
                Text(
                  'The camera never reported that it started.',
                  textAlign: TextAlign.center,
                  style: AppTypography.caption,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// What to say when the camera cannot be used.
///
/// A refused permission is the common case and has a specific remedy, so it is
/// named rather than reported as a generic failure.
///
/// ## The retry button, and why a message alone is not enough
///
/// Telling the user to change a permission in the system settings is correct advice, and on its
/// own it leaves them with nothing to do on this screen: they either navigate away by hand — and
/// a first-time user does not know that the answer is one tap on "Back" — or they sit looking at
/// an error. Android also has the case where a permission was refused twice and the dialog will
/// not appear again, which means the screen has to offer the second half of the remedy itself.
///
/// [onRetry] rebuilds the camera, which is what re-asks for the permission: a fresh
/// `MobileScannerController` triggers a fresh `start()`, and that is where the platform
/// permission check lives.
class _CameraProblem extends StatelessWidget {
  const _CameraProblem({required this.error, this.onRetry});

  final MobileScannerException error;

  /// Offered when the camera is worth trying again. Null in tests and in the one case where a
  /// retry cannot help.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final refused = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return ColoredBox(
      color: AppColors.background,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                refused ? Icons.no_photography_outlined : Icons.videocam_off_outlined,
                size: 40,
                color: AppColors.textSecondary,
              ),
              const SizedBox(height: 14),
              Text(
                refused
                    ? 'DarkFlow is not allowed to use the camera. Turn the camera '
                        'permission on for DarkFlow in the system settings, then come '
                        'back to this screen.'
                    : 'The camera could not be started. You can still add a contact '
                        'by typing the address.',
                textAlign: TextAlign.center,
                style: AppTypography.secondary,
              ),
              if (onRetry != null) ...<Widget>[
                const SizedBox(height: 20),
                SecondaryButton(label: 'Try the camera again', onPressed: onRetry),
              ],
              // The reason, on screen, in the words only the platform can produce.
              //
              // The log has carried this for a while, and reading it requires exporting a file from
              // a phone. The person who hit the problem is looking at this screen, so the one detail
              // that identifies the cause is put where they already are — and it is small and
              // secondary, because a user with a working camera must never see it.
              const SizedBox(height: 18),
              Text(
                'Reason: ${error.errorCode.name}'
                '${error.errorDetails?.message == null ? '' : ' — ${error.errorDetails!.message}'}',
                textAlign: TextAlign.center,
                style: AppTypography.caption,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Turns whatever a QR code contains into a bare `.onion` address.
///
/// Separated from the screen because it is the part with rules, and the part that
/// can be tested without a camera: every accepted and refused form is a case in
/// `qr_scanner_test.dart`.
abstract final class OnionAddressParser {
  /// The length of a Tor v3 address without its suffix: 56 base32 characters.
  static const int v3Length = 56;

  /// The length of the older v2 address, kept because a contact may still present
  /// one and refusing it with a clear reason beats refusing it silently.
  static const int v2Length = 16;

  /// Extracts the address from [raw], or null when there is not one.
  static String? extract(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return null;

    // A copied URL routinely brings a query or fragment along, and neither is part
    // of the address.
    final cut = value.indexOf(RegExp(r'[?#]'));
    if (cut >= 0) value = value.substring(0, cut);

    // Strip a scheme, whichever one was used. Done before the path so that
    // `https://x.onion/` and `x.onion` end up in the same place.
    final scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');
    value = value.replaceFirst(scheme, '');
    value = value.replaceFirst(RegExp(r'^onion:', caseSensitive: false), '');
    // Any leading `//` left by a scheme-relative link.
    value = value.replaceFirst(RegExp(r'^/+'), '');

    // Drop a path, port or user-info: the address is the host.
    value = value.split('/').first;
    value = value.split('@').last;
    final colon = value.indexOf(':');
    if (colon >= 0) value = value.substring(0, colon);

    final lower = value.toLowerCase();
    if (!lower.endsWith('.onion')) return null;

    final host = lower.substring(0, lower.length - '.onion'.length);
    if (host.length != v3Length && host.length != v2Length) return null;
    // Base32 alphabet: a–z and 2–7. Anything else is not an onion address, and
    // accepting it would store a contact that can never be reached.
    if (!RegExp(r'^[a-z2-7]+$').hasMatch(host)) return null;

    return '$host.onion';
  }
}
