import 'package:flutter/material.dart';

import '../../design/design.dart';

/// What DarkFlow is, who wrote it and what it is built from.
///
/// The component list is part of the security story rather than legal filler:
/// a messenger that asks to be trusted should say exactly which open-source
/// libraries it links, and under which licence. It has to be complete for the
/// same reason — a list that omits something is worse than no list, because it
/// reads as a claim.
class AboutScreen extends StatelessWidget {
  const AboutScreen({
    required this.version,
    required this.buildNumber,
    this.isRelease = false,
    this.onBack,
    super.key,
  });

  /// The user-visible release, e.g. `'0.1.0'`.
  final String version;

  /// The build identifier, e.g. `'1'`, so a bug report can name exactly which
  /// binary it came from. Named `buildNumber` rather than `build` so it cannot
  /// collide with [StatelessWidget.build].
  final String buildNumber;

  /// False for a build that was not produced by `tool/release.ps1`.
  ///
  /// Shown rather than hidden. A version number in a bug report is only useful if
  /// the reader can tell whether it names a published artifact or somebody's
  /// working copy, and "0.1.0" from a local build is a different thing from
  /// "0.1.0" from a release.
  final bool isRelease;

  /// Pops the route; no back affordance is drawn when null.
  final VoidCallback? onBack;

  /// The bundled components and the licence each one ships under.
  ///
  /// Verified against the licence files in the pub cache, and against
  /// `pubspec.yaml` for completeness: everything the app links is here, including
  /// the transitive dependencies that carry their own obligations. `cryptography`
  /// is Apache-2.0 and pulls in `ffi`; the Tor binaries are BSD-3-Clause and are
  /// distributed unmodified.
  static const List<({String name, String licence, String why})> _components =
      <({String name, String licence, String why})>[
    (name: 'Flutter', licence: 'BSD-3-Clause', why: 'The user interface toolkit.'),
    (name: 'Tor', licence: 'BSD-3-Clause', why: 'The anonymity network, and the daemon that publishes this account.'),
    (name: 'obfs4proxy / lyrebird', licence: 'BSD-2-Clause', why: 'The obfs4 pluggable transport.'),
    (name: 'snowflake', licence: 'BSD-3-Clause', why: 'The Snowflake pluggable transport.'),
    (name: 'WebTunnel', licence: 'BSD-3-Clause', why: 'The WebTunnel pluggable transport.'),
    (name: 'meek', licence: 'BSD-3-Clause', why: 'The meek pluggable transport.'),
    (name: 'conjure', licence: 'BSD-3-Clause', why: 'The conjure pluggable transport.'),
    (name: 'cryptography', licence: 'Apache-2.0', why: 'AES-256-GCM, Argon2id, Ed25519, X25519, HKDF and BLAKE2b.'),
    (name: 'pretty_qr_code', licence: 'MIT', why: 'Drawing the onion-address QR code.'),
    (name: 'record', licence: 'BSD-3-Clause', why: 'Recording voice messages.'),
    (name: 'audioplayers', licence: 'MIT', why: 'Playing voice messages.'),
    (name: 'file_picker', licence: 'MIT', why: 'Choosing a file to send or protect.'),
    (name: 'mobile_scanner', licence: 'BSD-3-Clause', why: 'Scanning an onion-address QR code with a camera.'),
    (name: 'path_provider', licence: 'BSD-3-Clause', why: 'Finding the platform application-support directory.'),
    (name: 'intl', licence: 'BSD-3-Clause', why: 'Formatting dates and times.'),
    (name: 'mime', licence: 'BSD-3-Clause', why: 'Guessing a file type from its extension.'),
    (name: 'ffi', licence: 'BSD-3-Clause', why: 'Calling Windows DPAPI to bind the PIN secret to this device.'),
  ];

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
                      child: ScreenTitle('About DarkFlow'),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(32, 10, 32, 0),
                      child: Text(
                        'Version $version'
                        '${buildNumber == '0' ? '' : ' · build $buildNumber'}'
                        '${isRelease ? '' : ' · development build'}',
                        textAlign: TextAlign.center,
                        style: AppTypography.caption,
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(
                        AppMetrics.screenPadding,
                        24,
                        AppMetrics.screenPadding,
                        0,
                      ),
                      child: _DesignNote(),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(
                        AppMetrics.screenPadding,
                        24,
                        AppMetrics.screenPadding,
                        0,
                      ),
                      child: _LicenceNote(),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(
                        AppMetrics.screenPadding,
                        28,
                        AppMetrics.screenPadding,
                        0,
                      ),
                      child: SectionHeader('Open source'),
                    ),
                    const SizedBox(height: 12),
                    AppListSection(
                      children: <Widget>[
                        for (final component in _components)
                          AppListRow(
                            label: component.name,
                            // The reason each one is here, so the list says what
                            // the app depends on rather than only naming it.
                            subtitle: component.why,
                            trailing: Text(
                              component.licence,
                              style: AppTypography.caption,
                            ),
                          ),
                      ],
                    ),
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
}

/// The paragraph that explains why DarkFlow has no servers, split out so the
/// page's build method stays a layout description.
class _DesignNote extends StatelessWidget {
  const _DesignNote();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'DarkFlow keeps no servers. Every account is its own Tor onion service, '
      'so there is no address book to seize and no inbox to subpoena: what you '
      'send is dialled directly to the person you are talking to. Messages are '
      'end-to-end encrypted, and the keys are derived on your device from your '
      'account keys, never from anything we hold. When a contact is offline, '
      'their messages are carried by other contacts, who can forward the '
      'ciphertext but cannot read it. Nothing here talks to the open internet '
      'except through Tor.',
      style: AppTypography.secondary,
    );
  }
}

/// The paragraph that says where the bundled software came from and under what
/// terms, which is a redistribution obligation rather than a courtesy.
///
/// DarkFlow ships the Tor daemon and several pluggable transports inside the
/// application, unmodified. Their licences (BSD-2-Clause and BSD-3-Clause) permit
/// that, and require the copyright notice and the licence text to travel with the
/// binaries. Naming the components and their licences here satisfies the notice
/// requirement; the full texts ship in the repository under `licenses/`, and the
/// source each binary was built from is recorded by `tool/fetch_tor_windows.ps1`.
class _LicenceNote extends StatelessWidget {
  const _LicenceNote();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'The Tor daemon and its pluggable transports are bundled with this '
      'application, unmodified, under their own open-source licences. Their full '
      'licence texts ship with the source tree in the licenses/ directory, and '
      'the exact version and source of every bundled binary is recorded in '
      'tor_runtime/windows/MANIFEST.json. Tor is developed by the Tor Project '
      'and is not affiliated with this application.',
      style: AppTypography.secondary,
    );
  }
}
