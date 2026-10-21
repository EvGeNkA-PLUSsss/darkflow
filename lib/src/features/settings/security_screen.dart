import 'package:flutter/material.dart';

import '../../design/design.dart';

/// The account password and the immediate lock.
///
/// The explanation block at the bottom is part of the design: the password is
/// the only secret this app asks for, so the screen states plainly what it
/// protects and why there is nothing shorter offered next to it.
class SecurityScreen extends StatelessWidget {
  const SecurityScreen({
    this.cryptoBackend,
    this.onChangePassword,
    this.onLock,
    this.onBack,
    super.key,
  });

  /// The crypto implementation in use, e.g. `'dart_crypto_engine (Argon2id,
  /// AES-GCM, Ed25519, X25519)'`. Shown as a caption when provided.
  final String? cryptoBackend;

  /// Starts the password-change flow; the row is hidden when null.
  final VoidCallback? onChangePassword;

  /// Locks the vault now. The destructive row is hidden when null.
  final VoidCallback? onLock;

  /// Pops the route; no back affordance is drawn when null.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
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
                      child: ScreenTitle('Security'),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(32, 10, 32, 0),
                      child: Text(
                        'Keys never leave this device, and nothing is stored '
                        'unencrypted.',
                        textAlign: TextAlign.center,
                        style: AppTypography.secondary,
                      ),
                    ),
                    const SizedBox(height: 24),
                    AppListSection(
                      children: <Widget>[
                        if (onChangePassword != null)
                          AppListRow(
                            label: 'Change account password',
                            leading: _rowIcon(Icons.password_outlined),
                            onTap: onChangePassword,
                          ),
                        if (onLock != null)
                          AppListRow(
                            label: 'Lock now',
                            labelColor: AppColors.danger,
                            leading: _rowIcon(Icons.lock_outline),
                            onTap: onLock,
                          ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppMetrics.screenPadding,
                        24,
                        AppMetrics.screenPadding,
                        0,
                      ),
                      child: Text(_explanation, style: AppTypography.secondary),
                    ),
                    if (cryptoBackend != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppMetrics.screenPadding,
                          20,
                          AppMetrics.screenPadding,
                          32,
                        ),
                        child: Text(
                          'Crypto backend: $cryptoBackend',
                          style: AppTypography.caption,
                        ),
                      )
                    else
                      const SizedBox(height: 32),
                  ],
                ),
                if (onBack != null)
                  Positioned(
                    top: 4,
                    left: 4,
                    child: IconButton(
                      onPressed: onBack,
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

  /// Three sentences, no jargon: one master key, the stretched password that is
  /// the only thing that unlocks it, and why nothing shorter is offered.
  static const String _explanation = 'One random master key encrypts everything '
      'DarkFlow stores, and it never leaves this device. Your account password '
      'is stretched with Argon2id into a key that unlocks that master key, so '
      'changing the password re-wraps it rather than re-encrypting your data. '
      'It is the only secret DarkFlow asks for. A six-digit code would be a '
      'million possibilities — nothing at all against a stolen vault file — so '
      'a shorter way in would only be a weaker door to the same master key.';

  static Widget _rowIcon(IconData icon) =>
      Icon(icon, size: 20, color: AppColors.textSecondary);
}
