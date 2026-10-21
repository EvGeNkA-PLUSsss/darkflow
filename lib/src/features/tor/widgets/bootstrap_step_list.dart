import 'package:flutter/material.dart';

import '../../../design/design.dart';

/// How far a single Tor bootstrap step has got.
///
/// Tor's control port reports progress as a coarse percentage, so this is the
/// smallest set of states that still lets the transcript read honestly: phases
/// that have not started, the one in flight, the ones that succeeded, and the
/// one that failed. Anything richer would be invented rather than observed.
enum BootstrapStepState {
  /// Not reached yet — the daemon has not reported this phase.
  pending,

  /// In flight; the dot and the label light up in the accent colour.
  active,

  /// Finished successfully.
  done,

  /// Abandoned. [BootstrapStep.reason] says why.
  failed,
}

/// One line of the bootstrap transcript.
///
/// Kept as a plain value object so the screen that renders it stays
/// presentational: the Tor manager owns the state machine and hands over a list.
@immutable
class BootstrapStep {
  const BootstrapStep({
    required this.label,
    this.state = BootstrapStepState.pending,
    this.reason,
  });

  /// The phase in plain words, e.g. `'Connecting to bridge…'`.
  final String label;

  /// Where the phase currently stands.
  final BootstrapStepState state;

  /// A one-line explanation rendered under a [BootstrapStepState.failed] step,
  /// e.g. `'Bridge refused the connection.'`. Ignored for other states.
  final String? reason;
}

/// The vertical run of bootstrap steps on the Tor connection screen.
///
/// The mockup measures: a 9 pt dot at x = 22, its label 10 pt to the right, and
/// 30 pt between rows. The dot sits on the row's vertical centre so it lines up
/// with the text's optical centre rather than its top.
class BootstrapStepList extends StatelessWidget {
  const BootstrapStepList({required this.steps, super.key});

  /// The transcript, top to bottom.
  final List<BootstrapStep> steps;

  /// The mockup places the dots 22 pt from the canvas edge.
  static const double _dotInset = 22;

  /// Distance between a dot's right edge and its label.
  static const double _labelGap = 10;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final step in steps) _StepRow(step: step),
      ],
    );
  }
}

/// A single transcript row: dot, label, and an optional failure reason.
class _StepRow extends StatelessWidget {
  const _StepRow({required this.step});

  final BootstrapStep step;

  /// The label colour carries the state, so a glance is enough to find the
  /// active phase and any failure.
  TextStyle get _labelStyle => switch (step.state) {
        BootstrapStepState.pending =>
          AppTypography.body.copyWith(color: AppColors.textSecondary),
        BootstrapStepState.active => AppTypography.body.copyWith(color: AppColors.accent),
        BootstrapStepState.done => AppTypography.body.copyWith(color: AppColors.textPrimary),
        BootstrapStepState.failed => AppTypography.body.copyWith(color: AppColors.danger),
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: BootstrapStepList._dotInset),
          child: SizedBox(
            height: AppMetrics.progressStepSpacing,
            child: Row(
              children: <Widget>[
                _StepDot(state: step.state),
                const SizedBox(width: BootstrapStepList._labelGap),
                Expanded(
                  child: Text(
                    step.label,
                    style: _labelStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (step.reason != null)
          Padding(
            padding: const EdgeInsets.only(
              left: BootstrapStepList._dotInset +
                  AppMetrics.progressDotSize +
                  BootstrapStepList._labelGap,
              bottom: 6,
            ),
            child: Text(
              step.reason!,
              style: AppTypography.caption.copyWith(color: AppColors.danger),
            ),
          ),
      ],
    );
  }
}

/// The 9 pt marker. Pending steps are grey, running and finished steps are
/// accent-coloured, failures are red — a failure must not look like progress.
class _StepDot extends StatelessWidget {
  const _StepDot({required this.state});

  final BootstrapStepState state;

  @override
  Widget build(BuildContext context) {
    if (state == BootstrapStepState.failed) {
      // `StatusDot` only knows "accent or grey", so the failure colour is drawn
      // directly at exactly the same size.
      return Container(
        width: AppMetrics.progressDotSize,
        height: AppMetrics.progressDotSize,
        decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
      );
    }
    return StatusDot(
      active: state == BootstrapStepState.active || state == BootstrapStepState.done,
    );
  }
}
