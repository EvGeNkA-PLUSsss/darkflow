# Release checklist

Everything needed to produce a DarkFlow release, in the order it has to happen.
Each step says what it is for, because the ones that look like ceremony are the
ones that catch a mistake nobody notices until a user does.

The short version:

```
pwsh -File tool/release.ps1
```

That runs the checks, builds both platforms, places the Tor runtime, prints the
SHA-256 of every artifact and says plainly whether each one is signed. The rest of
this document explains what it does and what still has to be done by hand.

---

## 1. Before building

### Decide the version

`pubspec.yaml` is the only place the version lives:

```yaml
version: 0.1.0+1
#        ^     ^
#        |     build number: increment for every uploaded build, never reuse
#        release name
```

`tool/release.ps1` reads this line and passes it to the Dart compiler, so the
About screen, the diagnostic report and the Android manifest all agree. There is
no second copy to update.

Use [semantic versioning](https://semver.org/): breaking changes to the wire
protocol or the vault format bump the major, a new feature bumps the minor, a fix
bumps the patch. The build number must increase for every build uploaded to a
store — a store rejects a duplicate.

### Check that the tree is clean

```
flutter analyze
flutter test
```

`tool/release.ps1` runs both unless given `-SkipTests`, which exists only for
iterating on packaging.

### Confirm the Tor runtime is present

```
ls tor_runtime/windows/tor.exe
```

If it is missing, `tool/fetch_tor_windows.ps1` downloads the official Tor Expert
Bundle and builds the pluggable transports from upstream sources, verifying each
binary by running it. See `tor_runtime/README.md` for why the runtime lives
outside the asset tree.

---

## 2. Windows

### Build

```
pwsh -File tool/release.ps1 -Target windows
```

This builds, then runs `tool/stage_tor_runtime.ps1 -Configuration Release`, which
copies `tor_runtime/windows/*` into `build\windows\x64\runner\Release\tor\`. That
directory is where the application looks for the daemon; it is not part of the
Flutter asset bundle, because Flutter copies every declared asset directory into
every platform's build — which is how a 119 MB Windows runtime used to end up
inside the Android APK. See the note in `lib/src/tor/tor_paths.dart`.

### Package

The build output is a directory, not a single file:

```
build\windows\x64\runner\Release\
    darkflow.exe
    tor\                 <- the Tor runtime, 119 MB
    data\                <- Flutter assets
    *.dll
```

Distribute it as a ZIP, or wrap it in an installer. **No installer is configured
in this repository** — producing one (Inno Setup, WiX, MSIX) is a decision that
has not been made, and the choice affects code signing and auto-update. The ZIP is
the honest minimum:

```powershell
Compress-Archive -Path build\windows\x64\runner\Release\* `
                 -DestinationPath darkflow-0.1.0-windows-x64.zip
```

### Sign it

Unsigned, Windows SmartScreen warns every user that the application is
unrecognised, and the warning is indistinguishable from the one a malicious
binary produces. A certificate is required for a public release.

With a certificate in the current user's store:

```
pwsh -File tool/release.ps1 -Target windows -CertThumbprint <SHA1-thumbprint>
```

`signtool.exe` ships with the Windows SDK. The script timestamps the signature
through DigiCert's RFC 3161 service, because a signature without a timestamp stops
being verifiable when the certificate expires.

Sign `darkflow.exe` **and** the Tor binaries in `tor\` if the certificate allows
it — a signed launcher next to unsigned children still triggers a warning when one
of them starts.

### What to check by hand

Launch the release build and press Connect. It should reach "Connected" or show a
specific bootstrap failure. If it reports the Tor daemon as missing, the staging
step did not run.

```
build\windows\x64\runner\Release\darkflow.exe
```

---

## 3. Android

### Create the signing key — once, ever

```
keytool -genkeypair -v `
  -keystore android\darkflow-release.jks `
  -alias darkflow -keyalg RSA -keysize 4096 -validity 10000 -storetype JKS
```

Then copy the template and fill it in:

```
Copy-Item android\keystore.properties.example android\keystore.properties
```

`android/keystore.properties` and `*.jks` are in `.gitignore`. Both must stay out
of version control: the keystore is the identity of every future release, and
losing it means an existing installation can never be updated — Android refuses an
update signed with a different key, and the only way forward would be a new
application id.

Back the keystore up somewhere you will still have it in five years.

If the plan is Google Play, enrol in Play App Signing instead: Play then holds the
release key and this keystore becomes the replaceable *upload* key.

### Build and verify

One build detail that will bite anyone editing the Gradle script: the release build
has **core library desugaring enabled**. `flutter_local_notifications` declares it in
its AAR metadata, so `checkReleaseAarMetadata` fails the build without both
`isCoreLibraryDesugaringEnabled = true` and the `coreLibraryDesugaring(...)` runtime
dependency in `android/app/build.gradle.kts`. The failure reads "Dependency
':flutter_local_notifications' requires core library desugaring to be enabled", which
names the plugin rather than the two lines that are missing.

```
pwsh -File tool/build_android.ps1 -Release
```

The script:

1. refuses to build if `jniLibs/arm64-v8a/libtor.so` is missing, because the
   result installs cleanly and fails on the first Connect;
2. warns loudly when `android/keystore.properties` is absent, because that build is
   debug-signed and cannot be published;
3. opens the finished APK and fails if any `assets/tor/windows/*` entry is inside
   it, and fails again if `libtor.so` is not;
4. prints the artifact size and its SHA-256.

Sizes to expect: roughly 45 MB for the APK. A build near 93 MB means the Windows
runtime is inside it.

### The `.aab` for Google Play

```
pwsh -File tool/build_android.ps1 -Release -AppBundle
```

Play requires an App Bundle rather than an APK. The verification steps above run
against whichever artifact was produced.

### What to check by hand

Install on an actual arm64 device and press Connect. An emulator will not do:
`libtor.so` is arm64-v8a only, and the ABI filter in `android/app/build.gradle.kts`
is deliberate — an APK that installs on a 32-bit phone and then cannot start Tor is
worse than one that will not install.

---

## 4. Before publishing

### Record the artifact hashes

`tool/release.ps1` prints a SHA-256 for each artifact. Put them in the release
notes. Without them there is no way to tell a genuine download from a modified one,
which for this application is the difference between a working install and
something that phones home.

### Update the notices

- [ ] `licenses/flutter-libraries/` — re-run `tool/collect_licences.ps1` after any
      dependency change. The file names carry the versions, so a stale notice is
      visible rather than silent.
- [ ] `licenses/PROVENANCE.md` — check whether the Tor version in
      `tor_runtime/windows/MANIFEST.json` changed, and re-verify the Tor licence
      against upstream.
- [ ] **The pluggable-transport licence texts are not yet collected.** They are
      BSD-2-Clause and BSD-3-Clause, which require the notice to be reproduced.
      `licenses/PROVENANCE.md` lists the upstream locations. This is a real gap,
      not a formality.

### Confirm the About screen

It lists the bundled components and their licences, and it is the one place a user
can check what they are running. Open it and compare against `pubspec.yaml`.

---

## 5. Known gaps

Stated plainly, because a release note that hides these is worse than none.

| Gap | Consequence | Needed for |
|---|---|---|
| **No installer for Windows** | Users get a ZIP and run an `.exe` from it. | A polished release |
| **Unsigned by default** | SmartScreen warns every user. | A public release |
| **Pluggable-transport licences not collected** | Notice requirement not met. | Any redistribution |
| **No privacy policy in the tree** | Stores require one for an app with permissions. | Google Play |
| **No store listing assets** | Screenshots, feature graphic, description. | Google Play |
| **No auto-update** | Users must notice and re-download. | Maintenance |
| **Tor bootstrap never verified end to end on a real network from this build** | The network available during development is censored and blocks the directory authorities; bootstrap reaches `conn_done` and stops. Everything up to that point is exercised. | Confidence |
| **iOS is not built** | App Store policy forbids shipping executable Tor. It needs a different transport, not a build fix. | iOS |
| **Only arm64-v8a on Android** | No 32-bit or x86_64 devices. Deliberate. | Broader reach |
| **Group chats** | Not implemented. | Beyond 1.0 |
| **Notifications only while the app is running** | DarkFlow receives over Tor through a daemon inside its own process, so there is no code alive to be woken once the system reclaims it and no push service to deliver from. There is no background service: keeping the process alive for ever was tried and removed, because it cost a permanent notification and battery for alerts that still could not be guaranteed. | Always-on alerts |
| **No notifications on Windows** | The notification plugin's Windows implementation needs the ATL headers, which are not part of a standard Flutter desktop toolchain. Rather than make the Windows build depend on a Visual Studio workload, notifications are reported as unavailable there and the settings switch is disabled with a reason. | Parity |
| **Calls were removed** | Voice and video over Tor need an Opus-over-TCP media relay with its own congestion handling. Rather than ship a feature that connects sometimes, the call code was deleted. No interface claims it exists. | Calls |
| **Delivery is verified by tests, not between two devices** | The storage ordering, the conversation creation, the shared dial and the inbound handshake are all covered, and each fix is checked by breaking it and watching a test fail. Two machines exchanging messages over a real onion circuit have not been observed. | Confidence |

---

## 6. Rolling back

There is no server, so a bad release cannot be withdrawn — only superseded.

* **Android.** Increment the build number and publish a new build. A store will
  not let you upload a lower `versionCode`, so the rollback *is* the next release.
* **Windows.** Publish the previous ZIP again. Nothing auto-updates, so a user who
  has not downloaded the broken build is unaffected.
* **Both.** If a release breaks the vault format, a user who opened it with the new
  build cannot go back: the header carries a format version and an older build
  refuses it with a clear message rather than corrupting anything. See
  `VaultHeader.fromJson` in `lib/src/crypto/key_vault.dart`. Test a format change
  against a copy of a real vault before shipping it.

Keep the previous release's artifacts and hashes. They are the rollback.

---

## 7. Reference

| Task | Command |
|---|---|
| Full release, both platforms | `pwsh -File tool/release.ps1` |
| Windows only, signed | `pwsh -File tool/release.ps1 -Target windows -CertThumbprint <SHA1>` |
| Android APK | `pwsh -File tool/build_android.ps1 -Release` |
| Android App Bundle | `pwsh -File tool/build_android.ps1 -Release -AppBundle` |
| Place the Tor runtime beside a Debug build | `pwsh -File tool/stage_tor_runtime.ps1` |
| Refresh the bundled Tor | `pwsh -File tool/fetch_tor_windows.ps1` |
| Refresh the licence notices | `pwsh -File tool/collect_licences.ps1` |
| Regenerate the icons | `python tool/make_icons.py` |
| Verify Tor really starts | `dart run tool/smoke_tor.dart` |
| Measure the crypto cost on this hardware | `dart run tool/bench_crypto.dart` |
