import 'package:flutter/material.dart';

import '../../design/design.dart';

/// The hub screen: every group of settings, one tap from here.
///
/// The screen owns no state. It renders whatever labels the caller passes in —
/// including the Tor status and the bridge mode — so it stays usable from a
/// widget test and from the app layer alike.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.version,
    required this.onOpenProfile,
    required this.onOpenTorConnection,
    required this.onOpenTorBridges,
    required this.onOpenRelaySettings,
    required this.onOpenSecurity,
    required this.onOpenProtectedFiles,
    required this.onOpenAbout,
    this.onExportDiagnostics,
    this.onOpenMicrophone,
    this.microphoneLabel,
    this.notificationsSupported = true,
    required this.notificationsEnabled,
    required this.onNotificationsChanged,
    required this.torStatusLabel,
    required this.torStatusIsGood,
    required this.bridgeModeLabel,
    required this.relayEnabled,
    required this.onRelayChanged,
    this.onLock,
    this.onBack,
    super.key,
  });


  /// Shown in the About row and the footer.
  final String version;

  final VoidCallback onOpenProfile;
  final VoidCallback onOpenTorConnection;
  final VoidCallback onOpenTorBridges;
  final VoidCallback onOpenRelaySettings;
  final VoidCallback onOpenSecurity;
  final VoidCallback onOpenProtectedFiles;
  final VoidCallback onOpenAbout;

  /// Writes the diagnostics report and hands it to the share sheet. The row is hidden when
  /// null, so a build without a way to send it does not offer one.
  final VoidCallback? onExportDiagnostics;

  /// Opens the input-device picker. Hidden when null: a platform with no choice to offer
  /// should not show a row that leads nowhere.
  final VoidCallback? onOpenMicrophone;

  /// The chosen input, for the row's subtitle.
  final String? microphoneLabel;

  /// Whether this platform can show alerts at all. False on a build without the plugin.
  final bool notificationsSupported;

  final bool notificationsEnabled;
  final ValueChanged<bool> onNotificationsChanged;

  /// A short Tor state, e.g. `'Connected'`, `'Connecting…'` or `'Offline'`.
  final String torStatusLabel;

  /// Paints [torStatusLabel] in the accent colour when true, secondary grey
  /// otherwise — the same green/amber distinction the Tor screen makes.
  final bool torStatusIsGood;

  /// [BridgeMode.label] of the configured transport.
  final String bridgeModeLabel;

  final bool relayEnabled;
  final ValueChanged<bool> onRelayChanged;

  /// Locks the vault immediately. The row is hidden when null, so a platform
  /// without a lock path simply does not offer one.
  final VoidCallback? onLock;

  /// Leaves the screen. When non-null an app bar with a back button is drawn;
  /// when null — a phone, where the system back gesture exists — the screen
  /// keeps its large centred title instead.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      // A real way out.
      //
      // The screen had no app bar and no back affordance at all, so on Windows
      // — where there is no system back gesture — opening Settings was a
      // one-way trip. The bar appears whenever the caller can supply somewhere
      // to go, and the in-body title is dropped in that case so "Settings" is
      // not printed twice.
      appBar: onBack == null
          ? null
          : AppBar(
              title: const Text('Settings'),
              leading: IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                color: AppColors.textPrimary,
                tooltip: 'Back',
              ),
            ),
      child: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          child: CenteredContent(
            maxWidth: AppMetrics.maxContentWidth * 2,
            padding: EdgeInsets.zero,
            child: Padding(
              padding: EdgeInsets.only(top: onBack == null ? 24 : 12, bottom: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (onBack == null) const ScreenTitle('Settings'),
                  _SettingsSection(
                    title: 'Account',
                    rows: <Widget>[
                      AppListRow(
                        label: 'My profile',
                        leading: _rowIcon(Icons.person_outline),
                        trailing: _chevron(),
                        onTap: onOpenProfile,
                      ),
                      AppSwitchRow(
                        label: 'Notifications',
                        // Said plainly rather than left as an unqualified promise.
                        //
                        // DarkFlow receives over Tor through a daemon inside this
                        // process, so there is no code alive to be woken once the
                        // system reclaims the app: an alert can only be produced
                        // while DarkFlow is running. A switch labelled "alerts for
                        // messages" implies they arrive always, and a user who
                        // discovers otherwise has been misled rather than informed.
                        subtitle: notificationsSupported
                            ? 'Alerts while DarkFlow is running. Nothing arrives when '
                                'it has been closed, because there is no server to '
                                'wake it.'
                            : 'This platform cannot show alerts from DarkFlow.',
                        value: notificationsEnabled && notificationsSupported,
                        onChanged:
                            notificationsSupported ? onNotificationsChanged : null,
                      ),
                      if (onOpenMicrophone != null)
                        AppListRow(
                          label: 'Microphone',
                          leading: _rowIcon(Icons.mic_none_outlined),
                          subtitle: 'Which input a voice message is recorded from',
                          trailing: _status(microphoneLabel ?? 'System default'),
                          onTap: onOpenMicrophone,
                        ),
                    ],
                  ),
                  _SettingsSection(
                    title: 'Network',
                    rows: <Widget>[
                      AppListRow(
                        label: 'Tor connection',
                        leading: _rowIcon(Icons.lan_outlined),
                        trailing: _status(torStatusLabel, good: torStatusIsGood),
                        onTap: onOpenTorConnection,
                      ),
                      AppListRow(
                        label: 'Tor bridges',
                        leading: _rowIcon(Icons.route_outlined),
                        trailing: _status(bridgeModeLabel),
                        onTap: onOpenTorBridges,
                      ),
                      AppListRow(
                        label: 'Relay & mailbox',
                        leading: _rowIcon(Icons.dns_outlined),
                        trailing: _RelayTrailing(
                          enabled: relayEnabled,
                          onChanged: onRelayChanged,
                        ),
                        onTap: onOpenRelaySettings,
                      ),
                    ],
                  ),
                  _SettingsSection(
                    title: 'Privacy',
                    rows: <Widget>[
                      AppListRow(
                        label: 'Protected files',
                        leading: _rowIcon(Icons.folder_special_outlined),
                        trailing: _chevron(),
                        onTap: onOpenProtectedFiles,
                      ),
                      AppListRow(
                        label: 'Security',
                        leading: _rowIcon(Icons.shield_outlined),
                        trailing: _status('Password only'),
                        onTap: onOpenSecurity,
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
                  _SettingsSection(
                    title: 'About',
                    rows: <Widget>[
                      AppListRow(
                        label: 'About DarkFlow',
                        leading: _rowIcon(Icons.info_outline),
                        trailing: _status(version),
                        onTap: onOpenAbout,
                      ),
                      if (onExportDiagnostics != null)
                        AppListRow(
                          label: 'Export diagnostics',
                          leading: _rowIcon(Icons.description_outlined),
                          subtitle: 'A report about this build to attach to a bug '
                              'report. No messages, names or addresses.',
                          trailing: _chevron(),
                          onTap: onExportDiagnostics,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A 20 pt secondary-coloured glyph, the size and colour the mockup uses for
  /// every leading icon.
  Widget _rowIcon(IconData icon) =>
      Icon(icon, size: 20, color: AppColors.textSecondary);

  /// The affordance for rows that navigate and carry no status of their own.
  /// "My profile" shows a chevron rather than the account's shortened `.onion`
  /// because this screen is handed no address to shorten.
  Widget _chevron() =>
      const Icon(Icons.chevron_right, size: 20, color: AppColors.textSecondary);

  /// A trailing value in caption size, optionally accented when the state is a
  /// good one.
  Widget _status(String label, {bool good = false}) => Text(
        label,
        style: good
            ? AppTypography.caption.copyWith(color: AppColors.accent)
            : AppTypography.caption,
      );
}

/// A labelled group of rows. The header sits above the run so a user can scan
/// for "Privacy" without reading the rows.
class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.rows});

  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionHeader(
          title,
          padding: const EdgeInsets.fromLTRB(14, 24, 14, 8),
        ),
        AppListSection(children: rows),
      ],
    );
  }
}

/// The trailing half of "Relay & mailbox": the design asks for an "On"/"Off"
/// word, and the screen is also handed a switch callback, so both are offered —
/// the word states the value, the switch changes it without leaving the screen,
/// and a tap anywhere else on the row opens the full relay settings.
class _RelayTrailing extends StatelessWidget {
  const _RelayTrailing({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(enabled ? 'On' : 'Off', style: AppTypography.caption),
        const SizedBox(width: 6),
        Switch(
          value: enabled,
          onChanged: onChanged,
          activeThumbColor: AppColors.textOnAccent,
          activeTrackColor: AppColors.accent,
          inactiveThumbColor: AppColors.textSecondary,
          inactiveTrackColor: AppColors.surfaceHigh,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }
}
