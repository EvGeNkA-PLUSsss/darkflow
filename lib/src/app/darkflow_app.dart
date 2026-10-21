import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:file_picker/file_picker.dart';

import '../data/attachment_preview_cache.dart';
import 'log_book.dart';
import '../data/models/contact.dart';
import '../data/models/message.dart';
import '../data/models/protected_file.dart';
import '../design/design.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/my_profile_screen.dart';
import '../features/auth/onion_qr_screen.dart';
import '../features/auth/password_setup_screen.dart';
import '../features/auth/qr_scanner_screen.dart';
import '../features/auth/signup_screen.dart';
import '../features/chats/add_contact_sheet.dart';
import '../features/chats/chat_screen.dart';
import '../features/chats/chats_screen.dart';
import '../features/common/text_prompt_dialog.dart';
import '../features/files/file_opener.dart';
import '../features/files/protected_files_screen.dart';
import '../features/profile/contact_actions_sheet.dart';
import '../features/profile/contact_profile_screen.dart';
import '../features/shell/desktop_shell.dart';
import '../features/settings/about_screen.dart';
import '../features/settings/microphone_screen.dart';
import '../features/settings/relay_settings_screen.dart';
import '../features/settings/security_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/widgets/microphone_picker.dart';
import '../features/tor/tor_bridge_settings_screen.dart';
import '../features/tor/tor_connection_screen.dart';
import '../features/tor/widgets/bootstrap_step_list.dart';
import '../media/voice_recorder.dart';
import '../notifications/notification_service.dart';
import '../tor/tor_manager.dart';
import 'app_controller.dart';
import 'app_scope.dart';
import 'diagnostics.dart';

/// The application version shown in Settings and About.
///
/// Supplied by the build rather than read from `package_info_plus`. Two reasons,
/// and the first is why this is not a plain constant any more:
///
///  * A constant is a second copy of `version:` in pubspec.yaml, and nothing
///    connected them. Bumping pubspec for a release and forgetting this file
///    shipped a build whose About screen and diagnostic reports named the
///    previous version — the one detail a bug report depends on, wrong in exactly
///    the situation it is needed. `tool/release.ps1` passes the pubspec values
///    through `--dart-define`, so there is one source of truth.
///  * A plugin lookup would make the value depend on a platform channel being
///    available, which it is not at the point the vault header is written.
///
/// The default below is what a `flutter run` or a test sees with no defines: it
/// is deliberately not a plausible release number, so a build that forgot to pass
/// them is recognisable instead of silently claiming to be a real version.
const String kAppVersion = String.fromEnvironment(
  'DARKFLOW_VERSION',
  defaultValue: '0.0.0-dev',
);

/// The build number, from `version: x.y.z+N` in pubspec.yaml.
const String kBuildNumber = String.fromEnvironment(
  'DARKFLOW_BUILD_NUMBER',
  defaultValue: '0',
);

/// True when this build was given a real version by the release script.
///
/// Used to say so on the About screen, because "0.0.0-dev" in a bug report means
/// "a developer build" and nothing else.
const bool kIsReleaseBuild = bool.fromEnvironment('DARKFLOW_RELEASE');

/// A one-line description of this build, for diagnostics.
String get kBuildLabel =>
    kAppVersion + (kBuildNumber == '0' ? '' : '+$kBuildNumber') +
    (kIsReleaseBuild ? '' : ' (development build)');

/// The root widget.
class DarkFlowApp extends StatefulWidget {
  const DarkFlowApp({this.controller, super.key});

  /// Injected by tests; the app creates its own controller otherwise.
  final AppController? controller;

  @override
  State<DarkFlowApp> createState() => _DarkFlowAppState();
}

class _DarkFlowAppState extends State<DarkFlowApp> with WidgetsBindingObserver {
  late final AppController _controller = widget.controller ?? AppController();
  late final bool _ownsController = widget.controller == null;

  /// The root navigator, held so locking can return to the first route.
  ///
  /// Every screen that changes a security-relevant thing — the settings switch, the
  /// security screen's Lock button, the lifecycle observer — is a *pushed* route above
  /// the root. Changing the stage renders the password screen underneath them, which is
  /// invisible: the pushed route stays on top and the lock looks like it did nothing.
  /// Popping to the first route is what actually shows it.
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// The platform's alert channel, handed to the controller so incoming messages
  /// can reach it.
  final NotificationService _notifications = NotificationService();

  @override
  void initState() {
    super.initState();
    // Observed so the app knows whether the user is looking at it. An alert for a
    // message that just appeared on screen is an interruption with nothing in it,
    // and the lock-on-background setting needs the same signal.
    WidgetsBinding.instance.addObserver(this);
    _controller.attachNotifications(_notifications);
    _controller.onLocked = _returnToUnlock;
    unawaited(_prepareNotifications());
    unawaited(_controller.bootstrap());
  }

  /// Unwinds every pushed route so the password screen is what the user sees.
  void _returnToUnlock() {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    // `popUntil` rather than `pop`: a lock can happen under any depth of stack — a
    // profile over a chat over the list — and only the first route is the one the stage
    // machine renders into.
    navigator.popUntil((Route<dynamic> route) => route.isFirst);
  }

  Future<void> _prepareNotifications() async {
    await _notifications.initialise(
      onOpened: (String conversationKey) => _controller.openConversationFromAlert(
        conversationKey,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    _controller.setForeground(foreground);

    // The vault locks when the window loses focus, if the user asked for that — but only
    // after a grace period, and that delay is load-bearing rather than a nicety.
    //
    // Android hands the foreground to a *permission dialog*: asking for the camera, or for
    // notification permission, produces `inactive` and then `paused` while the system's own
    // dialog is on screen. An immediate lock therefore locked the vault underneath the
    // scanner, and `onLocked` unwound the route stack — so the user granted camera
    // permission and was thrown back to the password screen. From the outside that reads as
    // "the QR screen does not work", and the same mechanism explains a file picker whose
    // result could not be encrypted.
    //
    // Waiting makes the two cases distinguishable: a permission dialog is answered in a
    // second or two and the application comes straight back, cancelling the timer, while a
    // genuine backgrounding lasts longer than the window and locks as before.
    if (foreground) {
      _lockTimer?.cancel();
      _lockTimer = null;
      super.didChangeAppLifecycleState(state);
      return;
    }

    if (state == AppLifecycleState.inactive) {
      super.didChangeAppLifecycleState(state);
      return;
    }
    if (!_controller.settings.lockOnBackground) {
      super.didChangeAppLifecycleState(state);
      return;
    }
    // A platform dialog is holding the lock off; the caller releases it when the dialog
    // closes, and the lock is not re-armed here because the application never left.
    if (_controller.isAutoLockSuspended) {
      super.didChangeAppLifecycleState(state);
      return;
    }

    _lockTimer?.cancel();
    _lockTimer = Timer(_lockGrace, () {
      if (!mounted) return;
      // Re-checked rather than assumed: the setting can be turned off and a dialog can
      // open during the wait.
      if (_controller.isAutoLockSuspended) return;
      if (!_controller.settings.lockOnBackground) return;
      unawaited(_controller.lock());
    });
    super.didChangeAppLifecycleState(state);
  }

  /// How long the application may be away before the vault locks itself.
  ///
  /// Long enough to answer a system permission dialog, short enough that a phone put down
  /// on a table is locked by the time anyone picks it up.
  static const Duration _lockGrace = Duration(seconds: 3);

  Timer? _lockTimer;

  @override
  void dispose() {
    _lockTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: _controller,
      child: MaterialApp(
        title: 'DarkFlow',
        navigatorKey: _navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(),
        locale: const Locale('en'),
        supportedLocales: const <Locale>[Locale('en'), Locale('ru')],
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        // Second line of defence against `MaterialApp`'s fallback text style.
        //
        // Flutter applies a red monospace style with a double yellow underline
        // to any `Text` that ends up outside a `Material`, and a style that
        // omits `decoration` inherits it. The design system now sets it on every
        // style, but a raw `TextStyle` added later would reintroduce the
        // stripes; this override means it cannot.
        builder: (context, child) => DefaultTextStyle(
          style: const TextStyle(
            decoration: TextDecoration.none,
            color: AppColors.textPrimary,
          ),
          child: child ?? const SizedBox.shrink(),
        ),
        home: const _RootView(),
      ),
    );
  }
}

/// Chooses the screen that matches the controller's stage.
class _RootView extends StatelessWidget {
  const _RootView();

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    return switch (controller.stage) {
      AppStage.booting => _BootstrapView(message: controller.statusMessage),
      AppStage.failure => _FailureView(
          message: controller.failure ?? 'Something went wrong.',
          onRetry: controller.retryBootstrap,
        ),
      AppStage.needsAccount => const _OnboardingFlow(),
      AppStage.locked => _LockedView(controller: controller),
      AppStage.torSetup => const _TorSetupView(),
      AppStage.busy => _BootstrapView(message: controller.statusMessage ?? 'Working…'),
      AppStage.ready => const _ShellView(),
    };
  }
}

/// Shown while the vault is being opened or a key is being derived.
class _BootstrapView extends StatelessWidget {
  const _BootstrapView({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppMetrics.controlInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text('DarkFlow', style: AppTypography.logo, textAlign: TextAlign.center),
              const SizedBox(height: 28),
              const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.6),
              ),
              if (message != null) ...<Widget>[
                const SizedBox(height: 22),
                Text(message!, textAlign: TextAlign.center, style: AppTypography.secondary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when the vault cannot be opened at all.
class _FailureView extends StatelessWidget {
  const _FailureView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppMetrics.controlInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.error_outline, size: 48, color: AppColors.danger),
              const SizedBox(height: 20),
              const Text('DarkFlow could not start', style: AppTypography.h2, textAlign: TextAlign.center),
              const SizedBox(height: 14),
              Text(message, textAlign: TextAlign.center, style: AppTypography.secondary),
              const SizedBox(height: 28),
              PrimaryButton(label: 'Try again', onPressed: () => unawaited(onRetry())),
            ],
          ),
        ),
      ),
    );
  }
}

/// The return path: an account exists and the master key is not in memory.
///
/// The account password is the only way in, so there is no branch here: a vault
/// that could also be opened from a short code would be a second, weaker lock on
/// the same door.
class _LockedView extends StatefulWidget {
  const _LockedView({required this.controller});

  final AppController controller;

  @override
  State<_LockedView> createState() => _LockedViewState();
}

class _LockedViewState extends State<_LockedView> {
  String? _error;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;

    return LoginScreen(
      errorText: _error ?? controller.statusMessage,
      onUnlock: (password) async {
        setState(() => _error = null);
        await controller.unlockWithPassword(password);
        if (!mounted) return;
        setState(() => _error = controller.isUnlocked ? null : controller.statusMessage);
      },
      // Not "create account" — the vault already exists, and offering to create
      // a second one would be a lie. The only truthful move when the password
      // is gone is to erase and start over, and it is destructive enough to
      // deserve a confirmation.
      onCreateAccount: () => unawaited(_confirmStartOver(context, controller)),
    );
  }
}

/// Asks before destroying the vault, then does it.
Future<void> _confirmStartOver(BuildContext context, AppController controller) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Erase everything?'),
      content: const Text(
        'The account can only be opened with its password, and there is no way '
        'to recover it. Erasing removes every message, file and key on this '
        'device and cannot be undone.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          child: const Text('Erase and start over'),
        ),
      ],
    ),
  );
  if (confirmed ?? false) await controller.eraseAndStartOver();
}

/// Sign-up: name, then password. The same two steps on every platform.
class _OnboardingFlow extends StatefulWidget {
  const _OnboardingFlow();

  @override
  State<_OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<_OnboardingFlow> {
  int _step = 0;
  String _name = '';
  String _about = '';
  String _password = '';
  String? _error;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);

    return switch (_step) {
      0 => SignUpScreen(
          busy: false,
          errorText: _error,
          onSubmit: (name, about) async {
            setState(() {
              _name = name.trim();
              _about = about.trim();
              _error = null;
              _step = 1;
            });
          },
          // Back on the very first screen would have nowhere to go either.
        ),
      _ => PasswordSetupScreen(
          busy: false,
          errorText: _error,
          onSubmit: (password) async {
            setState(() {
              _password = password;
              _error = null;
            });
            // Choosing the password creates the account. There is no third step
            // any more: a phone used to be offered a six-digit PIN here, and it
            // was removed because it was a second wrap of the same master key —
            // two ways in is one way too many.
            await _createAccount(controller);
          },
          onBack: () => setState(() => _step = 0),
        ),
    };
  }

  /// Creates the account and, on failure, drops back to the password step with
  /// the reason on screen.
  Future<void> _createAccount(AppController controller) async {
    await controller.createAccount(
      displayName: _name.isEmpty ? 'DarkFlow user' : _name,
      about: _about,
      password: _password,
    );
    if (!mounted) return;
    if (controller.stage == AppStage.failure) {
      setState(() {
        _error = controller.failure;
        _step = 1;
      });
    }
  }
}

/// The unlocked application.
///
/// Until Tor has a circuit the app shows the connection screen, because nothing
/// can be sent or received without it and pretending otherwise would be a lie.
/// The user may step past it to read existing conversations, which is why it is
/// a gate rather than a wall.
class _ShellView extends StatefulWidget {
  const _ShellView();

  @override
  State<_ShellView> createState() => _ShellViewState();
}

class _ShellViewState extends State<_ShellView> {
  final VoiceRecorder _recorder = VoiceRecorder();
  bool _torGateDismissed = false;

  /// Which note is playing. Shared rather than copied, because the conversation is a pushed route on a
  /// phone and a route cannot be handed a value that changes later.
  final PlaybackController _playback = PlaybackController();

  /// True once the stored microphone choice has been handed to the recorder.
  ///
  /// Done on the first build rather than in `initState`, because the settings are
  /// read from the controller and the controller is only in scope inside a build.
  /// Once is enough: the value only changes when the picker writes it, and the
  /// picker tells the recorder directly.
  bool _microphoneApplied = false;

  /// The controller, kept once the first build has it.
  ///
  /// Needed by the call audio callbacks, which run outside a build and so have no
  /// context to read the scope from.

  @override
  void dispose() {
    // Disposed with the shell that owns it. A `ValueNotifier` holds its listeners until it is
    // disposed, and the conversation route subscribes to this one — so a shell torn down without this
    // would keep the route's builder alive through the notifier's listener list.
    _playback.dispose();
    unawaited(_recorder.dispose());
    super.dispose();
  }

  /// Opens or closes the call's microphone, as the controller asks.
  ///
  /// The controller owns the call's *state*; this owns the devices, because the recorder
  /// and the speaker belong to the shell. That division is why the controller exposes a
  /// callback rather than holding a recorder of its own: the account layer has no
  /// business opening a microphone, and a build with no audio plugins — a test — simply

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final tor = controller.tor;

    if (!_microphoneApplied) {
      _microphoneApplied = true;
      // Without this the choice survived a restart in the settings and was never
      // used: the recorder defaults to the system device, so a user who picked a
      // headset got the built-in array again on the next launch and had no way to
      // tell why.
      _recorder.microphoneId = controller.settings.microphoneId;
    }

    // A tapped alert asks for a conversation. Acted on here rather than at the
    // moment of the tap, because the tap may arrive while the vault is locked or
    // while this widget does not exist yet — the request is kept by the controller
    // and consumed when there is somewhere to navigate to.
    final alertTarget = controller.pendingAlertConversation;
    if (alertTarget != null) {
      controller.clearPendingAlert();
      unawaited(_openFromAlert(context, controller, _recorder, alertTarget));
    }

    // The gate covers "no daemon yet" as well as "daemon running but not
    // connected". Waiting for a non-null manager meant the connection screen
    // could be skipped entirely if the manager was created a frame later than
    // the shell, which is exactly what happened on first run.
    final gateOpen = !_torGateDismissed &&
        (tor == null || !tor.status.isConnected);
    if (gateOpen) {
      final status = tor?.status;
      // Tor never starts on its own, so this screen has three genuinely
      // different jobs: invite a first attempt, show one in progress, or offer
      // a retry after a failure. Which button appears follows from that.
      final notStarted = tor == null || !tor.isStarted;
      return TorConnectionScreen(
        progress: status?.progress ?? 0,
        connected: status?.isConnected ?? false,
        subtitle: controller.failure ??
            (notStarted
                ? 'Tor is not running yet. Choose a bridge first if Tor is '
                    'blocked where you are, then connect.'
                : (status == null || status.summary.isEmpty
                    ? 'Starting the Tor daemon…'
                    : status.summary)),
        errorText: status?.error ?? controller.failure,
        backendName: controller.engine.backendName,
        socksPort: status?.socksPort,
        bridgeSummary: _bridgeSummary(controller),
        steps: _stepsFor(status),
        onOpenBridgeSettings: () => _openBridgeSettings(context, controller),
        onRetry: () => unawaited(controller.restartTor()),
        onConnect: notStarted ? () => unawaited(controller.startTor()) : null,
        onDisconnect: notStarted ? null : () => unawaited(controller.stopTor()),
        warningText: status?.warning,
        // No back button on the setup gate. It used to be one, and pressing it
        // dropped the user into the messenger with Tor never configured — a
        // control that looked like navigation but silently skipped setup. The
        // explicit "Continue without connecting" action above replaces it, and
        // only appears after Tor has failed.
        onNext: () => setState(() => _torGateDismissed = true),
      );
    }

    return _ChatsHome(
      recorder: _recorder,
      playback: _playback,
      onVoicePlaybackChanged: (id, progress) {
        // Recorded as it arrives, so the log shows whether the mark reached the screen at all. The
        // report was "the sound plays and the button stays off", which is either this never being
        // called or the value never reaching the bubble — and those need different fixes.
        if (id != _playback.value.attachmentId) {
          logApp(
            'the screen is now showing a different note as playing',
            detail: 'was ${_playback.value.attachmentId == null ? 'none' : 'set'}, '
                'now ${id == null ? 'none' : 'set'}',
          );
        }
        // The notifier, not `setState`. A rebuild of the shell does not reach a pushed route, which is
        // what left the button on "play" while the note was audible.
        _playback.set(id, progress);
      },
    );
  }

  /// Maps the Tor manager's stage onto the four milestones the mockup shows,
  /// using Tor's own progress percentage to decide which one is in flight.
  ///
  /// [status] is null before the manager exists, in which case every step is
  /// still pending — which is the truthful picture at that moment.
  List<BootstrapStep> _stepsFor(TorStatus? status) {
    if (status == null) {
      return const <BootstrapStep>[
        BootstrapStep(label: 'Initializing connection…', state: BootstrapStepState.active),
        BootstrapStep(label: 'Connecting to bridge…'),
        BootstrapStep(label: 'Establishing secure circuit…'),
        BootstrapStep(label: 'Connection established!'),
      ];
    }
    const labels = <String>[
      'Initializing connection…',
      'Connecting to bridge…',
      'Establishing secure circuit…',
      'Connection established!',
    ];
    final index = switch (status.progress) {
      < 0.05 => 0,
      < 0.5 => 1,
      < 1 => 2,
      _ => 3,
    };
    final failed = status.stage == TorStage.failed;
    return <BootstrapStep>[
      for (var i = 0; i < labels.length; i++)
        BootstrapStep(
          label: status.usingBridges && i == 1 ? 'Connecting via bridge…' : labels[i],
          state: failed && i == index
              ? BootstrapStepState.failed
              : i < index
                  ? BootstrapStepState.done
                  : i == index
                      ? (status.isConnected ? BootstrapStepState.done : BootstrapStepState.active)
                      : BootstrapStepState.pending,
          reason: failed && i == index ? status.error : null,
        ),
    ];
  }
}

/// The first of the two first-run steps: how should this device reach Tor?
///
/// Nothing is connected from here. The screen exists so that a user on a
/// censored network can pick a transport *before* watching a bootstrap stall,
/// which is the opposite of the previous behaviour and the reason Tor no longer
/// starts automatically.
class _TorSetupView extends StatelessWidget {
  const _TorSetupView();

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final current = controller.settings.torSettings;
    return TorBridgeSettingsScreen(
      presets: controller.bridgePresets,
      selectedMode: current.mode,
      initialBridges: current.customBridges,
      // No back arrow: there is nothing behind this screen, and an arrow that
      // moves forward would misdescribe itself.
      showBackAffordance: false,
      onApply: (mode, bridges) => unawaited(
        controller.applyTorSettings(
          current.copyWith(mode: mode, customBridges: bridges),
        ),
      ),
      // Reached from the screen's own "Next" too, which is how the user moves
      // on to the connection attempt.
      onBack: controller.completeTorSetup,
    );
  }
}

/// The conversation list, and everything reachable from it.
/// The conversation list, and — on a wide window — the conversation beside it.
///
/// Below [AppMetrics.twoPaneBreakpoint] this is the phone layout: a list that
/// pushes a route when a thread is opened. Above it the shell switches to the
/// two-pane arrangement every desktop messenger uses, where the list stays put
/// and the conversation fills the rest of the window.
class _ChatsHome extends StatefulWidget {
  const _ChatsHome({
    required this.recorder,
    required this.playback,
    required this.onVoicePlaybackChanged,
  });

  final VoiceRecorder recorder;

  /// Which note is playing. Shared with the conversation route rather than copied into it.
  final PlaybackController playback;

  final void Function(String? attachmentId, double progress) onVoicePlaybackChanged;

  @override
  State<_ChatsHome> createState() => _ChatsHomeState();
}

class _ChatsHomeState extends State<_ChatsHome> {
  /// Which thread the right-hand pane is showing. Null means "nothing open",
  /// which is a real state on desktop rather than an error.
  String? _selectedPeerOnion;

  List<ConversationSummary> _summaries(AppController controller) => <ConversationSummary>[
        for (final conversation in controller.conversations)
          ConversationSummary(
            peerOnion: conversation.peerOnion,
            displayName: controller.contactFor(conversation.peerOnion)?.displayName ??
                conversation.peerOnion,
            avatarPath: controller.contactFor(conversation.peerOnion)?.avatarPath,
            online: controller.canReach(conversation.peerOnion),
            lastMessagePreview: conversation.lastMessagePreview,
            lastMessageAt: conversation.lastMessageAt,
            unreadCount: conversation.unreadCount,
            muted: conversation.muted,
            pinned: conversation.pinned,
          ),
      ];

  /// Loads a thread's history and opens it in the right-hand pane.
  Future<void> _select(AppController controller, String peerOnion) async {
    await controller.loadMessages(peerOnion);
    unawaited(controller.markRead(peerOnion));
    if (mounted) setState(() => _selectedPeerOnion = peerOnion);
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final summaries = _summaries(controller);

    return AttachmentPreviewListener(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // A transfer that landed since the last build invalidates every cached
          // decryption, so the cache is dropped before anything is read from it.
          _syncPreviewCache(controller);
          final twoPane = constraints.maxWidth >= AppMetrics.twoPaneBreakpoint;
          if (!twoPane) {
            return ChatsScreen(
              conversations: summaries,
              onOpenConversation: (onion) => openConversation(
                context,
                controller,
                onion,
                widget.recorder,
                widget.playback,
                widget.onVoicePlaybackChanged,
              ),
              onAddContact: () => _addContact(context, controller),
              onStartChatWith: (onion) =>
                  controller.addContact(onionAddress: onion).then((_) {}),
              // Without these the phone layout has no route to settings or to the
              // profile: there is no desktop sidebar here to offer one.
              onOpenSettings: () => unawaited(openSettings(context, controller, recorder: widget.recorder)),
              onOpenProfile: () => unawaited(openMyProfile(context, controller)),
              // Offered on a long press of a row, so the phone reaches a contact's
              // management actions exactly as the desktop sidebar does.
              onOpenContactProfile: (onion) =>
                  unawaited(openContactProfile(context, controller, onion)),
            );
          }

          final selected = _selectedPeerOnion;
          return DesktopShell(
            conversations: summaries,
            selectedPeerOnion: selected,
            onSelectConversation: (onion) => unawaited(_select(controller, onion)),
            onClearSelection:
                selected == null ? null : () => setState(() => _selectedPeerOnion = null),
            onAddContact: () => _addContact(context, controller),
            onOpenSettings: () => unawaited(openSettings(context, controller, recorder: widget.recorder)),
            onOpenSelfProfile: () => unawaited(openMyProfile(context, controller)),
            onOpenContactProfile: (onion) =>
                unawaited(openContactProfile(context, controller, onion)),
            onStartChatWith: (onion) =>
                controller.addContact(onionAddress: onion).then((_) {}),
            displayName: controller.account?.displayName ?? 'DarkFlow',
            selfInitial: controller.account == null
                ? '?'
                : AppAvatar.initialOf(controller.account!.displayName),
            selfAvatarPath: controller.account?.avatarPath,
            conversationPane: selected == null
                ? null
                : buildChatScreen(
                    context: context,
                    controller: controller,
                    peerOnion: selected,
                    recorder: widget.recorder,
                    playback: widget.playback,
                    onPlaybackChanged: widget.onVoicePlaybackChanged,
                    // No back arrow: the list is already beside it.
                    onBack: null,
                  ),
          );
        },
      ),
    );
  }
}

/// Opens the add-contact sheet and adds whatever the user pastes or scans.
///
/// The scanner is offered wherever the camera exists. On desktop it is left out —
/// a webcam pointed at a printed code is a worse way to type 56 characters than
/// pasting them — so the button is absent rather than opening a camera that has
/// nothing to point at.
///
/// Both paths end here rather than inside the sheet, because both of them *navigate*.
/// The sheet's job is to collect an address or ask for the camera; opening the scanner
/// from within it meant pushing a route in the same turn as the sheet was popping, and
/// the two changes racing each other left a black screen behind the camera.
Future<void> _addContact(BuildContext context, AppController controller) async {
  final result = await AddContactSheet.show(
    context,
    onAdd: (String onion, String name) =>
        unawaited(controller.addContact(onionAddress: onion, displayName: name)),
    onScanQr: supportsQrScanning ? () {} : null,
  );
  if (!context.mounted) return;
  if (result == AddContactResult.scanRequested) {
    await _scanContactCode(context, controller);
  }
}

/// True when this platform has a camera the scanner can use.
///
/// Android and iOS are where scanning matters: the address has to be typed on a
/// phone keyboard otherwise. Windows keeps the button out of the way.
bool get supportsQrScanning => Platform.isAndroid || Platform.isIOS;

/// Opens the scanner and adds the contact it reads.
///
/// By the time this runs the sheet has closed, so the scanner is the only route being
/// pushed and there is nothing for it to race with.
///
/// The automatic lock is held off for as long as the scanner is on screen. The first thing
/// the camera does is ask for permission, and the system's permission dialog takes the
/// foreground — `paused`, not merely `inactive`. The grace period in the lifecycle
/// observer covers the ordinary case; this covers the one where the user reads the dialog
/// slowly, because a vault that locks under the scanner unwinds the route stack and throws
/// them back to the password screen with the permission they just granted.
Future<void> _scanContactCode(
  BuildContext context,
  AppController controller,
) async {
  controller.holdAutoLock();
  try {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (BuildContext inner) => QrScannerScreen(
          onScanned: (String address) => Navigator.of(inner).pop(address),
          onBack: () => Navigator.of(inner).maybePop(),
        ),
      ),
    );
    if (scanned == null || !context.mounted) return;

    final contact = await controller.addContact(onionAddress: scanned);
    if (!context.mounted) return;
    _reportToUser(
      context,
      contact == null
          ? 'That address could not be added. It may already be in your list, or '
              'not a valid .onion address.'
          : 'Added ${contact.displayName}.',
    );
  } finally {
    controller.releaseAutoLock();
  }
}

// --------------------------------------------------------------- navigation

/// Shows [message] to the user, if this context is still on screen.
///
/// A helper rather than an inline `ScaffoldMessenger.of(context)` because several
/// of the callers run after an `await`, where the context may already have been
/// torn down — and `ScaffoldMessenger.of` on a dead context throws, turning a
/// failure the user should read into a second, silent one.
void _reportToUser(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Opens an attachment: decrypts it, asks, then hands it to the platform.
///
/// Two things were wrong before. The action wrote the decrypted copy into the cache and
/// put its *path* on the clipboard with nothing on screen to say so — a file path is not
/// something a user can act on, so tapping a photo appeared to do nothing at all. And
/// there was no confirmation, although the copy leaves the vault's protection the moment
/// another program opens it.
///
/// The question comes first, before anything is decrypted, because it is a question about
/// the plaintext existing rather than about what happens to it afterwards.
Future<void> openAttachment(
  BuildContext context,
  AppController controller,
  Attachment attachment,
) async {
  final vault = controller.fileVault;
  if (vault == null) {
    _reportToUser(context, 'The vault is locked, so that file cannot be opened.');
    return;
  }

  final agreed = await _confirmPlaintextExposure(context, attachment.fileName);
  if (!agreed || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  try {
    final file = await vault.materialise(
      attachmentId: attachment.id,
      fileName: attachment.fileName,
    );
    final failure = await FileOpener.open(file);
    if (failure != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(failure)));
    }
  } on Object catch (error) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Could not open that file: $error')));
  }
}

/// Writes a decrypted copy of an attachment somewhere the user chooses.
///
/// The difference from [openAttachment] is what survives: the cache the open path uses is
/// wiped on every lock, so a file the user wants to keep has to be written outside it —
/// and choosing where is the user's decision, not the application's.
Future<void> saveAttachmentForever(
  BuildContext context,
  AppController controller,
  Attachment attachment,
) async {
  final vault = controller.fileVault;
  if (vault == null) {
    _reportToUser(context, 'The vault is locked, so that file cannot be saved.');
    return;
  }

  final messenger = ScaffoldMessenger.of(context);
  try {
    final target = await _withAutoLockSuspended(
      controller,
      () => FilePicker.saveFile(
        dialogTitle: 'Save a decrypted copy',
        fileName: attachment.fileName,
        bytes: Uint8List(0),
        mimeType: attachment.mimeType,
      ),
    );
    if (target == null) return;

    final plain = await vault.materialise(
      attachmentId: attachment.id,
      fileName: attachment.fileName,
    );
    final destination = File(target.path);
    await destination.parent.create(recursive: true);
    await plain.copy(destination.path);

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Saved to ${destination.path}. The copy is no longer encrypted, so '
            'DarkFlow cannot protect it any more.',
          ),
        ),
      );
  } on Object catch (error) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Could not save that file: $error')));
  }
}

/// Asks before a decrypted copy is handed to another application.
///
/// Shared by the message menu, the file card's own open action and the protected-files
/// screen, so the wording and the consequence described are the same wherever the user
/// meets it. A dialog rather than a snack bar: the consequence is permanent — a program
/// that has read the file can keep it — and a message that disappears on its own is the
/// wrong shape for a decision.
Future<bool> _confirmPlaintextExposure(BuildContext context, String fileName) async {
  final agreed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialog) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Open this file?'),
      content: Text(
        '“$fileName” will be decrypted and handed to another application, which means '
        'anything running on this device can read it while it is open. Locking DarkFlow '
        'deletes the temporary copy, but a program that already has it can keep it.',
        style: AppTypography.secondary,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('confirm-open-attachment'),
          onPressed: () => Navigator.of(dialog).pop(true),
          child: const Text('Open'),
        ),
      ],
    ),
  );
  return agreed ?? false;
}

/// Decrypted image previews, so a photo shows as a photo.
///
/// `ChatScreen` has accepted an `attachmentPreviews` map since it was written and
/// nothing ever filled it, so every image message arrived as the same grey
/// placeholder glyph however long ago its bytes had been downloaded.
///
/// The decryption itself lives in [AttachmentPreviewCache], which owns the paths,
/// the in-flight and failed sets, and the revision the interface listens to. It is
/// a separate object because the faults that produce "previews do not load" — a
/// decryption that failed, bytes that never arrived, a cache that never learned a
/// decryption finished, a lock recorded as a broken file — all look identical from
/// the outside, and separating them is what makes them testable.
final AttachmentPreviewCache _previewCache = AttachmentPreviewCache();

/// Resolved previews for [attachments], starting any decryption that is missing.
///
/// Returns only what is ready now; the rebuild that
/// [AttachmentPreviewCache.revision] triggers brings the rest in, which is why a
/// caller has to be inside an [AttachmentPreviewListener].
Map<String, Widget> attachmentPreviewsFor(
  AppController controller,
  Iterable<Attachment> attachments,
) {
  final ready = _previewCache.resolve(controller.fileVault, attachments);
  return <String, Widget>{
    for (final entry in ready.entries)
      entry.key: Image.file(
        entry.value,
        fit: BoxFit.cover,
        // A file that a lock or the cache purge removed underneath us must not
        // take the whole conversation down with it.
        errorBuilder: (_, _, _) => const ColoredBox(
          color: AppColors.surfaceHigh,
          child: Icon(Icons.broken_image_outlined, size: 40),
        ),
      ),
  };
}

/// Rebuilds [child] whenever a decrypted preview becomes available.
///
/// Both layouts need this: the pushed route is built once, and the two-pane pane
/// only rebuilds on a controller notification — and decrypting a file is not one
/// of those. Without it the decryption completes and the picture stays a
/// placeholder, which is indistinguishable from the feature not working at all.
class AttachmentPreviewListener extends StatelessWidget {
  const AttachmentPreviewListener({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: _previewCache.revision,
        builder: (BuildContext context, int _, Widget? inner) =>
            inner ?? const SizedBox.shrink(),
        child: child,
      );
}

/// The attachment revision the preview cache was last rebuilt against.
int _previewRevisionSeen = 0;

/// Drops the preview cache when the app layer says an attachment changed.
///
/// Keyed on a counter rather than on a notification, because a notification
/// happens for every message, every draft keystroke and every status change, and
/// throwing away decrypted images that often would make a conversation with
/// photos in it flicker. The counter only moves when an attachment actually gains
/// or loses its bytes — which is exactly when a remembered "cannot be read" has
/// become wrong.
void _syncPreviewCache(AppController controller) {
  final revision = controller.attachmentRevision;
  if (revision == _previewRevisionSeen) return;
  _previewRevisionSeen = revision;
  _previewCache.clear();
}

/// Builds the conversation screen for `peerOnion`.
///
/// Shared by the pushed route (phone layout) and the right-hand pane (desktop
/// layout), so the two cannot drift apart: the same callbacks, the same
/// attachment map, the same composer. The only difference is [onBack], which is
/// null in the two-pane case because there is nothing to go back to.
Widget buildChatScreen({
  required BuildContext context,
  required AppController controller,
  required String peerOnion,
  required VoiceRecorder recorder,
  required PlaybackController playback,
  required void Function(String? attachmentId, double progress) onPlaybackChanged,
  bool sending = false,
  VoidCallback? onBack,
}) {
  final contact = controller.contactFor(peerOnion);
  final messages = controller.messagesFor(peerOnion);
  final attachments = <String, Attachment>{
    for (final message in messages)
      if (message.attachmentId != null)
        if (controller.attachmentFor(message.attachmentId) != null)
          message.attachmentId!: controller.attachmentFor(message.attachmentId)!,
  };
  // Whose avatar goes on an outgoing bubble.
  //
  // `selfName` and `selfAvatarPath` were never passed, so every outgoing bubble
  // fell back to the widget's default of `'Me'` and drew an "M" — while the
  // sidebar and the conversation list drew the account's real initial next to its
  // real name. The two disagreed about the same person in the same window, which
  // is what "the avatar does not match the name" was.
  final account = controller.account;

  // ## Why the whole screen is wrapped, rather than being handed the two values
  //
  // It used to receive `playingAttachmentId` and `voiceProgress` as arguments, and both callers are
  // built once: the phone layout pushes a route, and the two-pane layout builds its pane inside a
  // shell that does not rebuild when a note starts. So the arguments were a snapshot taken when the
  // conversation opened, and a note played afterwards left the button on "play" for ever — the
  // reported fault.
  //
  // Listening to the notifier here rather than at the call sites fixes both at once and keeps the
  // feature widget itself unaware of where the state comes from: `ChatScreen` still takes two plain
  // values, and the only thing that changed is what feeds them.
  return ValueListenableBuilder<PlaybackState>(
    valueListenable: playback,
    builder: (context, playbackState, _) => ChatScreen(
      peerName: contact?.displayName ?? peerOnion,
      peerOnion: peerOnion,
      peerAvatarPath: contact?.avatarPath,
      peerOnline: controller.canReach(peerOnion),
      messages: controller.messagesFor(peerOnion),
      attachments: attachments,
      attachmentPreviews: attachmentPreviewsFor(controller, attachments.values),
      playingAttachmentId: playbackState.attachmentId,
      voiceProgress: playbackState.progress,
      selfName: account?.displayName ?? 'Me',
      selfAvatarPath: account?.avatarPath,
    // The reply id travels with the text, which is what makes the quote appear
    // on the peer's side too. It used to be dropped on the floor here — the
    // gesture was wired to the clipboard instead.
    //
    // The decision is taken *before* the send is started, from state that is
    // already in memory: whether the vault is open and whether the text is
    // anything. The composer needs a synchronous answer, because the alternative
    // is clearing the input on a message that was then refused, and the user's
    // words would be gone with nothing to show for them.
    onSend: (String text, String? replyToId) {
      final accepted = controller.isUnlocked && text.trim().isNotEmpty;
      if (accepted) {
        unawaited(controller.sendText(peerOnion, text, replyToId: replyToId));
      }
      return accepted;
    },
    onSendFailed: (String reason) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(reason)));
    },
    onAttach: () => unawaited(pickAndSendFile(context, controller, peerOnion)),
    onBack: onBack,
    // A draft the user typed and did not send is restored when the thread is
    // reopened, and written back on every keystroke.
    initialDraft: controller.draftFor(peerOnion),
    onDraftChanged: (text) => controller.saveDraft(peerOnion, text),
    sending: sending,
    onRetry: (message) => unawaited(controller.retry(message.id)),
    onOpenAttachment: (attachment) => unawaited(
      openAttachment(context, controller, attachment),
    ),
    onStartVoice: () => recorder.start(),
    onStopVoice: () => unawaited(() async {
      final file = await recorder.stop();
      if (file == null) return;
      await controller.sendVoice(
        peerOnion,
        file,
        durationMs: recorder.elapsed.inMilliseconds,
        waveform: recorder.waveform,
      );
    }()),
    onToggleVoicePlayback: (attachmentId) => unawaited(
      toggleVoicePlayback(
        controller,
        attachmentId,
        recorder,
        // The current value, not the one the screen was built with: the builder above re-runs on
        // every change, so a second tap is comparing against what is actually playing.
        playback.value.attachmentId,
        onPlaybackChanged,
        onFailed: (String message) => _reportToUser(context, message),
      ),
    ),
    // The one route into the contact's profile from a conversation. Both layouts
    // build this screen, so a phone and a two-pane window reach it the same way.
    onOpenPeerProfile: () => unawaited(openContactProfile(context, controller, peerOnion)),
    // A reply is started by the screen itself; the app layer is told after the
    // fact so it can react, but the gesture does not depend on it. It used to be
    // "copy the message body to the clipboard", with no reply and no feedback.
    onReply: (message) => unawaited(_noteReplyStarted(message)),
    // The message menu. The screen owns the menu itself — reply and copy need
    // nothing from here — and hands up only the two actions that touch the vault.
    onCopied: (String what) => _reportToUser(context, what),
    onOpenAttachmentAction: (Message message) {
      final id = message.attachmentId;
      final attachment = id == null ? null : controller.attachmentFor(id);
      if (attachment == null) return;
      unawaited(openAttachment(context, controller, attachment));
    },
    onSaveAttachment: (Message message) {
      final id = message.attachmentId;
      final attachment = id == null ? null : controller.attachmentFor(id);
      if (attachment == null) return;
      unawaited(saveAttachmentForever(context, controller, attachment));
    },
    ),
  );
}

/// Runs a platform file dialog with the automatic lock suspended.
///
/// Every picker and save dialog goes through this, and the reason is specific to
/// Android: the picker is a separate activity, so the application really does go to the
/// background while it is open. With lock-on-background on — which is the default — the
/// vault locked itself while the user was choosing a file in the other window, and the
/// chosen file could not be encrypted afterwards because the key was gone. From the
/// user's side that is "Protected files cannot be added on Android".
///
/// `try`/`finally` rather than a happy-path release: a dialog the platform refuses to
/// open, or one that throws, must not leave the lock suspended for the rest of the
/// session — that would silently disable a security setting.
Future<T> _withAutoLockSuspended<T>(
  AppController controller,
  Future<T> Function() open,
) async {
  controller.holdAutoLock();
  try {
    return await open();
  } finally {
    controller.releaseAutoLock();
  }
}

/// A no-op hook kept deliberately small: the reply is owned by [ChatScreen], and
/// this exists only so the app layer has one place to react if it ever needs to.
Future<void> _noteReplyStarted(Message message) async {}

/// Pushes the conversation screen for [peerOnion].
Future<void> openConversation(
  BuildContext context,
  AppController controller,
  String peerOnion,
  VoiceRecorder recorder,
  PlaybackController playback,
  void Function(String? attachmentId, double progress) onPlaybackChanged,
) async {
  await controller.loadMessages(peerOnion);
  unawaited(controller.markRead(peerOnion));
  if (!context.mounted) return;

  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (routeContext) => AppScope(
        controller: controller,
        // The `Builder` is load-bearing, not decoration.
        //
        // `buildChatScreen` reads the message list once and hands `ChatScreen` a
        // finished list, so nothing in the pushed subtree ever calls
        // `AppScope.of`. `AppScope` is an `InheritedNotifier` and therefore only
        // rebuilds widgets that *depend* on it — with no dependent, sending a
        // message called `notifyListeners()` into an empty room and the new
        // bubble never appeared. Depending on the scope here is what subscribes
        // the conversation to the controller.
        child: AttachmentPreviewListener(
          child: Builder(
            builder: (live) => buildChatScreen(
              context: live,
              controller: AppScope.of(live),
              peerOnion: peerOnion,
              recorder: recorder,
              // The shared notifier, not a snapshot. `buildChatScreen` listens to it, which is what
              // makes a note started after this route was pushed reach the bubble — a route is built
              // once, so a value passed here would never change.
              playback: playback,
              onPlaybackChanged: onPlaybackChanged,
              onBack: () => Navigator.of(routeContext).maybePop(),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Which voice note is playing, and how far through it is.
///
/// ## Why this is an object rather than two parameters
///
/// The state used to travel as `playingAttachmentId` and `voiceProgress`, and on a phone the
/// conversation is a **pushed route** — so those two were read once, when the route was pushed, and
/// never again. The shell rebuilt, the value changed, and the route kept the snapshot it was built
/// with. From the outside: the note plays and the button never changes.
///
/// A `ValueNotifier` in one object fixes that at the level the fault is at. The route subscribes to
/// it, so a change reaches the bubble however the screen was opened, and the two values cannot
/// disagree because they are updated together.
///
/// It also stops the whole chat list from rebuilding on every progress tick: only what listens to the
/// notifier redraws, which at five ticks a second around a list of conversations is worth having.
class PlaybackState {
  const PlaybackState({this.attachmentId, this.progress = 0});

  /// The note currently playing, or null when nothing is.
  final String? attachmentId;

  /// How far through it is, 0..1.
  final double progress;

  bool isPlaying(String attachmentId) => this.attachmentId == attachmentId;
}

class PlaybackController extends ValueNotifier<PlaybackState> {
  PlaybackController() : super(const PlaybackState());

  /// Marks a note as playing, or clears the mark with a null id.
  void set(String? attachmentId, double progress) {
    value = PlaybackState(attachmentId: attachmentId, progress: progress);
  }
}

///
/// "direct, no bridges" is the important one to be explicit about: a bootstrap
/// that stalls at 10% looks identical whether bridges are in force or not, and
/// the answer used to be visible only as one preposition inside a step label —
/// "Connecting via bridge…" against "Connecting to bridge…". That difference
/// went unnoticed through several rounds of debugging.
String _bridgeSummary(AppController controller) {
  final tor = controller.settings.torSettings;
  final lines = tor.bridgeLines;
  if (lines.isEmpty) return 'direct, no bridges';
  return '${tor.effectiveMode.label}, ${lines.length} '
      '${lines.length == 1 ? 'line' : 'lines'}';
}

/// Plays or stops a voice note, keeping the parent's progress in step.
///
/// [onFailed] is called with a sentence to show the user when the note cannot be
/// played at all.
///
/// ## Why that callback exists
///
/// Both steps here throw, and both used to be unguarded inside an `unawaited`
/// call from the bubble's tap handler, so a failure did one specific and very
/// confusing thing: `onPlaybackChanged(attachmentId, 0)` had already run, the play
/// glyph had already turned into a pause symbol, and then the exception vanished.
/// The bubble sat there looking like a note that was playing at position zero,
/// with no progress, no sound and no explanation — which is exactly what "voice
/// messages cannot be played" looks like from the outside.
///
/// The two reasons it happens are worth distinguishing, because only one of them
/// is the user's fault:
///
///  * `materialise` throws when the encrypted copy of the note is not on this
///    device. That is a missing transfer, not a corrupt file.
///  * `play` swallows a codec failure internally and simply returns, leaving the
///    progress at zero. Nothing downstream can tell that from a note that played
///    silently.
Future<void> toggleVoicePlayback(
  AppController controller,
  String attachmentId,
  VoiceRecorder recorder,
  String? playingAttachmentId,
  void Function(String? attachmentId, double progress) onPlaybackChanged, {
  void Function(String message)? onFailed,
}) async {
  if (playingAttachmentId == attachmentId) {
    await recorder.stopPlayback();
    onPlaybackChanged(null, 0);
    return;
  }
  final attachment = controller.attachmentFor(attachmentId);
  final vault = controller.fileVault;
  if (attachment == null || vault == null) {
    onFailed?.call('That voice message is no longer available.');
    return;
  }

  // ## The order matters, and getting it wrong is the reported fault
  //
  // The mark is set *before* the file is decrypted, and that is not a detail. `materialise` reads the
  // encrypted copy and decrypts it, which on a phone is tens to hundreds of milliseconds of work on
  // the platform thread. Set after it — which is where this used to be — the button stayed on "play"
  // for that whole time, and the note began playing while the screen still showed it as idle. From the
  // outside that is precisely "the sound plays and the button does not change".
  //
  // It also has to happen before, rather than after, because of what happens when the decryption
  // fails: the bubble shows the note as playing for one frame and then the failure puts it back. That
  // is correct, and it is only possible if the mark was set first.
  onPlaybackChanged(attachmentId, 0);
  // Written to the log because the reported fault was exactly this: the sound plays and the button
  // stays off. That means the screen never learned which note was playing, so the mark has to be
  // visible — reported as *set* here, and read back by whatever draws the bubble.
  logApp(
    'voice playback claimed by the screen',
    detail: 'attachment ${attachmentId.length > 8 ? attachmentId.substring(0, 8) : attachmentId}',
  );
  try {
    // ## The yield, and why a correct order was not enough
    //
    // Setting the mark before this point makes the *state* correct the instant the note is tapped. It
    // does not make the *screen* correct, and for a while this looked like the same bug coming back.
    //
    // `vault.materialise` decrypts the note with a synchronous loop over its frames — `Cipher.openChunk`
    // in a `while` — so while it runs, the UI isolate cannot build or paint a frame. The audio is
    // decoded on the platform's own thread and starts immediately; the button waits for the isolate to
    // be free. A few hundred milliseconds of a frozen screen, and the visible result is exactly "the
    // sound plays and the button does not change".
    //
    // Yielding first lets one frame be built and painted with the mark already set. The cost is one
    // event-loop turn before playback begins, which is not perceptible; the alternative is a frame that
    // shows the old state for the whole decryption.
    //
    // A plain zero delay is deliberate rather than `WidgetsBinding.instance.endOfFrame`, which would
    // make this function depend on there being a frame — and most of what it does has nothing to do
    // with the framework.
    await Future<void>.delayed(Duration.zero);

    // Decrypted here rather than before the mark, so the button changes the instant the note is
    // tapped instead of after the platform has finished reading and decrypting the file.
    final File file;
    try {
      file = await vault.materialise(
        attachmentId: attachment.id,
        fileName: attachment.fileName,
      );
    } on Object catch (error) {
      // A missing or unreadable encrypted copy: a transfer that never completed, not a codec failure.
      // Kept as its own message because the two send the user to different things — this one means the
      // note has to be sent again, and the other means the device cannot decode it.
      onPlaybackChanged(null, 0);
      onFailed?.call(
        'This voice message has not been received in full yet, so there is nothing '
        'to play. ($error)',
      );
      return;
    }

    // The result distinguishes "this note finished" from "this note was replaced
    // by another one". Clearing the playing state for a note that was replaced
    // would clear the state the replacement just set, which looks like a note that
    // starts and stops instantly.
    final finished = await recorder.play(
      file,
      totalDuration: Duration(milliseconds: attachment.durationMs ?? 0),
      onProgress: (progress) => onPlaybackChanged(attachmentId, progress),
    );
    if (finished) onPlaybackChanged(null, 0);
  } on Object catch (error) {
    onPlaybackChanged(null, 0);
    onFailed?.call('This voice message could not be played. ($error)');
  }
}

/// Opens the picker and sends whatever was chosen.
Future<void> pickAndSendFile(
  BuildContext context,
  AppController controller,
  String peerOnion,
) async {
  final picked = await _withAutoLockSuspended(
    controller,
    () => FilePicker.pickFile(dialogTitle: 'Send a file'),
  );
  final path = picked?.path;
  if (path == null) return;
  await controller.sendFile(peerOnion, File(path));
}

Future<void> _openBridgeSettings(BuildContext context, AppController controller) async {
  final tor = controller.tor;
  if (tor == null) return;
  final current = controller.settings.torSettings;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => TorBridgeSettingsScreen(
        presets: controller.bridgePresets,
        selectedMode: current.mode,
        initialBridges: current.customBridges,
        onApply: (mode, bridges) => unawaited(
          controller.applyTorSettings(
            current.copyWith(mode: mode, customBridges: bridges),
          ),
        ),
        onBack: () => Navigator.of(context).maybePop(),
      ),
    ),
  );
}

/// Opens the account's own profile.
Future<void> openMyProfile(BuildContext context, AppController controller) async {
  final account = controller.account;
  if (account == null) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AppScope(
        controller: controller,
        child: MyProfileScreen(
          displayName: account.displayName,
          about: account.about,
          onionAddress: account.onionAddress,
          createdAt: account.createdAt,
          avatarPath: account.avatarPath,
          onCopyAddress: () => unawaited(
            copyToClipboard(context, account.onionAddress, 'Your .onion address'),
          ),
          onShowQr: () => unawaited(openQr(context, account.onionAddress)),
          // A real editor, not a clipboard write.
          //
          // This row said "Change display name" and, byte for byte, did what the
          // row above it does: put the onion address on the clipboard. The
          // parameter was even documented as "Opens the display-name editor",
          // which did not exist anywhere in the app — so the account could not be
          // renamed from any screen, the tap looked broken, and the user's
          // clipboard was silently replaced.
          onChangeDisplayName: () => unawaited(
            editAccountDisplayName(context, controller),
          ),
          onChangePassword: () => unawaited(openSecurity(context, controller)),
          onBack: () => Navigator.of(context).maybePop(),
        ),
      ),
    ),
  );
}

/// Copies [text] and says so.
///
/// Every copy action in the app used to be silent: the clipboard changed and
/// nothing on screen acknowledged it, so the only way to find out whether it had
/// worked was to paste somewhere. A one-line confirmation is the whole fix.
Future<void> copyToClipboard(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('$what copied.')));
}

/// Asks for a new display name and applies it.
///
/// The dialog itself lives in `text_prompt_dialog.dart` as a stateful widget. It
/// used to be built inline here with the error message in a local variable that
/// the `showDialog` closure had already captured, so a rejected name produced no
/// message and the dialog appeared to ignore its own Save button.
Future<void> editAccountDisplayName(
  BuildContext context,
  AppController controller,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final chosen = await promptForText(
    context,
    title: 'Your display name',
    initialValue: controller.account?.displayName ?? '',
    hint: 'Display name',
    help: 'This is the name a contact sees. Up to '
        '${AppController.maxDisplayNameLength} characters.',
    maxLength: AppController.maxDisplayNameLength,
    emptyError: 'A name is required.',
  );
  if (chosen == null) return;

  final renamed = await controller.renameAccount(chosen);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          renamed
              ? 'Your display name is now “$chosen”.'
              : 'That name could not be saved.',
        ),
      ),
    );
}

/// Opens the QR code for an onion address.
Future<void> openQr(BuildContext context, String onionAddress) async {
  final messenger = ScaffoldMessenger.of(context);
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (inner) => OnionQrScreen(
        onionAddress: onionAddress,
        onCopy: () => unawaited(() async {
          await Clipboard.setData(ClipboardData(text: onionAddress));
          messenger.showSnackBar(
            const SnackBar(content: Text('Your .onion address copied.')),
          );
        }()),
        onBack: () => Navigator.of(inner).maybePop(),
      ),
    ),
  );
}

/// Opens the settings screen.
///
/// [recorder] is handed down so the microphone picker can be reached from here.
/// The recorder is owned by the shell, and the settings route is pushed from it,
/// so passing it explicitly is what keeps one owner for one object rather than
/// parking it on the controller.
Future<void> openSettings(
  BuildContext context,
  AppController controller, {
  VoiceRecorder? recorder,
}) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AppScope(
        controller: controller,
        child: _SettingsRoute(recorder: recorder),
      ),
    ),
  );
}

/// Wires the settings screen to the controller, and the screens it opens.
///
/// The controller is read through `AppScope.of` in [build] rather than taken as
/// a constructor field, and that is what makes the switches work. `AppScope` is
/// an `InheritedNotifier`: it rebuilds the widgets that *depend* on it, and a
/// widget holding the controller in a field depends on nothing. So a toggle
/// wrote the new value, the controller notified, nobody rebuilt, and the switch
/// sprang back to where it had been — every switch on the screen, including the
/// ones on the screens it opens.
class _SettingsRoute extends StatelessWidget {
  const _SettingsRoute({this.recorder});

  /// Used by the microphone picker. Null when settings were opened from a place
  /// that has no recorder, in which case the row is not offered rather than
  /// opening a screen that cannot apply anything.
  final VoiceRecorder? recorder;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final tor = controller.tor;
    return SettingsScreen(
      version: kAppVersion,
      torStatusLabel: tor?.status.label ?? 'Not started',
      torStatusIsGood: tor?.status.isConnected ?? false,
      bridgeModeLabel: controller.settings.torSettings.mode.label,
      relayEnabled: controller.settings.relayPolicy.enabled,
      onRelayChanged: (enabled) => unawaited(
        controller.applyRelayPolicy(controller.settings.relayPolicy.copyWith(enabled: enabled)),
      ),
      notificationsEnabled: controller.settings.notificationsEnabled,
      notificationsSupported: NotificationService.isSupported,
      onNotificationsChanged: (value) => unawaited(controller.setNotificationsEnabled(value)),
      onOpenProfile: () => unawaited(openMyProfile(context, controller)),
      onOpenTorConnection: () => unawaited(openTorConnection(context, controller)),
      onOpenTorBridges: () => unawaited(_openBridgeSettings(context, controller)),
      onOpenRelaySettings: () => unawaited(openRelaySettings(context, controller)),
      onOpenSecurity: () => unawaited(openSecurity(context, controller)),
      onOpenProtectedFiles: () => unawaited(openProtectedFiles(context, controller)),
      onOpenAbout: () => unawaited(openAbout(context, controller)),
      onExportDiagnostics: () => unawaited(exportDiagnostics(context, controller)),
      // Only offered where a choice exists. On a platform that routes the
      // microphone itself the row would open an empty screen, which reads as a
      // bug rather than as "there is nothing to configure here".
      onOpenMicrophone: supportsMicrophoneChoice && recorder != null
          ? () => unawaited(openMicrophonePicker(context, controller, recorder!))
          : null,
      microphoneLabel: controller.settings.microphoneId == null
          ? 'System default'
          : 'Custom device',
      onLock: () => unawaited(controller.lock()),
      onBack: () => Navigator.of(context).maybePop(),
    );
  }
}

/// True when this platform lets the user choose an input device.
///
/// Windows does, and it is where the choice matters most: it exposes every input —
/// a laptop's array, a headset, a virtual cable — and the system's preference is
/// regularly the wrong one, which a user experiences as the microphone not
/// working. Android and iOS route the input through their own policy, Linux and
/// macOS enumerate inconsistently, so the row is not offered there.
bool get supportsMicrophoneChoice => Platform.isWindows;

/// Opens the microphone picker and applies whatever it returns.
///
/// The choice is applied to the recorder as well as stored in the settings, which
/// is the part that has to happen here rather than in the account layer: the
/// recorder is owned by the shell, and the account layer has no business reaching
/// into it.
Future<void> openMicrophonePicker(
  BuildContext context,
  AppController controller,
  VoiceRecorder recorder,
) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext inner) => MicrophoneScreen(
        selectedId: controller.settings.microphoneId,
        listDevices: () async {
          final devices = await recorder.microphones();
          return <MicrophoneOption>[
            for (final device in devices)
              MicrophoneOption(
                id: device.id,
                label: device.label.isEmpty ? device.id : device.label,
              ),
          ];
        },
        onSelected: (String? id) {
          // Both, in this order: the store is durable and the recorder is what the
          // next recording actually uses.
          recorder.microphoneId = id;
          unawaited(controller.setMicrophone(id));
        },
        onBack: () => Navigator.of(inner).maybePop(),
      ),
    ),
  );
}

/// Opens the conversation a tapped alert pointed at.
///
/// The recorder is passed in rather than fetched: it belongs to the shell, and this
/// is a top-level function with no access to it.
///
/// The address is checked against the contact list rather than trusted: a
/// notification payload is data that outlived the process that wrote it, and opening
/// an arbitrary address from it would put a stranger's thread on screen.
Future<void> _openFromAlert(
  BuildContext context,
  AppController controller,
  VoiceRecorder recorder,
  String onion,
) async {
  if (controller.contactFor(onion) == null) return;
  // Cleared from the platform's tray too: leaving it there would let the user tap it
  // again and land on a conversation they have already opened.
  await controller.dismissAlert(onion);
  if (!controller.isUnlocked || !context.mounted) return;

  // ## Why this route has its own playback state
  //
  // A tapped alert opens a conversation through the root navigator, so it is not a child of the shell
  // that owns the shared `PlaybackController` — nothing in this call can reach it. Creating one here
  // means a note played in this route reports through a notifier this route listens to, which is what
  // makes the button work here at all.
  //
  // The cost, stated rather than hidden: a note started in this route is not shown as playing in the
  // main conversation list, and vice versa. Those are two different screens and only one is on top.
  //
  // Disposal is the route's, and it needs none: nothing outside the route holds a reference, and the
  // listener the route adds goes with the route's own element tree.
  final playback = PlaybackController();
  await openConversation(
    context,
    controller,
    onion,
    recorder,
    playback,
    // Wired to the controller, rather than ignored. The route used to be handed a callback that did
    // nothing, which is the same shape as the fault this whole line of work is about: playback state
    // that never reaches the screen.
    (String? id, double progress) => playback.set(id, progress),
  );
}

/// Opens the Tor connection screen outside of onboarding.
Future<void> openTorConnection(BuildContext context, AppController controller) async {
  final tor = controller.tor;
  if (tor == null) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AppScope(
        controller: controller,
        child: const _TorRoute(),
      ),
    ),
  );
}

/// The Tor screen when it is opened from settings rather than from the gate.
///
/// Reads the controller from [AppScope], for the same reason [SettingsRoute]
/// does: the progress bar and the bridge summary have to follow the daemon, and
/// a field-held controller subscribes to nothing.
class _TorRoute extends StatelessWidget {
  const _TorRoute();

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final tor = controller.tor!;
    return TorConnectionScreen(
      progress: tor.status.progress,
      connected: tor.status.isConnected,
      subtitle: tor.status.summary.isEmpty ? null : tor.status.summary,
      errorText: tor.status.error,
      backendName: controller.engine.backendName,
      socksPort: tor.status.socksPort,
      bridgeSummary: _bridgeSummary(controller),
      steps: const <BootstrapStep>[
        BootstrapStep(label: 'Initializing connection…'),
        BootstrapStep(label: 'Connecting to bridge…'),
        BootstrapStep(label: 'Establishing secure circuit…'),
        BootstrapStep(label: 'Connection established!'),
      ],
      onOpenBridgeSettings: () => unawaited(_openBridgeSettings(context, controller)),
      onRetry: () => unawaited(controller.restartTor()),
      onNext: () => Navigator.of(context).maybePop(),
      onBack: () => Navigator.of(context).maybePop(),
    );
  }
}

/// Opens the relay and mailbox settings.
Future<void> openRelaySettings(BuildContext context, AppController controller) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AppScope(
        controller: controller,
        // Rebuilt from a scope dependency, so a switch stays where it was put.
        //
        // Constructing the screen once with `policy:` as a value meant the
        // controller persisted the change, notified, and nothing listened: the
        // screen was never rebuilt and both switches visibly sprang back.
        child: Builder(
          builder: (live) {
            final liveController = AppScope.of(live);
            final mesh = liveController.mesh;
            return RelaySettingsScreen(
              policy: liveController.settings.relayPolicy,
              usedBytes: mesh?.mailboxBytes ?? 0,
              usedEnvelopes: mesh?.mailboxSize ?? 0,
              onChanged: (policy) => unawaited(liveController.applyRelayPolicy(policy)),
              onBack: () => Navigator.of(context).maybePop(),
            );
          },
        ),
      ),
    ),
  );
}

/// Opens the security screen.
Future<void> openSecurity(BuildContext context, AppController controller) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AppScope(
        controller: controller,
        child: SecurityScreen(
          cryptoBackend: controller.engine.backendName,
          onChangePassword: () => unawaited(_changePassword(context, controller)),
          onLock: () => unawaited(controller.lock()),
          onBack: () => Navigator.of(context).maybePop(),
        ),
      ),
    ),
  );
}

Future<void> _changePassword(BuildContext context, AppController controller) async {
  final chosen = await Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      builder: (_) => PasswordSetupScreen(
        title: 'New password',
        subtitle: 'Everything already stored stays readable: the master key is '
            're-wrapped, not re-derived.',
        onSubmit: (password) async => Navigator.of(context).pop(password),
        onBack: () => Navigator.of(context).maybePop(),
      ),
    ),
  );
  if (chosen == null) return;
  await controller.changePassword(chosen);
}

/// Opens the protected-files vault.
///
/// The screen is a live view over the controller's `protected` collection, which
/// is what it never was before: it was handed an empty list and three callbacks
/// that did nothing, so "Protected files" could not add anything it would then
/// show, could not open anything, and could not remove anything. Everything below
/// is wired to real vault operations.
Future<void> openProtectedFiles(BuildContext context, AppController controller) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AppScope(
        controller: controller,
        // Rebuilt on every notification, because adding a file, removing one and
        // saving a copy all change what the list has to show.
        child: AnimatedBuilder(
          animation: controller,
          builder: (BuildContext live, Widget? _) => ProtectedFilesScreen(
            // The vault is open whenever this screen is reachable: reaching it
            // requires an unlocked account. The locked branch exists for a future
            // re-authentication and is left honest rather than faked.
            unlocked: controller.isUnlocked,
            files: <ProtectedFileEntry>[
              for (final file in controller.protectedFiles)
                ProtectedFileEntry(
                  id: file.id,
                  fileName: file.fileName,
                  sizeBytes: file.sizeBytes,
                  addedAt: file.addedAt,
                  mimeType: file.mimeType,
                  savedTo: file.savedTo,
                ),
            ],
            totalBytes: controller.protectedBytes,
            onUnlock: () {},
            onAddFiles: () => unawaited(
              _protectFileFromPicker(live, controller),
            ),
            onOpen: (ProtectedFileEntry entry) => unawaited(
              _openProtected(live, controller, entry),
            ),
            onExport: (ProtectedFileEntry entry) => unawaited(
              _saveProtectedForever(live, controller, entry),
            ),
            onRemove: (ProtectedFileEntry entry) => unawaited(
              _removeProtected(live, controller, entry),
            ),
            onBack: () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
    ),
  );
}

/// Seals a chosen file into the vault.
Future<void> _protectFileFromPicker(
  BuildContext context,
  AppController controller,
) async {
  final picked = await _withAutoLockSuspended(
    controller,
    () => FilePicker.pickFile(dialogTitle: 'Protect a file'),
  );
  final path = picked?.path;
  if (path == null) return;

  final protected = await controller.protectFile(File(path));
  // Sealing a large file takes as long as pure-Dart AES-GCM takes, which is long
  // enough for the screen to have gone.
  if (!context.mounted) return;
  _reportToUser(
    context,
    protected == null
        ? 'That file could not be protected.'
        : '“${protected.fileName}” is encrypted in the vault.',
  );
}

/// Decrypts a sealed file and hands it to another application, after asking.
Future<void> _openProtected(
  BuildContext context,
  AppController controller,
  ProtectedFileEntry entry,
) async {
  final file = controller.protectedFiles
      .where((ProtectedFile candidate) => candidate.id == entry.id)
      .firstOrNull;
  if (file == null) {
    _reportToUser(context, 'That file is no longer in the vault.');
    return;
  }

  // Asked before anything is decrypted: the decision is about handing the
  // plaintext to another program, so the plaintext must not exist yet.
  final agreed = await confirmOpenFile(context, file: file);
  if (!agreed) return;
  // The dialog is a gap, and the route behind it may have been popped.
  if (!context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  try {
    final materialised = await controller.materialiseProtected(entry.id);
    if (materialised == null) {
      // Reported through the messenger captured above rather than the context:
      // decryption is a gap, and reaching for the context again afterwards is the
      // mistake the analyzer is pointing at.
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('That file could not be decrypted.')),
        );
      return;
    }
    final failure = await FileOpener.open(materialised);
    if (failure != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(failure)));
    }
  } on Object catch (error) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Could not open that file: $error')));
  }
}

/// Writes a decrypted copy where the user chooses, so it outlives the vault.
///
/// This is the "save forever" action. The distinction matters: the decrypted copy
/// that `open` produces lives in the cache directory, which is wiped on every
/// lock, so a file the user wants to keep has to be written somewhere else — and
/// choosing where is the user's decision, not the application's.
Future<void> _saveProtectedForever(
  BuildContext context,
  AppController controller,
  ProtectedFileEntry entry,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final target = await _withAutoLockSuspended(
      controller,
      () => FilePicker.saveFile(
        dialogTitle: 'Save a decrypted copy',
        fileName: entry.fileName,
        bytes: Uint8List(0),
        mimeType: entry.mimeType,
      ),
    );
    if (target == null) return;

    final saved = await controller.exportProtectedFile(entry.id, File(target.path));
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            saved == null
                ? 'That file could not be saved.'
                : 'Saved to ${saved.path}. The copy is no longer encrypted, so '
                    'DarkFlow cannot protect it any more.',
          ),
        ),
      );
  } on Object catch (error) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Could not save that file: $error')));
  }
}

/// Removes a file from the vault, after asking.
Future<void> _removeProtected(
  BuildContext context,
  AppController controller,
  ProtectedFileEntry entry,
) async {
  final agreed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialog) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Delete this file?'),
      content: Text(
        '“${entry.fileName}” will be removed from the vault and its encrypted copy '
        'deleted. Any copy you saved elsewhere is unaffected.',
        style: AppTypography.secondary,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (agreed != true) return;
  if (!context.mounted) return;

  final removed = await controller.unprotectFile(entry.id);
  if (!context.mounted) return;
  _reportToUser(
    context,
    removed ? '“${entry.fileName}” was removed.' : 'That file was already gone.',
  );
}

/// Opens the about screen.
///
/// The version strings come from `--dart-define` rather than from constants (see
/// [kAppVersion]), so a release names itself consistently and a development build
/// admits what it is instead of claiming a version number.
Future<void> openAbout(BuildContext context, AppController controller) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (inner) => AboutScreen(
        version: kAppVersion,
        buildNumber: kBuildNumber,
        isRelease: kIsReleaseBuild,
        onBack: () => Navigator.of(inner).maybePop(),
      ),
    ),
  );
}

/// Writes the diagnostic report where the user chooses, then says where it went.
///
/// The file is produced here rather than shown in a dialog first, because the
/// point of it is to be attached to a bug report — and because a report rendered
/// into a scrollable box is one the user cannot check before sending.
///
/// Nothing is uploaded and nothing is sent: the application has no server to send
/// it to. The user decides who sees it.
Future<void> exportDiagnostics(BuildContext context, AppController controller) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final bytes = Uint8List.fromList(DiagnosticsReport.encode(controller));
    final target = await _withAutoLockSuspended(
      controller,
      () => FilePicker.saveFile(
        dialogTitle: 'Save the diagnostic report',
        fileName: DiagnosticsReport.suggestedFileName(),
        bytes: bytes,
        mimeType: 'text/plain',
      ),
    );
    if (target == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Diagnostic report saved to ${target.path}. It contains no messages, '
            'contact names or onion addresses — read it before sharing it.',
          ),
        ),
      );
  } on Object catch (error) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Could not write the report: $error')));
  }
}

/// Opens a contact's profile.
///
/// Everything about the contact is re-read from the account layer on every
/// notification, because forgetting a contact, blocking one or renaming one all
/// change what this screen has to show, and the route is built once. What the
/// screen owns is only the name it is currently rendering, which [onManage] keeps
/// in step after a rename it applied itself.
Future<void> openContactProfile(
  BuildContext context,
  AppController controller,
  String peerOnion,
) async {
  if (controller.contactFor(peerOnion) == null) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (routeContext) => AppScope(
        controller: controller,
        child: AnimatedBuilder(
          animation: controller,
          builder: (BuildContext context, Widget? _) {
            final contact = controller.contactFor(peerOnion);
            // The contact has gone, so this route has nothing left to show. It used to
            // return an empty scaffold, which is a black screen: the profile is a pushed
            // route, and nothing was taking it off the stack. The user was left staring
            // at a blank page with no way to tell whether the delete had worked or the
            // app had crashed.
            //
            // The pop is scheduled rather than called here because this runs inside a
            // build, and mutating the navigator during one throws. `addPostFrameCallback`
            // lets the frame finish first, after which the route leaves as it should and
            // the screen underneath — the chat, or the conversation list — is revealed.
            if (contact == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (routeContext.mounted) {
                  Navigator.of(routeContext).maybePop();
                }
              });
              return const AppScaffold(child: SizedBox.shrink());
            }
            return ContactProfileScreen(
              displayName: contact.displayName,
              about: contact.about,
              onionAddress: contact.onionAddress,
              avatarPath: contact.avatarPath,
              lastSeenAt: contact.lastSeenAt,
              trust: contact.trust,
              blocked: contact.blocked,
              notificationsEnabled: contact.notificationsEnabled,
              online: controller.canReach(peerOnion),
              messageCount: controller.messagesFor(peerOnion).length,
              onCopyOnion: () => unawaited(
                Clipboard.setData(ClipboardData(text: contact.onionAddress)),
              ),
              onShowQr: () => unawaited(openQr(routeContext, contact.onionAddress)),
              onToggleBlock: () => unawaited(
                controller.setBlocked(peerOnion, !contact.blocked),
              ),
              onToggleNotifications: () => unawaited(
                controller.setNotifications(peerOnion, !contact.notificationsEnabled),
              ),
              onManage: (void Function(String displayName) onRenamed) => unawaited(
                _manageContact(
                  routeContext,
                  controller,
                  peerOnion,
                  onRenamed: onRenamed,
                ),
              ),
              onOpenChat: () => Navigator.of(routeContext).maybePop(),
              onBack: () => Navigator.of(routeContext).maybePop(),
            );
          },
        ),
      ),
    ),
  );
}

/// Opens the rename / clear / delete sheet for [peerOnion].
///
/// The sheet does not touch the account layer itself: it reports what the user
/// chose, and this function is the one place that turns those choices into
/// controller calls, so the wording of a warning and the write it authorises stay
/// side by side.
Future<void> _manageContact(
  BuildContext context,
  AppController controller,
  String peerOnion, {
  required void Function(String displayName) onRenamed,
}) async {
  final contact = controller.contactFor(peerOnion);
  if (contact == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final name = contact.displayName;

  await ContactActionsSheet.show(
    context,
    displayName: name,
    // Only what is loaded: a thread that has never been opened has no counts to
    // show, and "Clear chat history" is offered from the profile the user just
    // came through, where the history is loaded.
    messageCount: controller.messagesFor(peerOnion).length,
    onRename: (String displayName) => controller.renameContact(peerOnion, displayName),
    onClearHistory: () => unawaited(controller.clearConversation(peerOnion)),
    onDelete: () async {
      await controller.deleteContact(peerOnion);
      // Off the contact's own screen before it can be read again, and a line on
      // the way out, because a delete that the contact's conversation list also
      // reflects is otherwise indistinguishable from the app losing its place.
      //
      // Only the sheet is popped here. The profile route used to be popped too, and
      // that was the bug: an `AnimatedBuilder` on the profile rebuilds the moment the
      // contact disappears, and it popped the same route a second time — which took the
      // *conversation list* off the stack as well and left a black screen. The profile
      // now pops itself when it finds the contact gone, so the delete happens once.
      messenger.showSnackBar(
        SnackBar(content: Text('$name was deleted from this device.')),
      );
    },
  );
  // Only a rename can have changed the name, and the screen has to be told: it
  // was built with the values the app layer had at the time and a notification
  // never reaches a pushed route. The call is a no-op for every other outcome,
  // including the delete, which has already left this route.
  onRenamed(controller.contactFor(peerOnion)?.displayName ?? name);
}

/// Opens a contact's profile from a conversation's app bar.
///
/// Kept as a named entry point because the top bar is the one place a phone and a
/// two-pane window both offer it.
Future<void> openContactProfileFromChat(
  BuildContext context,
  AppController controller,
  String peerOnion,
) =>
    openContactProfile(context, controller, peerOnion);

/// The contact trust helper used by the profile screen's badge.
ContactTrust trustFor(AppController controller, String peerOnion) =>
    controller.contactFor(peerOnion)?.trust ?? ContactTrust.unverified;
