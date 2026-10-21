# Windows Tor runtime

This is the runtime that travels inside a Windows release of DarkFlow: the Tor
daemon, its pluggable transports and the geoip databases. It is kept out of the
`assets/` tree on purpose - see the note in `tor_runtime/README.md`.

`tool/stage_tor_runtime.ps1` copies these files into `assets/tor/` before a
Windows build, and `tool/unstage_tor_runtime.ps1` removes them again.

Do not add anything to `assets/tor/` by hand: it is a build-time directory, and
whatever is in it when an Android build runs ends up inside the APK.

The files are produced by `tool/fetch_tor_windows.ps1`, which downloads the
official Tor Expert Bundle and builds the pluggable-transport clients that the
bundle does not ship (obfs4proxy, snowflake-client, webtunnel-client,
meek-client). It verifies each binary by running it, including a real
pluggable-transport handshake, and writes `MANIFEST.json` with the source URLs
and SHA-256 sums of everything it produced.
