/// Checks a hand-typed or pasted bridge line before Tor ever sees it.
///
/// ## Why this exists
///
/// A bridge line reaches `torrc` verbatim. Tor then does one of two things: starts, or
/// **refuses to start at all**. There is no middle ground, and the refusal is not partial —
/// one malformed line stops the daemon, so the user's network is gone until they find and
/// remove it.
///
/// That is not hypothetical. It was reported as "Tor error, fixed by recreating the
/// account", and reproduced against the real daemon: a line whose fingerprint was four
/// characters instead of forty produced
///
/// ```
/// [warn] Key digest for Bridge is wrong length.
/// [warn] Failed to parse/validate config: Bridge line did not parse. See logs for details.
/// [err] Reading config failed--see warnings above.
/// ```
///
/// and `tor.exe` exited with code 1. Worse, the message the user was shown was the last of
/// those three — the only one that names no cause at all.
///
/// So this validates the line where it is typed, and the settings screen refuses to save
/// one it cannot parse. Tor's own log remains the authority; this only keeps a
/// configuration that is certain to fail from ever being written.
///
/// ## What it checks, and what it deliberately does not
///
/// It checks the structure: a known transport keyword, then an address, then a fingerprint
/// of exactly the right length and alphabet, then the per-transport key material. It does
/// **not** check that the bridge is reachable, that the fingerprint belongs to a real
/// bridge, or that the certificate string decodes — those need the network and are Tor's
/// business. A line that passes here can still fail to connect; a line that fails here can
/// never have worked.
library;

/// Why a bridge line cannot be used, or null when it looks well formed.
///
/// The returned text is written for the person who pasted the line: it says what is wrong
/// and what the line should look like, because "invalid" on its own leaves them with a
/// daemon that will not start and no idea which of the fields to look at.
String? bridgeLineProblem(String line) {
  var text = line.trim();
  if (text.isEmpty) return 'The line is empty.';

  // A leading `Bridge` keyword is optional — both forms are pasted in practice, and
  // `tor_config` adds it when it is missing.
  text = text.replaceFirst(RegExp(r'^bridge\s+', caseSensitive: false), '').trim();
  if (text.isEmpty) {
    return 'The line has the word "Bridge" and nothing after it.';
  }

  final parts = text.split(RegExp(r'\s+'));
  final keyword = parts.first.toLowerCase();

  // A plain `IP:PORT FINGERPRINT` bridge, the oldest form and still valid.
  //
  // Checked before the transport switch, and that order matters: the first token of a
  // plain line is an address, so the switch would otherwise call `192.0.2.10:443` an
  // unsupported transport and reject a perfectly good bridge. The distinction is that a
  // transport keyword is never a digit-initial token containing a colon.
  if (_looksLikeAddress(parts.first)) {
    final addressProblem = _addressProblem(parts.first, what: 'the bridge address');
    if (addressProblem != null) return addressProblem;
    if (parts.length < 2) {
      return 'A plain bridge line needs a fingerprint after the address, otherwise Tor '
          'cannot check that it is talking to the bridge it meant to.';
    }
    return _fingerprintProblem(parts[1]);
  }

  switch (keyword) {
    case 'obfs4':
      return _checkedLine(
        parts,
        transport: 'obfs4',
        // obfs4  IP:PORT  FINGERPRINT  cert=…  [iat-mode=…]
        minimumParts: 4,
        requires: <String>['cert='],
        describe: 'obfs4 <address:port> <40-character fingerprint> cert=<key> '
            '[iat-mode=0|1|2]',
      );
    case 'webtunnel':
      return _checkedLine(
        parts,
        transport: 'webtunnel',
        // webtunnel  ENDPOINT  FINGERPRINT  url=…
        //
        // The endpoint is written as an address in the lines the Tor Project hands out —
        // `webtunnel [2001:db8::1]:443 <fingerprint> url=https://… ver=0.0.7` — and the
        // `url=` parameter carries the https URL that the transport actually requests. An
        // earlier version of this check demanded a URL in the first position and rejected
        // the real, working format, which is worse than having no check at all: it would
        // have blocked the people who need bridges most from using them.
        //
        // A bare URL in the first position is accepted too, because hand-written lines are
        // pasted both ways.
        minimumParts: 3,
        addressMayBeUrl: true,
        requires: <String>['url='],
        describe: 'webtunnel <address:port> <40-character fingerprint> url=<https://…> '
            '[ver=…]',
      );
    case 'snowflake':
      return _checkedLine(
        parts,
        transport: 'snowflake',
        minimumParts: 2,
        // snowflake  FINGERPRINT  url=…  ice=…  utls=…
        addressOptional: true,
        requires: <String>['url='],
        describe: 'snowflake <40-character fingerprint> url=<broker> [ice=…] [utls=…]',
      );
    case 'meek_lite':
    case 'meek':
      return _checkedLine(
        parts,
        transport: 'meek_lite',
        minimumParts: 3,
        requires: <String>['url=', 'front='],
        describe: 'meek_lite <address:port> <40-character fingerprint> '
            'url=<…> front=<…>',
      );
    default:
      // An unrecognised first token is either a transport this build cannot register — so
      // no `ClientTransportPlugin` line would be written and Tor would have a bridge it
      // cannot speak to — or a plain line that lost its `Bridge` keyword.
      return 'The transport "$keyword" is not one DarkFlow can start. Use obfs4, '
          'webtunnel, snowflake or meek_lite, or paste a plain bridge line that begins '
          'with an address.';
  }
}

/// Shared shape check for the transports that take an address and a fingerprint.
String? _checkedLine(
  List<String> parts, {
  required String transport,
  required int minimumParts,
  required String describe,
  bool addressMayBeUrl = false,
  bool addressOptional = false,
  List<String> requires = const <String>[],
}) {
  if (parts.length < minimumParts) {
    return 'The $transport line is incomplete. It should look like: $describe';
  }

  var index = 1;
  if (!addressOptional) {
    final address = parts[index];
    final String? problem;
    if (addressMayBeUrl) {
      // Either shape is real, so the only unacceptable answer is one that is neither. The
      // error names both, because a user whose line is a URL and is told it needs an address
      // — or the reverse — has been actively misled.
      problem = _addressProblem(address, what: 'the bridge address') == null
          ? null
          : _urlProblem(address) == null
              ? null
              : 'Could not read "$address" as either an address or an https URL. It '
                  'should be an address and a port, like 192.0.2.10:443, or a full '
                  'https:// URL.';
    } else {
      problem = _addressProblem(address, what: 'the bridge address');
    }
    if (problem != null) return problem;
    index++;
  }

  // The fingerprint is the field Tor validates first and the one that is wrong most often,
  // because it is the easiest to truncate: copied from a page that elided the middle, or
  // pasted from a source that showed only its first characters.
  final fingerprintProblem = _fingerprintProblem(parts[index]);
  if (fingerprintProblem != null) return fingerprintProblem;

  for (final requirement in requires) {
    if (!parts.skip(index).any((String part) => part.startsWith(requirement))) {
      return 'The $transport line is missing "$requirement". It should look like: '
          '$describe';
    }
  }
  return null;
}

/// True when a token is an `address:port` rather than a transport keyword.
///
/// Used to tell a plain bridge line from a named transport. A keyword is a word; an address
/// contains a colon and its host part starts with a digit or a bracket. Checking for the
/// colon alone would misread a WebTunnel URL, which is why the scheme is excluded.
bool _looksLikeAddress(String token) {
  if (!token.contains(':')) return false;
  if (token.contains('://')) return false;
  return _addressProblem(token, what: 'the bridge address') == null;
}

/// The fingerprint must be forty hexadecimal characters.
///
/// Forty is the length of a SHA-1 relay digest, which is what a bridge fingerprint is. Tor
/// validates this before anything else and refuses to start when it is wrong — "Key digest
/// for Bridge is wrong length" — which is why this is a separate, precisely worded check
/// rather than part of the shape test.
String? _fingerprintProblem(String fingerprint) {
  final trimmed = fingerprint.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
  if (fingerprint.length != 40) {
    return 'The fingerprint must be exactly 40 characters, and this one is '
        '${fingerprint.length}. That is the check Tor fails on first — it says '
        '"Key digest for Bridge is wrong length" and then refuses to start at all.';
  }
  if (trimmed.length != 40) {
    return 'The fingerprint must be 40 hexadecimal characters, and this one contains '
        'something else.';
  }
  return null;
}

/// `1.2.3.4:443`, `[2001:db8::1]:443`, or a hostname with a port.
String? _addressProblem(String value, {required String what}) {
  final match = RegExp(r'^(?:\[[0-9A-Fa-f:]+\]|[^\s:]+):(\d{1,5})$').firstMatch(value);
  if (match == null) {
    return 'Could not read $what "$value". It needs to be an address and a port, like '
        '192.0.2.10:443.';
  }
  final port = int.tryParse(match.group(1)!);
  if (port == null || port < 1 || port > 65535) {
    return 'The port in "$value" is not a number between 1 and 65535.';
  }
  return null;
}

/// A WebTunnel bridge is reached through a URL, not an address.
String? _urlProblem(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return 'Could not read the WebTunnel URL "$value". It needs to be a full URL, like '
        'https://example.com/path.';
  }
  if (uri.scheme != 'https') {
    // Tor refuses a non-TLS WebTunnel URL, and a plain-http one would defeat the point of
    // the transport.
    return 'A WebTunnel URL has to start with https://, and "$value" does not.';
  }
  return null;
}
