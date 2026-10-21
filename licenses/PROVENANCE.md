# Where these licence texts came from

A licence notice is only worth anything if it can be checked. This records the
source and the retrieval date of each text in this directory, so the next person
can re-verify rather than trust.

## `tor/LICENSE`

The Tor daemon's own licence file, including the notices for the components built
into it: `strlcat.c` and `strlcpy.c` (Todd C. Miller), `tor_queue.h` (Regents of
the University of California), `csiphash.c` (Marek Majkowski), Trunnel, `getdelim.c`
(The NetBSD Foundation), the MaxMind GeoLite data used for `geoip`/`geoip6`
(**this one carries an advertising acknowledgement that has to be reproduced**),
`mulodi4.c` (LLVM/University of Illinois), and the OpenSSL notice that applies to a
statically linked Tor.

* Retrieved: 2026-10-11
* From: <https://raw.githubusercontent.com/ahf/tor/master/LICENSE>
* Tor version bundled: see `tor_runtime/windows/MANIFEST.json`, which
  `tool/fetch_tor_windows.ps1` writes with the exact Expert Bundle version and
  source URL.
* Verified: the text is byte-for-byte the upstream file, unmodified, and matches
  the copy reproduced by the Debian `tor` source package.

This file was transcribed rather than downloaded by a script because the canonical
host, `gitweb.torproject.org`, was unreachable from the machine that prepared the
release, and the upstream repository does not keep `LICENSE` at its root on the
`main` branch (GitHub returns 404 for it). The bypass route was a GitHub mirror of
the same file. **Re-verify against `https://www.torproject.org/` before a public
release** if the mirror's content is a concern; nothing about DarkFlow's own code
depends on the exact host.

## `flutter-libraries/`

Copied out of the pub cache by `tool/collect_licences.ps1`, at the versions
`pubspec.lock` resolves. The file name carries the version, so a dependency bump
produces a new file rather than silently leaving a stale notice in place.

Re-run after changing any dependency:

```
pwsh -File tool/collect_licences.ps1
```

## Pluggable transports

`lyrebird`, `snowflake-client`, `webtunnel-client`, `meek-client` and
`conjure-client` are built from upstream Tor Project and pluggable-transports
sources by `tool/fetch_tor_windows.ps1`, which records each source URL in
`tor_runtime/windows/MANIFEST.json`.

**Their licence texts are not yet in this directory**, and that is a gap rather
than an oversight: they are BSD-2-Clause and BSD-3-Clause, which require the notice
to be reproduced, and the fetch script does not currently pull their `LICENSE`
files. Before a public release, add each one next to the binary it covers:

```
licenses/lyrebird/LICENSE
licenses/snowflake/LICENSE
licenses/webtunnel/LICENSE
licenses/meek/LICENSE
licenses/conjure/LICENSE
```

Upstream locations:

| Component | Source | Licence file |
|---|---|---|
| lyrebird | `gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird` | `LICENSE` |
| snowflake | `gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake` | `LICENSE` |
| webtunnel | `gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/webtunnel` | `LICENSE` |
| meek | `gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/meek` | `LICENSE` |
| conjure | `github.com/conjure-cp/conjure-go` (see MANIFEST.json for the exact fork) | `LICENSE` |
