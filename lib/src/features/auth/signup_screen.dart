import 'package:flutter/material.dart';

import '../../design/design.dart';
import 'auth_scaffold.dart';
import 'widgets/auth_error_line.dart';

/// The "Create Account" screen: the first step of setting up a device.
///
/// DarkFlow accounts are created entirely offline, so this screen collects only
/// the two pieces of profile a peer will eventually see — a display name and a
/// short "about" line — and then hands them to [onSubmit], which owns account
/// creation, key generation and onward navigation.
class SignUpScreen extends StatefulWidget {
  const SignUpScreen({
    required this.onSubmit,
    this.onBack,
    this.busy = false,
    this.errorText,
    super.key,
  });

  /// Called with the trimmed name and about text when "Next" is pressed. The
  /// screen ignores further presses until the returned future completes, so a
  /// slow key generation cannot produce two accounts.
  final Future<void> Function(String name, String about) onSubmit;

  /// Returns to [LoginScreen].
  /// Provided for callers that can go back. Unused by this screen: the mockup has
/// no back affordance, and the first onboarding step has nothing behind it.
  final VoidCallback? onBack;

  /// True while [onSubmit] is in flight.
  final bool busy;

  /// A failure from the app layer, rendered under the button.
  final String? errorText;

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _about = TextEditingController();

  /// Held so that submitting the name field can move the keyboard to "About
  /// you" instead of dismissing it — the two fields are answered in one pass.
  final FocusNode _aboutFocus = FocusNode();

  bool _submitting = false;

  bool get _locked => widget.busy || _submitting;

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    _aboutFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_locked) return;
    setState(() => _submitting = true);
    try {
      await widget.onSubmit(_name.text.trim(), _about.text.trim());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      child: AuthFormLayout(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ScreenTitle('Create Account'),
            // 46 pt: the mockup leaves more air under a title here than the
            // 20 pt control rhythm, because the title is not a control.
            const SizedBox(height: 46),
            AppTextField(
              controller: _name,
              hint: 'Name',
              enabled: !_locked,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _aboutFocus.requestFocus(),
              autofillHints: const [AutofillHints.name],
            ),
            const SizedBox(height: AppMetrics.gap),
            AppTextField(
              controller: _about,
              hint: 'About you',
              enabled: !_locked,
              focusNode: _aboutFocus,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: AppMetrics.formGap),
            // The failure slot is reserved between the form and its submit
            // button, so a rejected name never moves "Next".
            AuthErrorLine(text: widget.errorText),
            PrimaryButton(
              label: 'Next',
              busy: _locked,
              onPressed: _locked ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}
