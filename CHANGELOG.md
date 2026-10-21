# Changelog

All notable changes to DarkFlow. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/).

Because there is no server, a release cannot be withdrawn — only superseded. A
change to the on-disk vault format is therefore a **major** change: an older
build refuses a newer vault header rather than corrupting it, so a user who
opens a vault with a new build cannot go back.

---

## [0.1.0] — 2026-10-21

First public release. Windows and Android.

### What it is

A peer-to-peer messenger on the Tor network with no server component. Each
account is its own Tor v3 onion service; the onion address *is* the username.
Everything on disk is encrypted with a key derived from the password through
Argon2id, and there is no plaintext store.

### Included

- **Accounts.** Argon2id over the password, an Ed25519 identity, an X25519
  exchange key, optional six-digit PIN bound to the OS keystore, and an
  encrypted vault with no database engine.
- **Tor bundled and managed by the application.** The daemon ships with the app
  — `jniLibs` on Android, a `tor/` directory beside the executable on Windows —
  and is started, monitored and stopped by it. Bridge support for obfs4,
  WebTunnel, Snowflake, meek and conjure, with a validator that refuses a
  malformed bridge line before Tor sees it.
- **Messaging over Tor.** Handshake with a pinned identity key (trust on first
  use, with key-change detection), a symmetric ratchet for the session, chunked
  encrypted attachments, delivery and read receipts, replies, drafts, and search
  inside a conversation.
- **Voice messages.** Recording with a waveform, encrypted at rest, played back
  with a position indicator.
- **Relaying between contacts.** Store-and-forward over contacts who opted in,
  with an outbox, backoff and a mailbox pull.
- **Diagnostics.** An in-application report with the Tor log, the mesh and
  network state, and an event log written to disk, so a failure can be described
  rather than guessed at.

### Fixed in this release

These were the faults behind "the contact appears only after a restart" and
"messages do not arrive":

- A contact learned from an inbound handshake never received a conversation, so
  it existed in storage and appeared nowhere until a restart rebuilt the list.
- Eight methods wrote to memory before writing to disk, leaving records visible
  on screen and absent from the vault. The order is now storage-first
  throughout.
- Overlapping writes to one store sink raised `StreamSink is bound to a stream`
  and lost the write. Each collection now has its own write queue, and `close`,
  `flush` and `compact` drain it.
- Concurrent dials to one peer were each started while the previous was still in
  flight — a real diagnostics report showed twenty-four simultaneous SOCKS dials
  to one address. They now share a single attempt.
- A failed inbound handshake was caught and dropped, making it
  indistinguishable from "nobody called". Failures are now logged with a reason.
- Voice playback showed no progress while the audio was already audible. Four
  independent causes: the "now playing" mark was set after the file was
  decrypted; the phone layout passed it to a pushed route as a snapshot; the
  decrypting loop blocked the frame that would have redrawn the control; and a
  missing platform completion signal left the button on pause for ever.
- The QR scanner could show an unexplained black rectangle, because the camera
  plugin renders an empty box when it has no texture. The explanation is now
  drawn underneath the preview, so the area is never blank.

### Removed

- **Voice and video calls.** They cannot cross Tor without a custom media relay,
  and a call button that connects sometimes is worse than none. The code was
  deleted rather than disabled.
- **The Android foreground service.** It kept the process alive for alerts that
  still could not be guaranteed, at the cost of a permanent notification and
  battery.

### Known gaps

See `docs/RELEASE.md` §5 for the full list with reasons. The ones that matter to
a user: no Windows installer, unsigned binaries, iOS not built, Android is
arm64-v8a only, no group chats, and **message delivery between two real devices
over Tor has not been observed** — it is covered by tests, not by a field test.

[0.1.0]: https://github.com/EvGeNkA-PLUSsss/darkflow/releases/tag/v0.1.0
