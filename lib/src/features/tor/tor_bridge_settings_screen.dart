import 'package:flutter/material.dart';

import '../../data/models/tor_settings.dart';
import '../../design/design.dart';
import '../../tor/bridge_line.dart';
import 'widgets/bridge_preset_grid.dart';

/// The bridge configuration screen: pick a preset, or paste `Bridge …` lines.
///
/// Stateful only because the manual box and the selected preset are edited
/// locally before [onApply] commits them; nothing is persisted here.
class TorBridgeSettingsScreen extends StatefulWidget {
  const TorBridgeSettingsScreen({
    required this.presets,
    required this.selectedMode,
    required this.initialBridges,
    required this.onApply,
    this.onBack,
    this.showBackAffordance = true,
    this.fetching = false,
    this.onFetchBridges,
    this.errorText,
    super.key,
  });

  /// The presets to offer. Supplied by the caller so a fetched list can replace
  /// the built-in one without touching this screen.
  final List<BridgePreset> presets;

  /// The mode currently in force, used to highlight a preset.
  final BridgeMode selectedMode;

  /// The starting contents of the manual box, normally
  /// [TorSettings.customBridges].
  final String initialBridges;

  /// Called by "Next" with the chosen transport and the raw bridge lines. An
  /// empty string means "use whatever the preset carries".
  ///
  /// [onBack] is invoked immediately afterwards, so "Next" always means
  /// "commit this and leave". The screen has nothing left to show once the
  /// choice is made, and a visible button that appears to do nothing is worse
  /// than no button at all.
  final void Function(BridgeMode mode, String bridges) onApply;

  /// Leaves the screen. Called after [onApply], and also by the back affordance.
  /// No back affordance is drawn when null, but "Next" still applies.
  final VoidCallback? onBack;

  /// Whether the corner back arrow is drawn.
  ///
  /// False during first-run setup, where there is nothing behind this screen
  /// and an arrow that moves *forward* would be a lie about what it does.
  final bool showBackAffordance;

  /// True while a fresh preset list is in flight.
  final bool fetching;

  /// Refreshes the presets from the configured bridge source; hidden when null.
  final VoidCallback? onFetchBridges;

  /// A one-line failure from the last fetch, shown in the danger colour.
  final String? errorText;

  @override
  State<TorBridgeSettingsScreen> createState() => _TorBridgeSettingsScreenState();
}

class _TorBridgeSettingsScreenState extends State<TorBridgeSettingsScreen> {
  /// Presets, the grid and the manual box all share the 20 pt content inset.
  static const double _contentInset = 20;

  /// Seeded once from [TorBridgeSettingsScreen.initialBridges]. Later updates
  /// from the caller deliberately do not overwrite it, so a rebuild cannot
  /// erase what the user is typing.
  late final TextEditingController _bridges =
      TextEditingController(text: widget.initialBridges);

  /// The transport the "Next" button will apply. Initialised from the widget so
  /// the caller's current setting is the starting point.
  late BridgeMode _mode = widget.selectedMode;

  /// Why the box cannot be applied, or null when every line is usable.
  ///
  /// Recomputed on every edit rather than only on "Next", so the complaint appears next to
  /// the line while the user is looking at it instead of after they have left the screen.
  String? _problem;

  @override
  void initState() {
    super.initState();
    _bridges.addListener(_revalidate);
    _revalidate();
  }

  /// Checks the box and reports the first line that cannot work.
  ///
  /// This is the guard against the failure that is otherwise invisible until it is fatal:
  /// a malformed bridge line does not degrade the connection, it stops Tor from starting
  /// at all, with "Reading config failed--see warnings above" as the only explanation. The
  /// daemon is the authority on whether a bridge is *reachable*; this only refuses a line
  /// that is certain to be rejected before it is ever written to `torrc`.
  void _revalidate() {
    final lines = _bridges.text
        .split('\n')
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList(growable: false);

    String? problem;
    for (final line in lines) {
      final why = bridgeLineProblem(line);
      if (why != null) {
        problem = why;
        break;
      }
    }

    if (problem == _problem) return;
    setState(() => _problem = problem);
  }

  @override
  void dispose() {
    _bridges.removeListener(_revalidate);
    _bridges.dispose();
    super.dispose();
  }

  /// Selecting a preset switches the transport.
  ///
  /// It must never wipe what the user typed, and that is a bug this method used
  /// to have: every shipped preset carries an empty `bridges` array — bridge
  /// addresses are rotated by the Tor Project and deliberately not baked into a
  /// release — so `preset.bridges.isEmpty` was true for all of them and tapping
  /// one blanked the box. The natural order of use is to paste the addresses
  /// *and then* pick the transport they belong to, so the paste was erased a
  /// moment after it was made. `torrc` then had no `Bridge` and no
  /// `ClientTransportPlugin`, `UseBridges` stayed 0, the app connected directly
  /// and stalled at 10% — with the user convinced the bridge was configured.
  ///
  /// A preset's own lines are still loaded when it actually has some.
  void _selectPreset(BridgePreset preset) {
    setState(() {
      _mode = preset.mode;
      if (preset.bridges.isNotEmpty) {
        _bridges.text = preset.asText;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      // "Next" commits the choice and then leaves. Doing only the first half
      // made the button look broken, which is exactly how it was reported.
      //
      // It refuses while a line cannot work. The alternative is to save it, let Tor fail
      // to start, and leave the user with a red "Reading config failed" and no idea which
      // of their lines caused it — which is what happened, and why the account had to be
      // recreated to recover.
      bottomBar: _ApplyBar(
        onPressed: _problem == null
            ? () {
                widget.onApply(_mode, _bridges.text);
                widget.onBack?.call();
              }
            : null,
      ),
      child: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          child: CenteredContent(
            maxWidth: AppMetrics.maxContentWidth * 2,
            padding: EdgeInsets.zero,
            child: Stack(
              children: <Widget>[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Padding(
                      padding: EdgeInsets.only(top: 24),
                      child: ScreenTitle(
                        'Tor Bridge Settings',
                        style: AppTypography.h2,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(32, 10, 32, 0),
                      child: Text(
                        'Configure Tor bridges for better privacy and censorship circumvention',
                        textAlign: TextAlign.center,
                        style: AppTypography.secondary,
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(_contentInset, 30, _contentInset, 0),
                      child: SectionHeader('Presets'),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(_contentInset, 12, _contentInset, 0),
                      child: BridgePresetGrid(
                        presets: widget.presets,
                        selectedMode: _mode,
                        enabled: !widget.fetching,
                        onSelected: _selectPreset,
                      ),
                    ),
                    if (widget.fetching || widget.onFetchBridges != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(_contentInset, 12, _contentInset, 0),
                        child: _FetchRow(
                          fetching: widget.fetching,
                          onFetchBridges: widget.onFetchBridges,
                        ),
                      ),
                    if (widget.errorText != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(_contentInset, 12, _contentInset, 0),
                        child: Text(
                          widget.errorText!,
                          style: AppTypography.caption.copyWith(color: AppColors.danger),
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(_contentInset, 24, _contentInset, 0),
                      child: SectionHeader('Manual Configuration'),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(_contentInset, 12, _contentInset, 0),
                      child: _BridgeTextArea(
                        controller: _bridges,
                        hint: 'Enter proxy here',
                      ),
                    ),
                    if (_problem != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(_contentInset, 12, _contentInset, 0),
                        child: Text(
                          'This bridge line cannot be used, so it will not be saved. '
                          '$_problem',
                          style: AppTypography.caption.copyWith(color: AppColors.danger),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(_contentInset, 10, _contentInset, 24),
                      child: Text(
                        'These lines are applied with UseBridges 1. Leave the box '
                        "empty to use the selected preset's own bridges.",
                        style: AppTypography.caption,
                      ),
                    ),
                  ],
                ),
                if (widget.onBack != null && widget.showBackAffordance)
                  Positioned(
                    top: 4,
                    left: 4,
                    child: IconButton(
                      onPressed: widget.onBack,
                      icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                      color: AppColors.textPrimary,
                      tooltip: 'Back',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The pinned "Next" action.
///
/// A null [onPressed] disables it — the button is inert while a bridge line cannot work, so
/// the choice cannot be committed into a configuration that stops the daemon from starting.
/// "Direct" with an empty box stays valid and always enabled.
class _ApplyBar extends StatelessWidget {
  const _ApplyBar({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppMetrics.controlInset, 8, AppMetrics.controlInset, 16),
        child: PrimaryButton(label: 'Next', onPressed: onPressed),
      ),
    );
  }
}

/// The bridge fresh-list control: a spinner while fetching, a secondary button
/// otherwise. Drawn only when the caller can actually fetch.
class _FetchRow extends StatelessWidget {
  const _FetchRow({required this.fetching, required this.onFetchBridges});

  final bool fetching;
  final VoidCallback? onFetchBridges;

  @override
  Widget build(BuildContext context) {
    if (fetching) {
      return Row(
        children: <Widget>[
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
          ),
          const SizedBox(width: 10),
          Text('Fetching bridges…', style: AppTypography.secondary),
        ],
      );
    }
    if (onFetchBridges == null) return const SizedBox.shrink();
    return SecondaryButton(
      label: 'Fetch fresh bridges',
      height: AppMetrics.listTileHeight,
      onPressed: onFetchBridges,
    );
  }
}

/// The tall manual-configuration box.
///
/// Built here rather than with `AppTextField` because the design fixes its
/// height at 464 pt and gives its content the monospaced face; `AppTextField`
/// sizes itself to its content and only ever draws the body face. Focus is
/// signalled the same way as everywhere else: a 1.5 pt accent outline.
class _BridgeTextArea extends StatefulWidget {
  const _BridgeTextArea({required this.controller, required this.hint});

  final TextEditingController controller;
  final String hint;

  @override
  State<_BridgeTextArea> createState() => _BridgeTextAreaState();
}

class _BridgeTextAreaState extends State<_BridgeTextArea> {
  final FocusNode _focusNode = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) setState(() => _focused = _focusNode.hasFocus);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      height: AppMetrics.bridgeTextAreaHeight,
      padding: const EdgeInsets.symmetric(
        horizontal: AppMetrics.fieldTextPadding - 1.5,
        vertical: 12,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppMetrics.fieldRadius),
        border: Border.all(
          color: _focused ? AppColors.fieldBorderFocused : AppColors.fieldBorder,
          width: 1.5,
        ),
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        expands: true,
        maxLines: null,
        minLines: null,
        keyboardType: TextInputType.multiline,
        textAlignVertical: TextAlignVertical.top,
        cursorColor: AppColors.accent,
        style: AppTypography.mono,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: widget.hint,
          hintStyle: AppTypography.placeholder,
        ),
      ),
    );
  }
}
