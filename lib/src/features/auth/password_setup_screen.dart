import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/design.dart';
import 'auth_scaffold.dart';
import 'widgets/auth_error_line.dart';
import 'widgets/password_strength_meter.dart';

/// The step between "who are you" and the finished account.
///
/// The mockups show a six-digit code but no long password, yet the architecture
/// the note describes needs one: the account password is what Argon2id stretches
/// into the key that wraps the master key, and it is the only secret standing
/// between a stolen vault file and its contents. Six digits alone would be a
/// million possibilities — trivial to exhaust — so this screen collects the
/// secret that carries the real weight.
///
/// It deliberately uses the same geometry as the surrounding auth screens: a
/// 28 pt centred title, 56 pt fields with 12 pt radii, 20 pt gaps, and the
/// primary action pinned to the same rhythm.
class PasswordSetupScreen extends StatefulWidget {
  const PasswordSetupScreen({
    required this.onSubmit,
    required this.onBack,
    this.title = 'Create password',
    this.subtitle = 'This password encrypts everything you send and store. '
        'It never leaves your device, and it cannot be recovered.',
    this.busy = false,
    this.errorText,
    super.key,
  });

  /// Called with the chosen password.
  final Future<void> Function(String password) onSubmit;

  /// Returns to the previous step.
  final VoidCallback onBack;

  final String title;
  final String subtitle;
  final bool busy;
  final String? errorText;

  @override
  State<PasswordSetupScreen> createState() => _PasswordSetupScreenState();
}

class _PasswordSetupScreenState extends State<PasswordSetupScreen> {
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  bool _revealed = false;
  String? _localError;

  /// Eight characters is the floor the vault enforces; the hint below the field
  /// explains why length matters more than symbols here.
  static const int _minimumLength = 8;

  @override
  void initState() {
    super.initState();
    _password.addListener(_onChanged);
    _confirm.addListener(_onChanged);
  }

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _onChanged() {
    // Rebuilding the whole screen on every keystroke is wasteful, and on
    // Windows it costs more than it looks: a full rebuild per character is
    // enough to make fast input drop keys. Only the things this screen actually
    // draws are compared, so typing stays cheap.
    //
    // The whole [PasswordStrength] is compared, not just its level. The bar fill
    // and the caption both change while the level stays the same — `fair` is 0.5
    // at score 2 and 0.75 at score 3, and its advice changes with the character
    // variety — so comparing the enum alone left the meter visibly stale: after
    // following the caption's advice the user saw the same bar and the same
    // sentence telling them to do what they had just done.
    final nextStrength = PasswordStrength.of(
      _password.text,
      minimumLength: _minimumLength,
    );
    final nextCanSubmit = _computeCanSubmit();
    final hadError = _localError != null;
    final unchanged = nextStrength.level == _strength.level &&
        nextStrength.fraction == _strength.fraction &&
        nextStrength.hint == _strength.hint &&
        nextCanSubmit == _canSubmit;
    if (!hadError && unchanged) return;
    setState(() {
      if (hadError) _localError = null;
      _strength = nextStrength;
      _canSubmit = nextCanSubmit;
    });
    // Submits itself as soon as the two fields agree.
    //
    // Becoming ready is the trigger, so the only other thing on the screen is the
    // explicit button below — which is what stops a seven-character password from
    // leaving the user with no visible control at all.
    if (nextCanSubmit && !_autoSubmitted) {
      _autoSubmitted = true;
      unawaited(_submit());
    }
  }

  /// Set once the auto-submit has fired, so typing more cannot send again.
  bool _autoSubmitted = false;

  /// True while a submit is in flight.
  ///
  /// The screen has two ways in — automatic, and the "Next" button — and no latch
  /// of its own, so two Enters on the confirmation field during the seconds
  /// Argon2id takes ran `createAccount` twice against the same vault. The
  /// automatic path was already latched; this is the other one, and it covers
  /// both.
  bool _submitting = false;

  @override
  void didUpdateWidget(PasswordSetupScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // `busy` comes from the parent, so a change in it has to re-evaluate the
    // button without waiting for a keystroke.
    if (oldWidget.busy != widget.busy) {
      final next = _computeCanSubmit();
      if (next != _canSubmit) setState(() => _canSubmit = next);
    }
  }

  PasswordStrength _strength = PasswordStrength.of('');
  bool _canSubmit = false;

  bool _computeCanSubmit() =>
      _password.text.length >= _minimumLength &&
      _password.text == _confirm.text &&
      !widget.busy &&
      !_submitting;

  Future<void> _submit() async {
    if (_submitting) return;
    if (_password.text.length < _minimumLength) {
      setState(() => _localError = 'Use at least $_minimumLength characters.');
      return;
    }
    if (_password.text != _confirm.text) {
      setState(() => _localError = 'The two passwords do not match.');
      return;
    }
    setState(() {
      _localError = null;
      _submitting = true;
    });
    try {
      await widget.onSubmit(_password.text);
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
          _canSubmit = _computeCanSubmit();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      bottomBar: AuthBottomSlot(
        child: AuthTextLink(label: 'Back', onTap: widget.busy ? null : widget.onBack),
      ),
      child: AuthFormLayout(
        alignment: const Alignment(0, -0.1),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ScreenTitle(widget.title),
            const SizedBox(height: 20),
            Text(
              widget.subtitle,
              textAlign: TextAlign.center,
              style: AppTypography.secondary,
            ),
            const SizedBox(height: 30),
            AppTextField(
              controller: _password,
              hint: 'Password',
              obscure: !_revealed,
              autofocus: true,
              enabled: !widget.busy,
              textInputAction: TextInputAction.next,
              suffix: _RevealToggle(
                revealed: _revealed,
                onPressed: () => setState(() => _revealed = !_revealed),
              ),
            ),
            const SizedBox(height: AppMetrics.formGap),
            AppTextField(
              controller: _confirm,
              hint: 'Repeat password',
              obscure: !_revealed,
              enabled: !widget.busy,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 14),
            PasswordStrengthMeter(
              password: _password.text,
              minimumLength: _minimumLength,
            ),
            const SizedBox(height: 10),
            AuthErrorLine(text: _localError ?? widget.errorText),
            // A visible way forward, always.
            //
            // This button used to be rendered only when there was an error, on the
            // reasoning that the screen submits on its own. It does — but only
            // once the password is at least eight characters, and the meter used to
            // claim six was enough. Someone who typed seven characters and matched
            // it saw no complaint, no button, no progress and no way to find out
            // what was wrong; the screen simply looked broken.
            const SizedBox(height: AppMetrics.formGap),
            PrimaryButton(
              label: 'Next',
              busy: widget.busy || _submitting,
              onPressed: _canSubmit
                  ? () {
                      _autoSubmitted = false;
                      unawaited(_submit());
                    }
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// The show/hide control inside the password field.
class _RevealToggle extends StatelessWidget {
  const _RevealToggle({required this.revealed, required this.onPressed});

  final bool revealed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            revealed ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            size: 20,
            color: AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
