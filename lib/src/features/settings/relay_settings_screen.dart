import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/relay.dart';
import '../../design/design.dart';

/// How much of the mesh this device carries for other people.
///
/// The screen is not in the mockups; it extends the Settings language — a
/// centred title, full-bleed switch rows, then labelled numeric fields — so it
/// does not look like a different application. Every edit is reported through
/// [onChanged] as a complete [RelayPolicy]; nothing is stored here.
class RelaySettingsScreen extends StatefulWidget {
  const RelaySettingsScreen({
    required this.policy,
    required this.onChanged,
    this.usedBytes = 0,
    this.usedEnvelopes = 0,
    this.onBack,
    super.key,
  });

  /// The policy currently in force, used to seed the fields.
  final RelayPolicy policy;

  /// Called with the whole policy after every edit, so the caller can persist
  /// it or reject it without this screen knowing how.
  final ValueChanged<RelayPolicy> onChanged;

  /// Ciphertext currently held for other people, for the usage caption.
  final int usedBytes;

  /// Envelopes currently held for other people, for the usage caption.
  final int usedEnvelopes;

  /// Pops the route; no back affordance is drawn when null.
  final VoidCallback? onBack;

  @override
  State<RelaySettingsScreen> createState() => _RelaySettingsScreenState();
}

class _RelaySettingsScreenState extends State<RelaySettingsScreen> {
  /// Quotas are stored in bytes but configured in whole megabytes, matching the
  /// "Storage limit (MB)" label and the usage caption.
  static const int _bytesPerMegabyte = 1024 * 1024;

  /// Horizontal inset of the labelled fields and the explanation copy. Rows stay
  /// full-bleed, as everywhere else.
  static const double _formInset = AppMetrics.screenPadding;

  /// Seeded once from the widget. The fields are deliberately not re-synced on
  /// rebuild: a caller that echoes [onChanged] straight back would otherwise
  /// fight the user's cursor while they type.
  late final TextEditingController _storageMb = TextEditingController(
    text: '${widget.policy.maxStoredBytes ~/ _bytesPerMegabyte}',
  );
  late final TextEditingController _retentionDays = TextEditingController(
    text: '${widget.policy.retention.inDays}',
  );
  late final TextEditingController _maxHops = TextEditingController(
    text: '${widget.policy.maxHops}',
  );

  @override
  void dispose() {
    _storageMb.dispose();
    _retentionDays.dispose();
    _maxHops.dispose();
    super.dispose();
  }

  /// Publishes the master switch. The numeric limits are left exactly as the
  /// user set them — the fields still own their own text.
  void _setEnabled(bool value) => widget.onChanged(_rebuild(enabled: value));

  /// Restricts the mailbox to known contacts.
  void _setOnlyForContacts(bool value) =>
      widget.onChanged(_rebuild(onlyForContacts: value));

  /// A copy of the policy with the given fields replaced. [RelayPolicy] has no
  /// `copyWith`, and spelling every field out means a new field on the model
  /// breaks this build instead of being silently dropped.
  RelayPolicy _rebuild({bool? enabled, bool? onlyForContacts}) {
    final policy = widget.policy;
    return RelayPolicy(
      enabled: enabled ?? policy.enabled,
      maxStoredBytes: policy.maxStoredBytes,
      maxEnvelopes: policy.maxEnvelopes,
      retention: policy.retention,
      onlyForContacts: onlyForContacts ?? policy.onlyForContacts,
      maxHops: policy.maxHops,
    );
  }

  /// Reads back an edited integer, falling back to the current policy when the
  /// field is empty or mid-edit.
  int _read(TextEditingController controller, int fallback) =>
      int.tryParse(controller.text.trim()) ?? fallback;

  /// Rebuilds the policy from the four controls and hands it to the caller.
  ///
  /// [RelayPolicy] is immutable and has no `copyWith`, so every field is named
  /// explicitly; adding one to the model will make this method fail to compile
  /// rather than silently drop the new field.
  void _emit() {
    widget.onChanged(
      RelayPolicy(
        enabled: widget.policy.enabled,
        maxStoredBytes:
            _read(_storageMb, widget.policy.maxStoredBytes ~/ _bytesPerMegabyte) *
                _bytesPerMegabyte,
        maxEnvelopes: widget.policy.maxEnvelopes,
        retention: Duration(
          days: _read(_retentionDays, widget.policy.retention.inDays),
        ),
        onlyForContacts: widget.policy.onlyForContacts,
        maxHops: _read(_maxHops, widget.policy.maxHops),
      ),
    );
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
                      child: ScreenTitle('Relay & mailbox'),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(32, 10, 32, 0),
                      child: Text(
                        'DarkFlow has no servers, so messages reach an offline '
                        'contact through devices like this one.',
                        textAlign: TextAlign.center,
                        style: AppTypography.secondary,
                      ),
                    ),
                    const SizedBox(height: 24),
                    AppListSection(
                      children: <Widget>[
                        AppSwitchRow(
                          label: 'Help deliver messages for my contacts',
                          subtitle: 'This device holds encrypted messages for '
                              'contacts who are offline, and cannot read them.',
                          value: widget.policy.enabled,
                          onChanged: (bool value) => _setEnabled(value),
                        ),
                        AppSwitchRow(
                          label: 'Only for my contacts',
                          subtitle: 'Refuse envelopes from anyone not in your list',
                          value: widget.policy.onlyForContacts,
                          onChanged: (bool value) => _setOnlyForContacts(value),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(_formInset, 24, _formInset, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          LabeledField(
                            label: 'Storage limit (MB)',
                            help: 'Ciphertext kept on disk for other people.',
                            field: AppTextField(
                              controller: _storageMb,
                              hint: '32',
                              keyboardType: TextInputType.number,
                              inputFormatters: <TextInputFormatter>[
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              onChanged: (_) => _emit(),
                            ),
                          ),
                          const SizedBox(height: AppMetrics.gap),
                          LabeledField(
                            label: 'Retention (days)',
                            help: 'Anything older is dropped, whatever its own '
                                'expiry says.',
                            field: AppTextField(
                              controller: _retentionDays,
                              hint: '3',
                              keyboardType: TextInputType.number,
                              inputFormatters: <TextInputFormatter>[
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              onChanged: (_) => _emit(),
                            ),
                          ),
                          const SizedBox(height: AppMetrics.gap),
                          LabeledField(
                            label: 'Maximum hops',
                            help: 'How many relays may pass an envelope along '
                                'before it is dropped.',
                            field: AppTextField(
                              controller: _maxHops,
                              hint: '3',
                              keyboardType: TextInputType.number,
                              inputFormatters: <TextInputFormatter>[
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              onChanged: (_) => _emit(),
                            ),
                          ),
                          const SizedBox(height: AppMetrics.gap),
                          Text(_usageCaption(), style: AppTypography.caption),
                        ],
                      ),
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

  /// "Holding N messages for others, X MB of Y MB" — the honest version of a
  /// quota bar, and the only place the user can see the device actually working.
  String _usageCaption() {
    final used = _megabytes(widget.usedBytes);
    final limit = _megabytes(widget.policy.maxStoredBytes);
    return 'Holding ${widget.usedEnvelopes} messages for others, $used MB of $limit MB';
  }

  String _megabytes(int bytes) => (bytes / _bytesPerMegabyte).toStringAsFixed(1);
}
