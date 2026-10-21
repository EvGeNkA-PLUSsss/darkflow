# DarkFlow

A peer-to-peer messenger that lives on the Tor network. There is no server:
every account is its own Tor onion service, and an account's onion address is
its username.

Built with Flutter 3.44 / Dart 3.12, targeting **Windows, Linux, macOS, Android
and iOS** from one codebase.

---

## What actually works today

Verified on Windows, not asserted:

| Area | State |
|---|---|
| All nine screens from the design mockups | Built, with geometry measured from the SVG sources |
| Tor daemon bundled and managed | **Verified.** Tor 0.4.9.13 starts, `--verify-config` passes, control port opens, cookie authentication succeeds |
| Own onion service | **Verified.** Tor publishes a v3 hostname; `tool/smoke_tor.dart` prints it |
| Network reachability | **Verified as far as this network allows.** Bootstrap reaches `conn_done` (10%, "Connected to a relay") before the censored uplink blocks the directory authorities |
| Bridges: obfs4, WebTunnel, Snowflake, meek, conjure | Binaries bundled and each one verified to complete a real pluggable-transport handshake |
| Argon2id password → master key → AES-256-GCM for everything | Working, covered by tests |
| Six-digit PIN unlock bound to the OS keystore | Working, covered by tests |
| Encrypted local store (no SQLite, no plaintext on disk) | Working, covered by tests |
| Encrypted attachment vault + protected-files screen | Working, covered by tests |
| P2P protocol over Tor: handshake, session ratchet, framing | Working, covered by tests |
| Identity pinning (trust on first use) with key-change detection | Working |
| Mesh: relay hand-off, mailbox pull, outbox retry with backoff | Implemented |
| File sending (encrypted chunks) | Implemented |
| Voice messages (record, waveform, playback) | Implemented |
| Delivery and read receipts | Implemented. The receiver sends them; the sender's bubble goes single tick → double tick → read |
| Replying to a message (quote, cancel, Escape) | Implemented |
| Drafts that survive closing the thread or the app | Implemented |
| Search inside a conversation, with the match marked | Implemented |
| **Voice/video calls** | **Removed.** The feature was cut rather than finished; see "Honest limitations" |
| Group chats | Not built (one-to-one only) |
| iOS | The code targets it, but iOS forbids shipping an executable Tor, so it needs a different transport. See below. |

`flutter test` runs **528 tests** (one skipped, and the skip is explained in
`docs/RELEASE.md`), and `dart run tool/smoke_tor.dart` walks the real Tor startup
path.

---

## Running it

The Flutter SDK lives at `D:\flutter` on this machine and had to be registered
with git first:

```powershell
git config --global --add safe.directory D:/flutter
```

Then:

```powershell
cd D:\Users\EvGeN\Desktop\darkflow
flutter pub get
flutter test                        # 528 tests
dart run tool/smoke_tor.dart        # real Tor startup + hidden service

# The Tor runtime is not a Flutter asset, so a bare `flutter run` needs it staged
# beside the built executable first. See "Bundled Tor" below.
flutter build windows --debug
pwsh -File tool/stage_tor_runtime.ps1
flutter run -d windows
```

To produce a distributable build:

```powershell
pwsh -File tool/release.ps1                 # both platforms, with checks
pwsh -File tool/release.ps1 -Target windows # Windows only
```

The result for Windows is a directory, not a single file — the Tor runtime and
the Flutter engine live beside the executable:

```
build\windows\x64\runner\Release\
    darkflow.exe        89 KB   the launcher
    tor\                119 MB  the Tor daemon and its pluggable transports
    data\               12 MB   Flutter assets
    *.dll                       the engine and the plugins
```

Roughly 151 MB in total, and Tor is almost all of it. `docs/RELEASE.md` has the
full checklist: signing, the Android keystore, what to verify before publishing,
and the list of things still missing.

> **Bundled Tor.** The daemon is deliberately *not* a Flutter asset. Flutter copies
> every asset directory declared in `pubspec.yaml` into every platform's build,
> with no conditional syntax and no Gradle exclusion for Flutter assets, so a
> 119 MB Windows runtime declared that way travelled inside the Android APK —
> where none of it can execute. Leaving it undeclared is not an answer either: an
> undeclared directory is not bundled at all. It therefore lives in
> `tor_runtime/windows/` and is copied beside the executable by
> `tool/stage_tor_runtime.ps1`, which `tool/release.ps1` runs for you. The APK
> went from 93 MB to 45 MB when this changed.

> **Machine notes.** Two environment problems had to be fixed before a Windows
> build would work, and neither is a project defect:
> `C:\Users\<user>\AppData\Roaming\NuGet\NuGet.Config` shipped with an *empty*
> `<packageSources>`, so `audioplayers_windows` could not restore
> `Microsoft.Windows.ImplementationLibrary`; adding nuget.org fixed it
> (`dotnet nuget add source https://api.nuget.org/v3/index.json -n nuget.org`).
> And a stale `build/windows` CMake cache can hold a
> `CMAKE_INSTALL_PREFIX` of `C:/Program Files/darkflow`, which fails the install
> step with "maybe need administrative privileges" — delete `build/windows` and
> rebuild.

### Android

Build the APK with the script, not with `flutter build apk` directly:

```
pwsh -File tool/build_android.ps1            # debug
pwsh -File tool/build_android.ps1 -Release   # release
```

The script moves the Windows Tor runtime out of `assets/tor/windows/` for the
duration of the build and restores it afterwards. Flutter bundles every asset
declared in `pubspec.yaml` on every platform and pubspec has no conditional
syntax, so without this the APK carries 119 MB of `.exe` files that cannot run
on a phone. A Gradle exclusion is not possible: `packaging.resources` does not
apply to Flutter assets (they are merged as Android *assets*, not resources) and
this AGP version has no `packaging.assets` block. With the script the APK is
**61.5 MB**; without it, 221 MB.

Four things are needed for the Android build, and each one fails in a way that
does not obviously point at itself:

1. **JDK 17 or newer.** `flutter config --jdk-dir="C:\Program Files\Android\Android Studio\jbr"`.
   The system `java` on this machine is 8, which the Android Gradle Plugin
   refuses.
2. **`kotlin.incremental=false`** in `android/gradle.properties`. Kotlin's
   incremental compiler stores relative paths in its caches, and this project is
   on `D:` while the Pub cache is on `C:`. Relativising across two drive letters
   throws, which aborts `compileDebugKotlin` for every plugin at about 25% of the
   build.
3. **`useLegacyPackaging = true`** in `android/app/build.gradle.kts`. Since AGP
   4.2 native libraries are left compressed inside the APK and mapped from
   there, which is fine for `dlopen` and fatal for `exec` — Tor is a child
   process, so `nativeLibraryDir` has to contain real files.
4. **`INTERNET` in the main manifest.** The Flutter template declares it only in
   the `debug` and `profile` manifests, because the tool needs it for hot
   reload. A release build would therefore install and then be unable to open a
   socket.

Tor for Android is `libtor.so`, taken from
`info.guardianproject:tor-android:0.4.9.13.2` on Maven Central — the same Tor
0.4.9.13 the Windows bundle ships. It goes in
`android/app/src/main/jniLibs/arm64-v8a/` and is executed straight from the
read-only native library directory, because Android forbids running a binary
from the writable data directory. The path has a per-install hash in it and is
not derivable from Dart, so `MainActivity.kt` answers a `darkflow/runtime`
method channel with `ApplicationInfo.nativeLibraryDir`.

Only **arm64-v8a** is built. The other ABIs have no Tor binary, and an APK that
installs on a 32-bit phone and then fails when the user presses Connect is worse
than one that refuses to install.

### First run

Tor is never started for the user. That is deliberate: on a censored network a
bootstrap stalls at 10%, and watching that happen before you have had a chance
to configure a bridge is a bad first impression. So the first run is explicitly
two steps.

1. **Create Account** — pick a display name.
2. **Create password** — this is the one that matters. Argon2id stretches it
   into the key that wraps the master key. It is deliberately **not
   selectable**: a password that cannot be copied cannot end up in a clipboard
   history or a screen recording. The screen submits itself once both fields
   agree, because with the confirmation typed there is nothing left to decide.
3. **Tor Bridge Settings** — choose how to reach the network: `obfs4`,
   `WebTunnel`, `Snowflake`, `meek`, or paste your own `Bridge …` lines. **Next**
   applies the choice and moves on. Nothing connects yet.
4. **Connect to Tor Network** — press **Connect**. Only now does the daemon
   start. If it fails, the primary action becomes **Retry** and the reason is
   read out of Tor's own log rather than reported as "exited with code 1".

There is exactly one secret. An earlier version also offered a six-digit PIN as a
second way into the same master key, mixed with a random secret held in the
platform keystore; it was removed. A PIN is only defensible while that secret
cannot leak, and DPAPI and the Android Keystore are both transparent to any
process already running as the user — so what remained was a six-digit path to
the master key, which is worse than no second path at all. Vault files written
by that version still open with the password; the unused PIN fields are ignored
on the way in.

**Two wrong passwords erase everything.** The counter is kept on disk next to the
vault, so restarting the app does not reset it — that would make the mechanism
decorative. The first failure warns and says how many attempts are left.

Your onion address appears in **Settings → My profile** once Tor has published
the service, and can be shared as text or as a QR code. Until then it is empty,
because the address genuinely does not exist yet.

### Why there are no bridge addresses in the box

The presets choose a *transport*, not an address list. Bridge lines are rotated
by the Tor Project precisely because censors block them, so a list baked into a
release is stale within weeks and gives users a false sense of working access —
worse than an empty box, because it hides the problem. Paste addresses obtained
from BridgeDB, or ask someone who has them. A preset with an empty box
deliberately does **not** produce `UseBridges 1`: Tor would start, find nothing
to connect to, and sit at 0% forever.

---

## Architecture

### Key hierarchy

The rule is that the password is the only thing a human remembers, and
everything else is derived or wrapped from it.

```
        password                     six-digit PIN
            │                              │
      Argon2id (64 MiB, t=3, p=2)     Argon2id + device secret
            │                        (secret lives in the OS keystore)
            ▼                              ▼
        KEK_password                   KEK_pin
            │                              │
            └──────── wraps ───────────────┘
                       │
                  MASTER KEY  (256 random bits, never written unwrapped)
                       │
      ┌────────────────┼────────────────┬─────────────────┐
      ▼                ▼                ▼                 ▼
 HKDF "db"       HKDF "files"     HKDF "identity"   HKDF "mesh"
 record store    attachments      account keys      relay bookkeeping
```

Both wraps protect the *same* master key with AES-256-GCM, so changing the
password re-wraps the key instead of re-encrypting your history. Written to
`vault.json`; the master key itself never appears on disk.

**Why six digits are acceptable.** A PIN has a million possibilities — trivially
exhausted offline. The PIN-derived key is therefore mixed with a random *device
secret* held outside the vault. An attacker with a copy of `vault.json` but not
the device cannot mount the attack at all. `test/crypto/key_vault_test.dart`
proves this: the correct PIN with the wrong device secret is refused.

Where that secret lives depends on the platform, and the difference is real, so
the app reports it rather than hiding it:

| Platform | Mechanism | Strength |
|---|---|---|
| Windows | DPAPI (`CryptProtectData`) through `dart:ffi` | Sealed to the user account — a copied file is useless elsewhere |
| Linux / macOS / Android / iOS | A file readable only by its owner | Weaker: anyone with access to the account can read it |

`flutter_secure_storage` would have unified this, but its Windows plugin
includes `atlstr.h`, so `flutter build windows` fails with `error C1083` unless
the C++ ATL component is installed. DPAPI is the API that plugin would have
called anyway, so calling it directly costs nothing and removes a dependency.

### Files

Every record is sealed individually:

```
[ magic "DF" ][ version ][ payloadLength : uint32 ][ version ][ idLength ][ id ][ sealed ]
                                                       └── sealed = nonce ‖ ciphertext ‖ tag
```

The record's collection and id are bound in as **associated data**, so a
ciphertext cannot be moved between collections, between accounts, or replayed
under another key. Collections are append-only with periodic compaction, which
means a crash can only damage the last record — and the reader drops a torn tail
rather than guessing.

Attachments are chunked at 256 KiB and each chunk carries its own nonce and its
index in the associated data, so chunks cannot be reordered, duplicated or
removed unnoticed. Decrypted working copies go to a cache directory that is
wiped on every lock.

### Network

There is no server, so delivery is the hard part.

```
   Alice                     Bob's relay                Bob
 (own onion)                (a mutual contact)       (own onion)
     │                             │                     │
     │  1. connect to Bob.onion ───┼──────── offline ────✗
     │                             │
     │  2. hand envelope to relay ─▶  holds ciphertext
     │                             │   (cannot read it)
     │                             │
     │                             │  3. Bob comes online and pulls
     │                             │◀────────────────────┤
     │                             ├── 4. forward ───────▶│
     │◀────────── 5. acknowledgement ─────────────────────┤
```

- **Connection handshake.** Both sides publish a fresh X25519 ephemeral inside a
  signed offer, and four Diffie-Hellman values (static-static, ephemeral-
  ephemeral and both crossed combinations) are mixed into a session root. The
  signature covers the ephemeral, so a relay cannot substitute its own.
- **Identity pinning.** The onion address names a *Tor service*; the Ed25519 key
  in the handshake names a *person*. They are separate keys, so the first
  successful handshake pins the identity key for that address (trust on first
  use) and a later handshake presenting a different key is flagged as
  `ContactTrust.keyChanged` rather than silently accepted. That flag is what the
  contact screen shows in red.
- **Frames.** `[uint32 length][kind][request id][payload]`, multiplexed so a file
  chunk and a chat message share one onion circuit — circuit setup costs seconds
  on Tor.
- **Per-connection ratchet.** Each frame gets a message key from a symmetric
  ratchet, with the counter bound in as associated data. Replays and reordering
  are rejected; a compromised message key exposes no other frame.
- **Envelopes.** A message that has to travel through a relay is sealed to the
  *destination's long-term key*, not the session key, because it may sit on a
  third party's disk for days. That is what lets a relay store and forward
  something it can never read.

### Tor integration

- The daemon and all pluggable transports ship as Flutter assets and are
  unpacked into the application support directory on first launch — asking a
  censored user to install a second app is one takedown away from useless.
- **Tor owns the hidden-service key, and the account adopts the address Tor
  publishes.** The first design derived the address from the account's Ed25519
  identity key and wrote Tor's key files directly, which would have made the
  address a pure function of the identity. It does not work, and the failure was
  measured rather than guessed: given `hs_ed25519_secret_key` containing a
  standard Ed25519 key (`seed || publicKey`), Tor reuses the seed byte-for-byte
  but derives a **different** public key and refuses to start with
  `hs_ed25519_public_key does not match hs_ed25519_secret_key`. This project's
  Ed25519 is provably standard — `test/crypto/sha3_test.dart` pins the RFC 8032
  vector — so the disagreement is in Tor's expected on-disk layout. Letting Tor
  generate the pair removes the ambiguity; `tool/smoke_tor.dart` reproduces the
  whole path. The cost is that the address is unknown until Tor has started
  once, which is why `Account.onionAddress` starts empty and is filled in from
  Tor's `hostname` file.
- The control port drives the bootstrap progress bar. Tor's dozen internal tags
  are collapsed into the four milestones the mockup shows.
- Bridges are applied with `ClientTransportPlugin` lines; switching transport
  restarts the daemon, while changing bridge *lines* uses `SETCONF` + `RELOAD`
  and keeps existing circuits.

**No bridge addresses are hard-coded.** Bridge lines are rotated precisely
because censors block them, so a list baked into a release is stale within weeks
and gives false confidence. The presets select the transport and the torrc
wiring; addresses come from the user or from BridgeDB's moat interface at
runtime.

---

## Honest limitations

These are real and worth stating plainly.

1. **Calls were removed, not finished.** Voice and video calls cannot cross Tor —
   UDP is not carried — so they would need a custom Opus-over-TCP media relay with
   its own congestion handling. That is a large piece of work, and a half-working
   call is worse than an absent one: a button that sometimes connects and then
   drops is harder to trust than a button that is not there. The code was deleted
   rather than left disabled, so nothing in the interface claims the feature
   exists. Voice *messages* work today.

2. **A peer that has never been reached cannot be messaged.** The first message
   requires one successful handshake to establish the exchange key. Until then
   the message sits in the outbox with an explanatory status.

3. **Relays are chosen from your own contacts.** A message is only handed to
   contacts the user already knows and who have opted into relaying. That is a
   deliberate trade: a mesh that forwards to strangers leaks the social graph.
   The consequence is that a small contact list gives few fallback paths.

4. **No forward secrecy against a compromised long-term key *and* a stored
   envelope.** Envelopes are sealed to long-term keys so they can be stored by
   relays. Someone who later steals both a peer's exchange private key and a
   relay's stored ciphertext can read that envelope. Live sessions do have
   forward secrecy. A future version should use one-time prekeys published at
   handshake time.

5. **Pure-Dart cryptography.** The faster option, libsodium via the `sodium`
   package, cannot be built on this machine: its Dart build hook decodes MSBuild
   output as UTF-8, and a Russian Windows has MSBuild answering in CP1251, so
   `flutter build windows` dies inside the hook with
   `FormatException: Unexpected extension byte`. That is a bug in the package,
   not here. Measured cost of the pure-Dart path (`tool/bench_crypto.dart`):
   Argon2id 64 MiB/t=3 is ~200 ms, AES-256-GCM is ~14 MiB/s. Argon2id is
   comfortably interactive; AES-GCM is the weak spot, which is why large
   transfers are chunked and report progress. Pure Dart is also not
   constant-time against a local cache-timing attacker.

6. **iOS cannot run the bundled daemon.** Apple forbids shipping an executable
   that is not part of the signed bundle, so the Android `jniLibs` trick does
   not apply. Getting iOS to work needs either a Rust `arti` build linked in as
   a library, or a user-supplied proxy.

7. **No group chats and no multi-device sync.** Search inside one conversation
   exists; there is no search across the whole account.

8. **Not independently audited.** The protocol is a simplified X3DH followed by
   a symmetric ratchet, which is defensible but not Noise, and it has not been
   reviewed by anyone but its author.

---

## Project layout

```
lib/
  main.dart                     entry point
  src/
    app/                        controller, scope, app shell and routing
    core/                       identifiers and small shared helpers
    crypto/                     SHA3, onion addresses, engine, cipher, key vault
    data/                       models, encrypted store, file vault
    design/                     colours, metrics, typography, widgets
    features/
      auth/                     sign-up, password, PIN, profile, QR
      chats/                    conversation list, chat view, composer, bubbles
      files/                    protected-files vault
      profile/                  contact profile
      settings/                 settings, relay, security, about
      tor/                      connection and bridge screens
    media/                      voice recording and playback
    mesh/                       envelopes, relays, outbox, mailbox
    net/                        SOCKS5, framing, peer connection, protocol
    tor/                        binaries, torrc, control port, manager
test/                          216 tests
tool/                           measurement and fetch scripts (see below)
assets/
  fonts/                        Inter (the mockup typeface), bundled
  bridges/                      bridge preset definitions
  tor/windows/                  Tor 0.4.9.13 + six pluggable transports
```

### Tooling

| Script | What it does |
|---|---|
| `tool/extract_layout.py` | Recovers exact geometry from the mockup SVGs |
| `tool/measure_radii.py` | Measures corner radii |
| `tool/measure_text.py` | Recovers font sizes from outlined glyphs |
| `tool/bench_crypto.dart` | Benchmarks Argon2id, AES-GCM and the curves |
| `tool/fetch_fonts.ps1` | Downloads the bundled Inter weights |
| `tool/fetch_tor_windows.ps1` | Rebuilds `assets/tor/windows` from upstream |
| `tool/probe_socket_relisten.dart` | Documents why `PeerStream` exists |

The design tokens in `lib/src/design/` are not guesses: the SVGs were rendered,
and the geometry, radii and glyph heights were measured from the pixels, then
converted into `AppMetrics`, `AppColors` and `AppTypography`.

---

## Design fidelity

The mockups are reproduced with measured values rather than approximations:

- canvas 390 × 844; controls inset 45 pt, 56 pt tall, 12 pt radii, 20 pt gaps
- search field 300 × 40 pt, pill shaped; FAB 48 pt at 16/24 pt margins
- chat top bar 60 pt; avatars 38 pt (chat), 48 pt (list), 96 pt (profile)
- bubbles 12 pt radii; every message left-aligned with its sender's avatar, as
  the mockup shows
- PIN cells 39.5 × 55.5 pt with a 10.5 pt gutter
- bridge presets 160 × 60 pt with a 30 pt gutter; manual box 464 pt tall
- bootstrap steps 30 pt apart with 9 pt dots; progress bar 7 pt, fully rounded

Two deliberate deviations: message rows are 12/18 pt apart instead of the
mockup's ~22 pt (it reads better at arm's length), and the composer's attach
button pushes the text inset in. Both are commented in the code.

---

## Licence

DarkFlow is released under the **GNU Affero General Public License, version 3**
(AGPL-3.0). The full text is in `LICENSE`. The short version: you may use, study,
modify and redistribute it, and if you run a modified version as a network
service you must offer its source to the people using it.

Tor is distributed under the BSD 3-clause licence; the bundled binaries are
unmodified upstream builds. The Dart packages used are listed in
`lib/src/features/settings/about_screen.dart`.

## Known open issue: message delivery after the handshake

## Delivery after the handshake: what was fixed, and what is still unproven

The symptom reported repeatedly was: a contact shows **Online**, a message is sent, and
nothing arrives — or it arrives only after restarting the application, and then the
conversation is missing on the other machine.

Several independent faults were found and fixed. Every one of them was invisible
from the outside in the same way: **work was done before its result was recorded**, so
the interface and the disk disagreed and the disagreement surfaced only later.

- **A contact learned from an inbound handshake never got a conversation.**
  `_rememberPeer` wrote the contact and stopped. The contact existed in storage and
  appeared nowhere — no row in the chat list, no thread — until a restart rebuilt the
  list from contacts. That is exactly "the contact appears only after a restart".
- **Records were written to memory before they were written to disk.** Eight methods
  updated the in-memory map first, so a failed or queued write left a record on screen
  that was absent from the vault. The order is now storage-first everywhere: a visible
  refusal is better than a visible record that does not exist.
- **Concurrent writes to one store sink threw.** `IOSink` accepts one stream at a time,
  so overlapping appends raised `Bad state: StreamSink is bound to a stream` and the
  write was lost entirely. Each collection now has its own write queue, `close`,
  `flush` and `compact` drain it first, and a closed store refuses new writes instead
  of racing the shutdown.
- **A dial was started while another was still in flight.** A real diagnostics report
  showed twenty-four simultaneous SOCKS dials to one onion address, each waiting out
  the ninety-second timeout. Concurrent dials for the same peer now share one attempt.
- **Handshake failures were swallowed.** An inbound handshake that failed was caught
  and dropped, so a failure was indistinguishable from "nobody called". Failures are
  now recorded in the event log with their reason.

What is **still unproven**: two real machines exchanging messages over a real onion
circuit. Every fix above is covered by tests — the shared-dial behaviour, the storage
ordering, the conversation creation, the frame ordering of voice playback — and the
suite is checked against regressions by deliberately breaking each fix and confirming a
test fails. None of that is the same as two phones on a network, and this file will not
pretend otherwise.

If delivery still fails, the in-application **Diagnostics** report now carries an event
log with `tor`, `network` and `mesh` lines — including each dial attempt, each inbound
connection accepted, and each handshake failure with its reason. That report is what
turns the next report of this problem into a diagnosis rather than a guess.
