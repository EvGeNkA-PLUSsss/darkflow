import 'package:flutter/material.dart';

import '../../design/design.dart';
import 'auth_scaffold.dart';
import 'widgets/auth_error_line.dart';
import 'widgets/password_strength_meter.dart';

/// The sign-in screen, which doubles as the app-unlock screen.
///
/// DarkFlow unlocks a local vault rather than authenticating against a server,
/// so the screen has no username field and no "forgot password" flow: the two
/// things a user can do are type the password they chose, and — if this device
/// has never been set up — go and create an account.
///
/// The screen owns nothing but the text in its field. [onUnlock] is handed the
/// typed password and the app layer decides whether it opens the vault.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    required this.onUnlock,
    required this.onCreateAccount,
    this.busy = false,
    this.errorText,
    this.hasVault = true,
    this.showStrengthMeter = false,
    this.strengthHint,
    super.key,
  });

  /// Called with the typed password when "Next" is pressed or the keyboard's
  /// submit action fires. The screen disables its button until the returned
  /// future completes, so a slow key derivation cannot be started twice.
  final Future<void> Function(String password) onUnlock;

  /// Navigates to [SignUpScreen]. Kept as a callback rather than a route push so
  /// the screen stays free of navigation policy.
  final VoidCallback onCreateAccount;

  /// True while [onUnlock] is in flight.
  final bool busy;

  /// A failure from the app layer, rendered under the field. Reserving its space
  /// keeps the layout still when it appears.
  final String? errorText;

  /// False when this device has no vault yet. It does **not** change this
  /// screen: the field, the "Next" label and the "Create account" link are the
  /// same either way, because a first run still has to ask for a password before
  /// it can offer a new one. The flag is exposed for callers that want to react
  /// to it (analytics, a first-run hint) without having to add a variant of this
  /// screen later.
  final bool hasVault;

  /// Shows the advisory [PasswordStrengthMeter] under the field. Used by the
  /// settings "change password" flow, whose first step reuses this screen.
  final bool showStrengthMeter;

  /// Overrides the meter's caption text. Ignored unless [showStrengthMeter].
  final String? strengthHint;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _password = TextEditingController();
  bool _submitting = false;
  bool _obscured = true;

  bool get _locked => widget.busy || _submitting;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_locked) return;
    if (_password.text.isEmpty) return;
    setState(() => _submitting = true);
    try {
      await widget.onUnlock(_password.text);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      // -0.18 is the measured offset of the mockup's block from the screen
      // centre (76 pt on the 390 x 844 canvas), not an arbitrary nudge.
      child: AuthFormLayout(
        alignment: const Alignment(0, -0.18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthWordmark(),
            // 36 pt: the wordmark's baseline-to-field distance in the mockup.
            // There is no token for it because no other screen stacks against
            // the logo.
            const SizedBox(height: 36),
            AppTextField(
              controller: _password,
              hint: 'Password',
              obscure: _obscured,
              enabled: !_locked,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              onChanged: (_) => setState(() {}),
              autofillHints: const [AutofillHints.password],
              suffix: _RevealToggle(
                obscured: _obscured,
                onPressed: () => setState(() => _obscured = !_obscured),
              ),
            ),
            // The failure slot sits next to the field it describes, so the
            // measured 20 pt field-to-button rhythm is what a user actually
            // sees and only the *reserved* space changes when an error lands.
            AuthErrorLine(text: widget.errorText),
            const SizedBox(height: AppMetrics.gap),
            if (widget.showStrengthMeter) ...[
              PasswordStrengthMeter(
                password: _password.text,
                caption: widget.strengthHint,
              ),
              const SizedBox(height: AppMetrics.gap),
            ],
            PrimaryButton(
              label: 'Next',
              busy: _locked,
              onPressed: _locked ? null : _submit,
            ),
            const SizedBox(height: 22),
            AuthTextLink(
              label: 'Create account',
              onTap: _locked ? null : widget.onCreateAccount,
            ),
          ],
        ),
      ),
    );
  }
}

/// The eye toggle inside the password field.
///
/// It exists because the field is obscure by default and a phone keyboard makes
/// a long passphrase hard to verify without a reveal.
class _RevealToggle extends StatelessWidget {
  const _RevealToggle({required this.obscured, required this.onPressed});

  final bool obscured;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: obscured ? 'Show password' : 'Hide password',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: SizedBox(
            // A 20 pt glyph is a poor tap target. The box is deliberately taller
            // than the field and is clamped by it, so the whole end of the row
            // becomes tappable instead of just the glyph.
            width: 40,
            height: AppMetrics.fieldHeight,
            child: Center(
              child: Icon(
                // The glyph describes what the tap will *do*, which is what the
                // semantics label at the top of this widget already says. It was
                // the other way round here and the opposite way round on the
                // password screen — so the two screens contradicted each other,
                // and this one showed a crossed-out eye while announcing "Show
                // password".
                obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                size: 20,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
