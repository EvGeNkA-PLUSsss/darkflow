# Security policy

DarkFlow is a privacy tool, so a weakness in it is not an ordinary bug. This
file says how to report one and what to expect.

## Reporting a vulnerability

**Do not open a public issue for a security problem.** Use GitHub's private
reporting instead: on the repository, *Security* → *Report a vulnerability*.
That opens a private advisory visible only to the maintainer.

If private reporting is unavailable, open an issue that says only "I have a
security report, please contact me" and nothing about the flaw.

What helps, in rough order of usefulness:

1. **What an attacker gains.** Read another user's messages? Impersonate a
   contact? Recover the vault without the password? Decrypt a relay's stored
   envelope? "There is a bug in the handshake" is much harder to act on than
   "a peer can force the ratchet to reuse a key".
2. **The exact version and platform** from the About screen, plus the
   diagnostics report if one is available. The report contains no messages,
   contact names, onion addresses, file names or keys — it says so itself, and
   that claim is worth checking before you send it.
3. **Steps to reproduce**, or a proof of concept. A protocol flaw usually needs
   either a modified client or a description precise enough to build one.

## What is in scope

- The cryptographic design and its implementation: key derivation, sealing,
  the handshake, the ratchet, onion-address handling, the vault format.
- Anything that leaks plaintext to disk, to a log, or to another application.
- The mesh: relaying, the outbox, the mailbox, and anything that lets one peer
  read or forge another's traffic.
- Bypassing the identity pin, or making a key change pass unnoticed.
- The Android and Windows packaging, where a bundling mistake could ship the
  wrong binary.

## What is out of scope, or already known

Stated so that a report of one of these is not treated as a discovery:

- **Tor's own weaknesses.** Route length, traffic correlation by a global
  observer, and timing analysis are properties of Tor. DarkFlow does not and
  cannot defend against them; it inherits them.
- **A compromised device.** Malware with the user's privileges, a keylogger, or
  a rooted phone is outside the threat model.
- **The gaps listed in `docs/RELEASE.md` §5** — no forward secrecy against a
  compromised long-term key *and* a stored envelope, pure-Dart cryptography
  without constant-time guarantees, and the absence of an independent audit.
- **Metadata the network can see**: that two onion addresses are talking, and
  when. That is inherent to onion services, not a defect here.

## Expectations

This is a single-maintainer project without funding, and it does not promise a
response time. What it does promise:

- A report will be read and answered honestly, including "this is not
  fixable in this design".
- A fix will be credited in the changelog and the release notes unless you ask
  otherwise.
- Nothing will be quietly dropped. If something is not going to be fixed, that
  will be said, and it will appear in the known-gaps table.

## Supported versions

Only the latest release. There is no server and no auto-update, so there is no
maintenance branch: a security fix is a new release, and the previous one stays
available so that a user can fall back if the new build breaks something.
