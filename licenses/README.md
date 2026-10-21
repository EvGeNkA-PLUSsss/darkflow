# Bundled third-party licences

DarkFlow ships Tor and several pluggable transports *inside* the application:
they are not downloaded on first run, because a censorship-circumvention tool that
depends on a second download is one blocked host away from being useless. That
makes this project a redistributor of those binaries, and their licences require
the copyright notice and the licence text to travel with them.

Their licences permit exactly this — commercial use, modification and
redistribution, provided the notice is kept — so the obligation is only to keep
the notice. This directory is that notice.

## What is here

| Directory | Component | Licence |
|---|---|---|
| `tor/` | Tor daemon (`tor.exe`, `libtor.so`) | BSD-3-Clause |
| `lyrebird/` | obfs4 pluggable transport | BSD-2-Clause |
| `snowflake/` | Snowflake pluggable transport | BSD-3-Clause |
| `webtunnel/` | WebTunnel pluggable transport | BSD-3-Clause |
| `meek/` | meek pluggable transport | BSD-3-Clause |
| `conjure/` | conjure pluggable transport | BSD-3-Clause |
| `flutter-libraries/` | The Dart packages listed by `AboutScreen` | see each file |

## How to refresh it

The Dart package texts are copied out of the pub cache, so they match the versions
actually resolved by `pubspec.lock` rather than whatever was current when somebody
last looked:

```
pwsh -File tool/collect_licences.ps1
```

The Tor and pluggable-transport texts are fetched from upstream by
`tool/fetch_tor_windows.ps1` when it pulls the binaries. If that script has not
been run on this machine, the directories below will say so instead of pretending
to hold a licence.

## What is not here

* **Flutter itself.** The Flutter engine and framework are BSD-3-Clause, and the
  licence ships inside every Flutter build already. It is listed in
  `AboutScreen` for completeness.
* **Anything linked only for development** — the test and linting packages — since
  none of it is present in a published artifact.
* **The geoip databases** bundled with Tor. They are data, distributed by the Tor
  Project under the same terms as the daemon.

## A note on what DarkFlow is not

DarkFlow is not affiliated with, endorsed by, or connected to the Tor Project.
It is an independent application that uses Tor as its transport.
