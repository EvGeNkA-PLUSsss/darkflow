import 'package:flutter/material.dart';

import '../../design/design.dart';
import 'auth_scaffold.dart';

/// The local user's own profile.
///
/// It is the screen that answers "who am I on this network?", which for DarkFlow
/// means showing the `.onion` address: that string *is* the username, and it is
/// the only thing another person needs in order to reach this account. The rows
/// below the address are therefore all about that string or about the identity
/// behind it — copy it, show it as a QR code, rename the display name, or change
/// the password that protects it.
///
/// The screen is purely presentational: every row hands control back to the app
/// layer, which owns the clipboard, the QR route and the settings screens.
class MyProfileScreen extends StatelessWidget {
  const MyProfileScreen({
    required this.displayName,
    required this.onionAddress,
    required this.createdAt,
    this.about = '',
    this.avatarPath,
    required this.onCopyAddress,
    required this.onShowQr,
    required this.onChangeDisplayName,
    required this.onChangePassword,
    required this.onBack,
    super.key,
  });

  /// Shown under the avatar and used for the avatar's initial.
  final String displayName;

  /// The full `.onion` address, i.e. the username.
  final String onionAddress;

  /// When the account was created, shown in the footer.
  final DateTime createdAt;

  /// The short bio from "Create Account". Hidden when empty rather than shown as
  /// a dash, because an empty bio is a normal state.
  final String about;

  /// A profile picture on disk, when the user has one.
  final String? avatarPath;

  /// Puts [onionAddress] on the clipboard.
  final VoidCallback onCopyAddress;

  /// Opens [OnionQrScreen] for this address.
  final VoidCallback onShowQr;

  /// Opens the display-name editor.
  final VoidCallback onChangeDisplayName;

  /// Opens the password-change flow, whose first step reuses [LoginScreen].
  final VoidCallback onChangePassword;

  /// Leaves the screen.
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(
        leading: AuthBackButton(onPressed: onBack),
        title: const Text('Profile', style: AppTypography.h1),
      ),
      child: SafeArea(
        top: false,
        // The list grows with the row count and the window can be short, so the
        // whole screen scrolls rather than only the rows.
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppMetrics.maxContentWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: AppMetrics.screenPadding),
                  _ProfileHeader(
                    displayName: displayName,
                    about: about,
                    avatarPath: avatarPath,
                  ),
                  const SizedBox(height: 34),
                  _IdentityAddress(address: onionAddress),
                  const SizedBox(height: 34),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: AppListSection(
                      children: [
                        AppListRow(
                          label: 'Copy .onion',
                          leading: const Icon(
                            Icons.content_copy_outlined,
                            size: 20,
                            color: AppColors.textSecondary,
                          ),
                          onTap: onCopyAddress,
                        ),
                        AppListRow(
                          label: 'Show QR code',
                          leading: const Icon(
                            Icons.qr_code_2_outlined,
                            size: 20,
                            color: AppColors.textSecondary,
                          ),
                          onTap: onShowQr,
                        ),
                        AppListRow(
                          label: 'Change display name',
                          leading: const Icon(
                            Icons.badge_outlined,
                            size: 20,
                            color: AppColors.textSecondary,
                          ),
                          onTap: onChangeDisplayName,
                        ),
                        AppListRow(
                          label: 'Change password',
                          leading: const Icon(
                            Icons.lock_outline,
                            size: 20,
                            color: AppColors.textSecondary,
                          ),
                          onTap: onChangePassword,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppMetrics.screenPadding),
                  _CreatedFooter(createdAt: createdAt),
                  const SizedBox(height: AppMetrics.screenPadding),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Avatar, name and bio.
///
/// The spacing is fixed rather than proportional because these three elements
/// are one visual unit: the avatar is the anchor the eye lands on, and the name
/// has to sit close enough to it to read as its caption.
class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({
    required this.displayName,
    required this.about,
    required this.avatarPath,
  });

  final String displayName;
  final String about;
  final String? avatarPath;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppAvatar(
          name: displayName,
          size: AppMetrics.avatarProfile,
          imagePath: avatarPath,
        ),
        const SizedBox(height: AppMetrics.gap),
        Text(
          displayName,
          style: AppTypography.title,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (about.isNotEmpty) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppMetrics.screenPadding),
            child: Text(
              about,
              style: AppTypography.secondary,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}

/// The `.onion` address, shown in full and selectable.
///
/// It is the one value on this screen that someone may need to read aloud or
/// copy by hand, so it wraps to at most two lines instead of being truncated,
/// and selection is enabled so a desktop user can copy a fragment of it.
class _IdentityAddress extends StatelessWidget {
  const _IdentityAddress({required this.address});

  final String address;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppMetrics.screenPadding),
      child: SelectableText(
        address,
        textAlign: TextAlign.center,
        maxLines: 2,
        style: AppTypography.mono.copyWith(color: AppColors.textSecondary),
      ),
    );
  }
}

/// When the account was created.
///
/// The date is formatted here rather than through `intl`'s locale data because
/// the app ships no locale data yet: the output has to be identical on every
/// platform, and this is the only date the auth flow displays.
class _CreatedFooter extends StatelessWidget {
  const _CreatedFooter({required this.createdAt});

  final DateTime createdAt;

  static const List<String> _months = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  /// `3 March 2025`, in the local time the user experienced.
  String get _formatted {
    final local = createdAt.toLocal();
    return '${local.day} ${_months[local.month - 1]} ${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppMetrics.screenPadding),
      child: Text(
        'Account created $_formatted',
        style: AppTypography.caption,
        textAlign: TextAlign.center,
      ),
    );
  }
}
