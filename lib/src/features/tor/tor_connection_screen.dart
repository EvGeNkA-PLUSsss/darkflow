import 'package:flutter/material.dart';

import '../../design/design.dart';
import 'widgets/bootstrap_step_list.dart';

/// The screen shown while DarkFlow brings Tor up.
///
/// It is driven entirely by the caller: [progress] and [steps] are handed in, so
/// the same widget renders "45%, connected to the bridge" and a finished 100%
/// bootstrap without knowing anything about the daemon. The four canonical
/// labels, matching the design, are `'Initializing connection…'`,
/// `'Connecting to bridge…'`, `'Establishing secure circuit…'` and
/// `'Connection established!'`.
class TorConnectionScreen extends StatelessWidget {
  const TorConnectionScreen({
    required this.progress,
    required this.steps,
    this.connected = false,
    this.subtitle,
    this.errorText,
    this.backendName,
    this.socksPort,
    this.bridgeSummary,
    this.onOpenBridgeSettings,
    this.onNext,
    this.onRetry,
    this.onConnect,
    this.onDisconnect,
    this.warningText,
    this.onBack,
    super.key,
  });

  /// Bootstrap completion, 0..1. Drives both the bar and the percentage.
  final double progress;

  /// The transcript, top to bottom.
  final List<BootstrapStep> steps;

  /// True once the first circuit is up. Only then is the primary button live.
  final bool connected;

  /// Overrides the default subtitle when the caller has something more precise
  /// to say — for a censored network, for instance.
  final String? subtitle;

  /// A failure summary rendered under the subtitle in the danger colour.
  final String? errorText;

  /// The Tor implementation in use, e.g. `'tor 0.4.8.10'`. Shown in the
  /// diagnostic line when provided.
  final String? backendName;

  /// The local SOCKS port Tor is listening on. Shown in the diagnostic line.
  final int? socksPort;

  /// Which way Tor is configured to reach the network, e.g. `webTunnel, 2
  /// bridges` or `direct`.
  ///
  /// The step list distinguishes them — "Connecting via bridge…" against
  /// "Connecting to bridge…" — but the difference is one preposition, and it
  /// went unnoticed through several rounds of "it hangs at 10%" while the real
  /// answer was that no bridge lines were in force at all. Stated in words, in
  /// the same line as the ports, it cannot be missed.
  final String? bridgeSummary;

  /// Opens the bridge settings screen; the button is hidden when null.
  final VoidCallback? onOpenBridgeSettings;

  /// Leaves the screen; only reachable once [connected] is true.
  final VoidCallback? onNext;

  /// Restarts the daemon after it gave up. When provided and [errorText] is set,
  /// the primary action becomes "Retry" instead of a disabled "Next", so a
  /// failed bootstrap is not a dead end.
  final VoidCallback? onRetry;

  /// Starts the daemon for the first time.
  ///
  /// When this is non-null the screen is in its "not attempted yet" state: the
  /// heading invites the user to connect and the primary action does so. Tor is
  /// never started behind the user's back, so a stalled bootstrap is always
  /// something they chose to try rather than something that happened to them.
  final VoidCallback? onConnect;

  /// Stops the daemon.
  ///
  /// Rendered whenever Tor is running, so an attempt that is going nowhere can
  /// always be interrupted without closing the application — and so the daemon
  /// can be stopped deliberately rather than only by exiting the app.
  final VoidCallback? onDisconnect;

  /// A bootstrap line Tor sent at WARN level while still working.
  ///
  /// Shown in the danger colour so it is not missed, but it does not put the
  /// screen into its failed state and does not summon a Retry: Tor warns about
  /// relays it routes around all the time.
  final String? warningText;

  /// Pops the route. Hidden when null, as on a first-run bootstrap that owns
  /// the whole window.
  final VoidCallback? onBack;

  /// The mockup left-aligns the heading 32 pt from the canvas edge.
  static const double _textInset = 32;

  /// The progress bar is inset 20 pt, giving the measured 349 pt track.
  static const double _barInset = 20;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      bottomBar: _ConnectionActions(
        connected: connected,
        diagnostic: _diagnostic(),
        onOpenBridgeSettings: onOpenBridgeSettings,
        onNext: onNext,
        onRetry: onRetry,
        onConnect: onConnect,
        onDisconnect: onDisconnect,
        failed: !connected && errorText != null && onRetry != null,
      ),
      child: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          child: CenteredContent(
            maxWidth: AppMetrics.maxContentWidth * 2,
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // A header row rather than an overlaid arrow.
                //
                // The arrow used to sit in a `Positioned` at the far left while
                // the title started at a fixed 32 pt inset, so the two shared
                // the same space and the arrow covered the first letters of the
                // heading. A row gives the button its own box, which means the
                // title can never be overlapped no matter the text scale or the
                // length of the heading.
                Padding(
                  padding: EdgeInsets.fromLTRB(onBack == null ? _textInset : 4, 12, _textInset, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (onBack != null)
                        // A filled circular button rather than a bare glyph: at
                        // this size an unadorned chevron on a dark canvas reads
                        // as a stray mark, and the mockup's own controls all
                        // have a surface behind them.
                        Material(
                          color: AppColors.surface,
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: onBack,
                            child: const SizedBox(
                              width: 40,
                              height: 40,
                              child: Icon(
                                Icons.arrow_back_ios_new,
                                size: 16,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                        ),
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(top: onBack == null ? 0 : 12),
                          child: Text(_title, style: AppTypography.h2),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  // Aligned with the title, not with the screen edge, so the
                  // block reads as one unit beside the arrow.
                  padding: EdgeInsets.fromLTRB(onBack == null ? _textInset : 52, 8, _textInset, 0),
                  child: Text(subtitle ?? _defaultSubtitle, style: AppTypography.secondary),
                ),
                if (errorText != null)
                  Padding(
                    padding: EdgeInsets.fromLTRB(onBack == null ? _textInset : 52, 8, _textInset, 0),
                    child: Text(
                      errorText!,
                      style: AppTypography.secondary.copyWith(color: AppColors.danger),
                    ),
                  ),
                if (warningText != null &&
                    warningText != errorText &&
                    warningText != (subtitle ?? _defaultSubtitle))
                  Padding(
                    padding: EdgeInsets.fromLTRB(onBack == null ? _textInset : 52, 8, _textInset, 0),
                    child: Text(
                      warningText!,
                      style: AppTypography.secondary.copyWith(color: AppColors.danger),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(_barInset, 37, _barInset, 0),
                  child: AppProgressBar(value: progress),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: Text(
                    '${(progress.clamp(0.0, 1.0) * 100).round()}%',
                    textAlign: TextAlign.center,
                    style: AppTypography.h2,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 34, bottom: 24),
                  child: BootstrapStepList(steps: steps),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The heading, which has three states rather than two: nothing has been
  /// attempted yet, an attempt is under way, and the circuit is up.
  String get _title {
    if (connected) return 'Connected to Tor Network';
    if (onConnect != null) return 'Connect to Tor Network';
    return 'Connecting to Tor Network';
  }

  String get _defaultSubtitle {
    if (connected) return 'Traffic is routed through the Tor network.';
    if (onConnect != null) {
      return 'Choose how to reach the network if Tor is blocked where you are, '
          'then connect.';
    }
    return 'Establishing secure connection…';
  }

  /// The backend and SOCKS port, joined for the caption under the buttons.
  /// Returns null when the caller knows neither, so the line disappears rather
  /// than showing an empty label.
  String? _diagnostic() {
    final parts = <String>[
      if (backendName != null && backendName!.isNotEmpty) 'Backend: $backendName',
      if (socksPort != null) 'SOCKS: 127.0.0.1:$socksPort',
      if (bridgeSummary != null && bridgeSummary!.isNotEmpty)
        'Bridges: $bridgeSummary',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// The pinned footer: the diagnostic caption, the bridge-settings escape hatch
/// and the primary action, both inset 45 pt as in the mockup.
class _ConnectionActions extends StatelessWidget {
  const _ConnectionActions({
    required this.connected,
    required this.diagnostic,
    required this.onOpenBridgeSettings,
    required this.onNext,
    required this.onRetry,
    required this.onConnect,
    required this.onDisconnect,
    required this.failed,
  });

  final bool connected;
  final String? diagnostic;
  final VoidCallback? onOpenBridgeSettings;
  final VoidCallback? onNext;

  /// Restarts the daemon. Only meaningful once it has given up.
  final VoidCallback? onRetry;

  /// Starts the daemon for the first time. Non-null only before any attempt.
  final VoidCallback? onConnect;

  /// Stops the daemon.
  ///
  /// Rendered whenever Tor is running, so an attempt that is going nowhere can
  /// always be interrupted without closing the application — and so the daemon
  /// can be stopped deliberately rather than only by exiting the app.
  final VoidCallback? onDisconnect;

  /// True when Tor has stopped trying, so the primary action becomes "Retry"
  /// rather than a permanently disabled "Next".
  final bool failed;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppMetrics.controlInset, 8, AppMetrics.controlInset, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (diagnostic != null) ...<Widget>[
              Text(diagnostic!, textAlign: TextAlign.center, style: AppTypography.caption),
              const SizedBox(height: 14),
            ],
            if (onOpenBridgeSettings != null) ...<Widget>[
              SecondaryButton(
                label: 'Go to Tor bridge settings',
                onPressed: onOpenBridgeSettings,
              ),
              const SizedBox(height: AppMetrics.stackedButtonGap),
            ],
            // A way to stop what is running. Without it the only way to abandon
            // a stalled bootstrap was to close the application, which is not a
            // decision a button should be replaced by.
            if (onDisconnect != null) ...<Widget>[
              SecondaryButton(
                label: 'Disconnect Tor',
                onPressed: onDisconnect,
              ),
              const SizedBox(height: AppMetrics.stackedButtonGap),
            ],
            // Four states, in order of precedence:
            //   failed  -> Retry, because a dead end helps nobody;
            //   not yet attempted -> Connect, so the user starts it;
            //   connected -> Continue;
            //   in flight -> a disabled Next, matching the mockup, which tells
            //                the user that something is still going to happen.
            PrimaryButton(
              label: failed
                  ? 'Retry'
                  : onConnect != null
                      ? 'Connect'
                      : connected
                          ? 'Continue'
                          : 'Next',
              onPressed: failed
                  ? onRetry
                  : onConnect ?? (connected ? onNext : null),
            ),
          ],
        ),
      ),
    );
  }
}
