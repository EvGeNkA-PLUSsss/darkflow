import 'package:flutter/material.dart';

import '../../data/models/contact.dart';
import '../../design/design.dart';

/// A contact's profile: who they are, how far they can be trusted, and the four
/// actions the mockup offers.
///
/// The screen takes primitives rather than a [Contact] so it can be rendered
/// for an address that has not been saved yet, and so the app layer keeps the
/// single source of truth for the contact record.
///
/// It is the one surface both layouts route to for a single contact — the phone
/// layout pushes it and the two-pane layout pushes the same route over the shell
/// — which is why the reference to the management actions sits here rather than
/// on a shell: a control added to only one of the two would be unreachable on the
/// other.
class ContactProfileScreen extends StatefulWidget {
  const ContactProfileScreen({
    required this.displayName,
    required this.onionAddress,
    required this.onCopyOnion,
    required this.onShowQr,
    required this.onToggleBlock,
    required this.onToggleNotifications,
    this.onCall,
    required this.blocked,
    required this.notificationsEnabled,
    this.about = '',
    this.avatarPath,
    this.online = false,
    this.lastSeenAt,
    this.trust = ContactTrust.unverified,
    this.onBack,
    this.onOpenChat,
    this.messageCount = 0,
    this.onManage,
    super.key,
  });

  final String displayName;

  /// The full `.onion` address. It is what the "Copy .onion" row copies and what
  /// the trust badge is about, so it is never shortened here.
  final String onionAddress;

  final VoidCallback onCopyOnion;
  final VoidCallback onShowQr;
  final VoidCallback onToggleBlock;
  final VoidCallback onToggleNotifications;

  /// Starts a call. Null hides the row.
  final VoidCallback? onCall;

  final bool blocked;
  final bool notificationsEnabled;

  /// A short bio, shown under the trust badge when the contact has set one.
  final String about;

  final String? avatarPath;

  final bool online;

  /// When they were last reachable; only used to word the status line.
  final DateTime? lastSeenAt;

  final ContactTrust trust;

  /// Pops the route; no back affordance is drawn when null.
  final VoidCallback? onBack;

  /// Opens the conversation. The row is hidden when null, leaving the four
  /// mockup actions untouched.
  final VoidCallback? onOpenChat;

  /// How many messages the thread holds, used to word the consequence of clearing
  /// it. Zero only means there is nothing to clear, not that the management row is
  /// hidden: renaming and deleting apply to a contact with no history too.
  final int messageCount;

  /// Opens the rename / clear / delete sheet. The row is hidden when null,
  /// because a row that opens nothing is a control that does nothing.
  ///
  /// The callback is handed a way to report a rename the account layer accepted,
  /// so this screen can show the new name immediately: the route is built with
  /// the values the app layer had at the time, and a notification from the
  /// account layer does not reach into a pushed route.
  final void Function(void Function(String displayName) onRenamed)? onManage;

  /// The gap between the title and the avatar, measured from the mockup.
  static const double _titleToAvatar = 60;

  @override
  State<ContactProfileScreen> createState() => _ContactProfileScreenState();
}

class _ContactProfileScreenState extends State<ContactProfileScreen> {
  /// The name currently shown, which a rename changes without a round trip.
  ///
  /// The screen reads its values once, when the app layer builds the route, so a
  /// notification from the account layer does not reach it. Renaming therefore
  /// has to update this or the heading would keep the old name until the user
  /// navigated away and back.
  late String _displayName = widget.displayName;

  void _applyRename(String name) {
    if (!mounted) return;
    setState(() => _displayName = name);
  }

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
                      child: ScreenTitle('Profile'),
                    ),
                    const SizedBox(height: ContactProfileScreen._titleToAvatar),
                    Center(
                      child: AppAvatar(
                        name: _displayName,
                        size: AppMetrics.avatarProfile,
                        imagePath: widget.avatarPath,
                        online: widget.online,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Text(
                        _displayName,
                        textAlign: TextAlign.center,
                        style: AppTypography.title,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8, left: 32, right: 32),
                      child: Text(
                        _statusLine(),
                        textAlign: TextAlign.center,
                        style: AppTypography.secondary.copyWith(
                          color: widget.online ? AppColors.accent : AppColors.textSecondary,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 10, left: 32, right: 32),
                      child: _TrustBadge(trust: widget.trust),
                    ),
                    if (widget.about.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 12, left: 32, right: 32),
                        child: Text(
                          widget.about,
                          textAlign: TextAlign.center,
                          style: AppTypography.caption,
                        ),
                      ),
                    const SizedBox(height: 40),
                    AppListSection(
                      children: <Widget>[
                        if (widget.onOpenChat != null)
                          AppListRow(
                            label: 'Open chat',
                            onTap: widget.onOpenChat,
                          ),
                        // Offered only when the host provides a call action, so there is
                        // never a row that does nothing. It is drawn even when the contact
                        // is unreachable, because "there is no route yet" is what the call
                        // screen then says — which is more useful than a missing row.
                        if (widget.onCall != null)
                          AppListRow(
                            label: 'Call',
                            onTap: widget.onCall,
                          ),
                        AppListRow(label: 'Copy .onion', onTap: widget.onCopyOnion),
                        AppListRow(label: 'QR', onTap: widget.onShowQr),
                        if (widget.onManage != null)
                          AppListRow(
                            label: 'Rename, clear or delete…',
                            onTap: () => _openActions(),
                          ),
                        AppListRow(
                          label: widget.blocked ? 'Unblock' : 'Block',
                          // Blocking is the destructive direction; once a contact
                          // is blocked the same row offers to undo it, and that
                          // is not a warning.
                          labelColor: widget.blocked ? null : AppColors.danger,
                          onTap: widget.onToggleBlock,
                        ),
                        AppListRow(
                          label: widget.notificationsEnabled
                              ? 'Disable notifications'
                              : 'Enable notifications',
                          onTap: widget.onToggleNotifications,
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
                if (widget.onBack != null)
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

  void _openActions() {
    widget.onManage!(_applyRename);
  }

  /// "Online" when they are reachable, otherwise when they were last seen. The
  /// wording avoids claiming more precision than the presence beacons carry.
  String _statusLine() {
    if (widget.online) return 'Online';
    final lastSeen = widget.lastSeenAt;
    if (lastSeen == null) return 'Offline';
    return 'Last seen ${_relative(lastSeen.toLocal(), DateTime.now())}';
  }

  /// A compact, honest rendering of an elapsed time.
  static String _relative(DateTime then, DateTime now) {
    final elapsed = now.difference(then);
    if (elapsed.inMinutes < 1) return 'just now';
    if (elapsed.inMinutes < 60) return '${elapsed.inMinutes} minutes ago';
    if (elapsed.inHours < 24) {
      return elapsed.inHours == 1 ? 'an hour ago' : '${elapsed.inHours} hours ago';
    }
    if (elapsed.inDays < 7) {
      return elapsed.inDays == 1 ? 'yesterday' : '${elapsed.inDays} days ago';
    }
    return 'on ${then.year}-${_two(then.month)}-${_two(then.day)}';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

/// The verification badge: the one line on this screen that says whether the
/// address the user pasted is provably the key they are encrypting to.
class _TrustBadge extends StatelessWidget {
  const _TrustBadge({required this.trust});

  final ContactTrust trust;

  @override
  Widget build(BuildContext context) {
    return switch (trust) {
      ContactTrust.verified => const _Badge(
          icon: Icons.verified,
          colour: AppColors.accent,
          label: 'Verified',
        ),
      ContactTrust.keyed => const _Badge(
          icon: Icons.verified_user_outlined,
          colour: AppColors.accent,
          label: 'Key pinned on first contact',
        ),
      ContactTrust.keyChanged => const _Badge(
          icon: Icons.gpp_maybe,
          colour: AppColors.danger,
          label: 'Identity key changed',
          detail: 'This address is now answering with a different identity key '
              'than the one pinned earlier. Either your contact reinstalled, or '
              'somebody else is answering for this address. Confirm before you '
              'keep writing.',
        ),
      ContactTrust.unverified => const _Badge(
          icon: Icons.help_outline,
          colour: AppColors.warning,
          label: 'Not verified',
          detail: 'Compare this address with your contact out of band — on a '
              'call, or in person — before you trust it.',
        ),
    };
  }
}

/// A glyph, a label and an optional one-line explanation, centred.
class _Badge extends StatelessWidget {
  const _Badge({
    required this.icon,
    required this.colour,
    required this.label,
    this.detail,
  });

  final IconData icon;
  final Color colour;
  final String label;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 18, color: colour),
            const SizedBox(width: 8),
            Text(label, style: AppTypography.bodyStrong.copyWith(color: colour)),
          ],
        ),
        if (detail != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(detail!, textAlign: TextAlign.center, style: AppTypography.caption),
        ],
      ],
    );
  }
}
