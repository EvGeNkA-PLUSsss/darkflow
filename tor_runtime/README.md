# The bundled Tor runtime

The Tor daemon, its pluggable transports and the geoip databases live here, and
**not** under `assets/`, because of how Flutter bundles assets.

## Why it is not in `assets/`

Flutter copies every asset directory declared in `pubspec.yaml` into every build,
on every platform. There is no conditional syntax in pubspec and no Gradle
exclusion for Flutter assets (they are merged as Android *assets*, not resources).
`pubspec.yaml` therefore used to declare `assets/tor/windows/`, and the result was
that a 119 MB Windows runtime was copied into the Android APK — where none of it
can execute, because Android refuses to run code from app-private storage and
ships Tor as `jniLibs/arm64-v8a/lib*.so` instead.

Declaring `assets/tor/android/` as well does **not** help: it was measured, and
Flutter bundles both directories regardless of the target platform. Two separate
directories would only work if the bundler filtered by platform, and it does not.

So the runtime is kept out of the asset tree here, and the build stages it:

* `windows/` — the runtime that travels inside a Windows release.
* `android/` — a note explaining that Android needs nothing from here.

## How it gets into a build

```
pwsh -File tool/stage_tor_runtime.ps1 -Platform windows   # copies into assets/tor/
pwsh -File tool/unstage_tor_runtime.ps1                   # removes assets/tor/
```

`tool/release.ps1` and the Windows build path call the first one automatically, so
an ordinary release needs no extra steps. `tool/build_android.ps1` calls the
unstage step before building and checks the finished APK to prove that no Windows
binary is inside it.

If you run a bare `flutter build windows` or `flutter run -d windows` without
staging, the app builds and launches and then reports

> The bundled Tor daemon is missing from …

at the moment you press Connect — a clear failure rather than a silent one, and
the staging script is the fix.

## Refreshing the binaries

`tool/fetch_tor_windows.ps1` downloads the official Tor Expert Bundle and builds
the pluggable transports from upstream sources. It writes into
`tor_runtime/windows/` and verifies that every binary starts, including a real
pluggable-transport handshake. Point it here when upgrading Tor:

```
pwsh -File tool/fetch_tor_windows.ps1
```
