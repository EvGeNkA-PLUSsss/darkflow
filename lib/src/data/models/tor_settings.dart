/// Which pluggable transport (or none) Tor should use to reach the network.
///
/// The mockups expose two presets — `obfs4` and `WebTunnel` — plus a free-form
/// manual configuration box. The extra modes below exist because censorship
/// differs by country and the app should not need a code change to add one.
enum BridgeMode {
  /// Connect straight to guard relays. Fastest, and the first thing a censored
  /// network blocks.
  automatic,

  /// obfs4 — traffic looks like nothing in particular. The workhorse.
  obfs4,

  /// WebTunnel — the connection looks like ordinary HTTPS to a website.
  webTunnel,

  /// Snowflake — uses volunteers' browsers as short-lived proxies.
  snowflake,

  /// meek — domain fronting through a CDN.
  meek,

  /// The user pasted their own `Bridge` lines.
  custom;

  static BridgeMode fromName(String? name) => BridgeMode.values.firstWhere(
        (value) => value.name == name,
        orElse: () => BridgeMode.automatic,
      );

  /// True when this mode is reached through a pluggable transport rather than
  /// a direct connection to a guard relay.
  bool get isBridgeMode => this != BridgeMode.automatic;

  /// Human label used on the bridge settings screen.
  String get label => switch (this) {
        BridgeMode.automatic => 'Direct',
        BridgeMode.obfs4 => 'obfs4',
        BridgeMode.webTunnel => 'WebTunnel',
        BridgeMode.snowflake => 'Snowflake',
        BridgeMode.meek => 'meek',
        BridgeMode.custom => 'Custom',
      };
}

/// Where a set of bridge lines came from, shown in the UI so the user knows
/// whether the list is stale.
enum BridgeSource {
  builtIn,
  builtInDefault,
  manual,
  fetched;

  static BridgeSource fromName(String? name) => BridgeSource.values.firstWhere(
        (value) => value.name == name,
        orElse: () => BridgeSource.builtIn,
      );
}

/// Everything the Tor manager needs to start and configure the daemon.
class TorSettings {
  const TorSettings({
    this.mode = BridgeMode.automatic,
    this.customBridges = '',
    this.extraConfig = '',
    this.socksPort = 0,
    this.controlPort = 0,
    this.connectionTimeoutSeconds = 120,
    this.strictNodes = false,
    this.enableOnionService = true,
    this.virtualPort = 80,
    this.source = BridgeSource.builtIn,
    this.lastBootstrapAt,
    this.lastBootstrapSeconds,
  });

  final BridgeMode mode;

  /// Newline-separated `Bridge …` lines entered in the manual configuration
  /// box, or the lines belonging to the selected preset.
  final String customBridges;

  /// Extra torrc directives for power users, e.g. `EntryNodes {ru}`.
  final String extraConfig;

  /// 0 means "pick a free port automatically".
  final int socksPort;
  final int controlPort;

  final int connectionTimeoutSeconds;

  /// Restrict the circuit to the configured nodes. Useful for testing; harmful
  /// for anonymity, hence off by default.
  final bool strictNodes;

  /// Publish this device's own onion service.
  final bool enableOnionService;

  /// The onion-service virtual port peers dial. 80 mirrors the web convention
  /// and survives restrictive middleboxes better than an odd port.
  final int virtualPort;

  final BridgeSource source;

  final DateTime? lastBootstrapAt;

  /// How long the last successful bootstrap took, for the Tor screen's summary.
  final int? lastBootstrapSeconds;

  /// The transport to actually use.
  ///
  /// A user who pastes `webtunnel [addr]:443 …` has said what they want, even
  /// if they never tapped a preset to say it again — and leaving the mode on
  /// `automatic` made the app write `UseBridges 0` while the box was full of
  /// bridge lines. That is the whole reason a configured bridge could be
  /// silently ignored: Tor connected directly, stalled at 10%, and nothing
  /// anywhere said that the bridges had been discarded.
  ///
  /// The transport keyword is read from the first recognised line, which is the
  /// same token torrc itself uses.
  BridgeMode get effectiveMode {
    if (mode != BridgeMode.automatic) return mode;
    for (final line in bridgeLines) {
      // Case-insensitively, because torrc option keywords are case-insensitive:
      // `bridge obfs4 …` is a perfectly valid line, and matching only the
      // capitalised spelling meant the mode stayed `automatic` and
      // `requiredTransports` came back empty — the screen then reported
      // "direct, no bridges" about a configuration that had a bridge in it.
      final withoutKeyword =
          line.trim().toLowerCase().replaceFirst(RegExp(r'^bridge\s+'), '');
      final keyword = withoutKeyword
          .split(RegExp(r'\s+'))
          .firstWhere((token) => token.isNotEmpty, orElse: () => '');
      switch (keyword) {
        case 'obfs4':
          return BridgeMode.obfs4;
        case 'webtunnel':
          return BridgeMode.webTunnel;
        case 'snowflake':
          return BridgeMode.snowflake;
        case 'meek':
        case 'meek_lite':
          return BridgeMode.meek;
      }
    }
    return mode;
  }

  /// True when Tor should not connect directly.
  ///
  /// Bridge lines alone are enough: they are the user's instruction, whatever
  /// the preset dropdown happens to be showing.
  bool get usesBridges =>
      effectiveMode != BridgeMode.automatic || bridgeLines.isNotEmpty;

  /// The individual `Bridge` lines, minus comments and blank lines.
  List<String> get bridgeLines => customBridges
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('#'))
      .toList(growable: false);

  /// The `ClientTransportPlugin` binaries implied by the transport in force.
  List<String> get requiredTransports => switch (effectiveMode) {
        BridgeMode.automatic => const <String>[],
        BridgeMode.obfs4 => const <String>['obfs4'],
        BridgeMode.webTunnel => const <String>['webtunnel'],
        BridgeMode.snowflake => const <String>['snowflake'],
        BridgeMode.meek => const <String>['meek'],
        BridgeMode.custom => const <String>[], // inferred from the bridge lines
      };

  TorSettings copyWith({
    BridgeMode? mode,
    String? customBridges,
    String? extraConfig,
    int? socksPort,
    int? controlPort,

    int? connectionTimeoutSeconds,
    bool? strictNodes,
    bool? enableOnionService,
    int? virtualPort,
    BridgeSource? source,
    DateTime? lastBootstrapAt,
    int? lastBootstrapSeconds,
  }) {
    return TorSettings(
      mode: mode ?? this.mode,
      customBridges: customBridges ?? this.customBridges,
      extraConfig: extraConfig ?? this.extraConfig,
      socksPort: socksPort ?? this.socksPort,
      controlPort: controlPort ?? this.controlPort,

      connectionTimeoutSeconds: connectionTimeoutSeconds ?? this.connectionTimeoutSeconds,
      strictNodes: strictNodes ?? this.strictNodes,
      enableOnionService: enableOnionService ?? this.enableOnionService,
      virtualPort: virtualPort ?? this.virtualPort,
      source: source ?? this.source,
      lastBootstrapAt: lastBootstrapAt ?? this.lastBootstrapAt,
      lastBootstrapSeconds: lastBootstrapSeconds ?? this.lastBootstrapSeconds,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode.name,
        'customBridges': customBridges,
        'extraConfig': extraConfig,
        'socksPort': socksPort,
        'controlPort': controlPort,

        'connectionTimeoutSeconds': connectionTimeoutSeconds,
        'strictNodes': strictNodes,
        'enableOnionService': enableOnionService,
        'virtualPort': virtualPort,
        'source': source.name,
        'lastBootstrapAt': lastBootstrapAt?.toUtc().millisecondsSinceEpoch,
        'lastBootstrapSeconds': lastBootstrapSeconds,
      };

  factory TorSettings.fromJson(Map<String, dynamic> json) {
    return TorSettings(
      mode: BridgeMode.fromName(json['mode'] as String?),
      customBridges: json['customBridges'] as String? ?? '',
      extraConfig: json['extraConfig'] as String? ?? '',
      socksPort: (json['socksPort'] as num?)?.toInt() ?? 0,
      controlPort: (json['controlPort'] as num?)?.toInt() ?? 0,

      connectionTimeoutSeconds: (json['connectionTimeoutSeconds'] as num?)?.toInt() ?? 120,
      strictNodes: json['strictNodes'] as bool? ?? false,
      enableOnionService: json['enableOnionService'] as bool? ?? true,
      virtualPort: (json['virtualPort'] as num?)?.toInt() ?? 80,
      source: BridgeSource.fromName(json['source'] as String?),
      lastBootstrapAt: json['lastBootstrapAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (json['lastBootstrapAt'] as num).toInt(),
              isUtc: true,
            ),
      lastBootstrapSeconds: (json['lastBootstrapSeconds'] as num?)?.toInt(),
    );
  }
}

/// A named bundle of bridge lines offered as a one-tap preset.
class BridgePreset {
  const BridgePreset({
    required this.id,
    required this.label,
    required this.mode,
    required this.description,
    required this.bridges,
    this.source = BridgeSource.builtIn,
    this.fetchedAt,
  });

  final String id;
  final String label;
  final BridgeMode mode;
  final String description;

  /// Raw `Bridge …` lines, already in torrc syntax.
  final List<String> bridges;

  final BridgeSource source;
  final DateTime? fetchedAt;

  String get asText => bridges.join('\n');

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'label': label,
        'mode': mode.name,
        'description': description,
        'bridges': bridges,
        'source': source.name,
        'fetchedAt': fetchedAt?.toUtc().millisecondsSinceEpoch,
      };

  factory BridgePreset.fromJson(Map<String, dynamic> json) {
    return BridgePreset(
      id: json['id'] as String? ?? 'preset',
      label: json['label'] as String? ?? 'Bridges',
      mode: BridgeMode.fromName(json['mode'] as String?),
      description: json['description'] as String? ?? '',
      bridges: (json['bridges'] as List<dynamic>? ?? const <dynamic>[])
          .map((dynamic e) => e.toString())
          .toList(growable: false),
      source: BridgeSource.fromName(json['source'] as String?),
      fetchedAt: json['fetchedAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (json['fetchedAt'] as num).toInt(),
              isUtc: true,
            ),
    );
  }
}
