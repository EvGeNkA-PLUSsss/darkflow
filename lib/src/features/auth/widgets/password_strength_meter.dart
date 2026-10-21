import 'package:flutter/material.dart';

import '../../../design/design.dart';

/// How good a candidate password is, on a four-point scale.
///
/// The meter is advisory and never blocks anything: the vault enforces its own
/// minimum length, so the caption's job is to say what would make the password
/// stronger rather than to scold. The scale stops at
/// [PasswordStrengthLevel.good] for the same reason — the top of it means
/// "nothing useful left to suggest", not "unbreakable".
enum PasswordStrengthLevel { empty, weak, fair, good }

/// The length the vault actually enforces (`KeyVault` refuses anything shorter).
///
/// It lives here, as the default for [PasswordStrength.of], because the meter used
/// to give its own advice against a hard-coded six: at six and seven characters it
/// said nothing at all — not "too short", just nothing — while the screen it sits
/// on refused to continue below eight. A user who typed seven strong characters
/// read no complaint and had no button, so the screen looked frozen, and the only
/// way to learn the real rule was to press Enter and hope.
const int kMinimumPasswordLength = 8;

/// The strength of one candidate password, with the reason for the verdict.
///
/// [hint] exists so the widget never has to invent advice at the last moment:
/// the scoring function knows *why* a password scored what it did, and that
/// reason is what the user needs to read.
class PasswordStrength {
  const PasswordStrength({
    required this.level,
    required this.fraction,
    required this.hint,
  });

  final PasswordStrengthLevel level;

  /// Filled portion of the meter, `0.0`-`1.0`.
  final double fraction;

  /// One short sentence telling the user what would raise the score.
  final String hint;

  /// True when there is nothing to show and the meter should not be drawn.
  bool get isEmpty => level == PasswordStrengthLevel.empty;

  /// Scores [password] without ever looking at the password itself again.
  ///
  /// The rules are deliberately readable rather than clever: a length baseline
  /// lifted by character variety. A score that depended on a dictionary or an
  /// entropy estimate would need a service or a bundled word list, and this
  /// widget has to run offline on the phone with no dependencies.
  ///
  /// [minimumLength] is the floor the *screen* enforces, so the caption can name
  /// the real number instead of a different one.
  static PasswordStrength of(
    String password, {
    int minimumLength = kMinimumPasswordLength,
  }) {
    final tooShort = 'Use at least $minimumLength characters.';
    if (password.isEmpty) {
      return PasswordStrength(
        level: PasswordStrengthLevel.empty,
        fraction: 0,
        hint: tooShort,
      );
    }

    final length = password.length;
    final variety = _variety(password);

    var score = 0;
    if (length >= minimumLength) score++;
    if (length >= 10) score++;
    if (length >= 14) score++;
    if (variety >= 2) score++;
    if (variety >= 3) score++;

    // A variety bonus alone must not promote a password that is under the floor.
    if (length < minimumLength && score > 1) score = 1;

    if (score >= 4) {
      return const PasswordStrength(
        level: PasswordStrengthLevel.good,
        fraction: 1,
        hint: 'Strong password.',
      );
    }
    if (score >= 2) {
      return PasswordStrength(
        level: PasswordStrengthLevel.fair,
        fraction: score >= 3 ? 0.75 : 0.5,
        hint: variety >= 3
            ? 'Longer would be stronger.'
            : 'Add digits or symbols for a stronger password.',
      );
    }
    return PasswordStrength(
      level: PasswordStrengthLevel.weak,
      fraction: 0.25,
      hint: length < minimumLength ? tooShort : 'Mix letters, digits and symbols.',
    );
  }

  /// Counts how many of the four character classes appear in [password].
  static int _variety(String password) {
    var classes = 0;
    if (_lower.hasMatch(password)) classes++;
    if (_upper.hasMatch(password)) classes++;
    if (_digit.hasMatch(password)) classes++;
    if (_symbol.hasMatch(password)) classes++;
    return classes;
  }

  static final RegExp _lower = RegExp('[a-z]');
  static final RegExp _upper = RegExp('[A-Z]');
  static final RegExp _digit = RegExp('[0-9]');
  static final RegExp _symbol = RegExp(r'[^a-zA-Z0-9]');
}

/// A thin feedback bar for a password being typed.
///
/// The mockups have no such element, so it follows the language they do have: a
/// 4 pt fully-rounded track in `#3A3A3A` with an accent fill, exactly the shape
/// of the Tor bootstrap bar in [AppProgressBar], plus a caption line. It is kept
/// subtle on purpose — on the sign-in screen it is advisory, never an error, so
/// it never uses [AppColors.danger] and never moves the layout (its caption has
/// a reserved height even while empty).
///
/// When [trailing] is supplied the caption doubles as the affordance that
/// reveals the typed password, which is the only way to check a long passphrase
/// on a phone keyboard.
class PasswordStrengthMeter extends StatelessWidget {
  const PasswordStrengthMeter({
    required this.password,
    this.caption,
    this.semanticLabel,
    this.trailing,
    this.minimumLength = kMinimumPasswordLength,
    super.key,
  });

  /// The current field contents. The widget scores them itself, so callers do
  /// not have to keep a derived value in their own state.
  final String password;

  /// The floor this screen enforces, so the default caption names the same number
  /// the submit button does.
  final int minimumLength;

  /// Overrides the scoring hint with caller-supplied copy.
  final String? caption;

  /// Announced to screen readers, which cannot perceive a 4 pt bar.
  final String? semanticLabel;

  /// Optional widget rendered at the end of the caption line.
  final Widget? trailing;

  /// Height reserved for the caption line whenever the meter is visible, so the
  /// controls below it do not jump between the empty and filled states.
  static const double captionReservedHeight = 16;

  @override
  Widget build(BuildContext context) {
    final strength = PasswordStrength.of(password, minimumLength: minimumLength);
    final captionText = caption ?? strength.hint;

    return Semantics(
      label: semanticLabel ?? 'Password strength',
      value: _levelLabel(strength.level),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 4,
              child: Stack(
                children: [
                  const ColoredBox(color: AppColors.surfaceHigh),
                  FractionallySizedBox(
                    widthFactor: strength.fraction.clamp(0.0, 1.0),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      decoration: const BoxDecoration(color: AppColors.accent),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            height: captionReservedHeight,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    captionText,
                    style: AppTypography.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The wording behind the bar, kept next to the widget that shows it so the
  /// visible copy and the announcement cannot drift apart.
  static String _levelLabel(PasswordStrengthLevel level) {
    switch (level) {
      case PasswordStrengthLevel.empty:
        return 'No password yet';
      case PasswordStrengthLevel.weak:
        return 'Weak';
      case PasswordStrengthLevel.fair:
        return 'Fair';
      case PasswordStrengthLevel.good:
        return 'Strong';
    }
  }
}
