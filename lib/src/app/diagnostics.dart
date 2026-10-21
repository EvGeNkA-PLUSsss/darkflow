import 'dart:convert';
import 'dart:io';

import '../app/darkflow_app.dart';
import 'app_controller.dart';
import 'log_book.dart';

/// Builds the diagnostic report a user attaches to a bug report.
///
/// ## What it is for
///
/// DarkFlow has no telemetry, no crash reporting and no server, which is the
/// point of the application and also means a bug report is the only signal that
/// reaches the developer. "Tor did not connect" is not actionable; the bootstrap
/// phase, the bridge mode, the ports and the platform usually are.
///
/// ## What it deliberately leaves out
///
/// Everything private. Not because it is hard to read — the report is assembled
/// in memory and written where the user chooses — but because a diagnostic file
/// gets pasted into issue trackers and chat rooms, and the person pasting it is
/// usually the one person this application exists to protect.
///
/// So the report contains no message bodies, no contact names, no onion
/// addresses, no file names, no key material and no counts that identify a
/// conversation. Distances and categories are used instead of values: "3
/// conversations" rather than their addresses, "a v3 onion address is published"
/// rather than what it is, the Tor *version* rather than the ports chosen at
/// random for this run.
///
/// The one thing that could be sensitive is the exact Tor runtime version and the
/// platform build, both of which are necessary to diagnose anything, and both of
/// which describe the software rather than the user.
abstract final class DiagnosticsReport {
  /// The report as plain text, ready to be attached to a bug report.
  ///
  /// Plain text rather than JSON on purpose: a user can read it before sending it,
  /// which is the only honest way to ask someone to share a file about themselves.
  static String build(AppController controller) {
    final buffer = StringBuffer();
    final now = DateTime.now().toUtc();

    buffer.writeln('DarkFlow diagnostic report');
    buffer.writeln('Generated: ${now.toIso8601String()}');
    buffer.writeln();

    _section(buffer, 'Build');
    buffer.writeln('version:       $kAppVersion+$kBuildNumber');
    buffer.writeln('release build: ${kIsReleaseBuild ? 'yes' : 'no (development)'}');
    buffer.writeln('crypto engine: ${controller.engine.backendName}');

    _section(buffer, 'Platform');
    buffer.writeln('os:            ${Platform.operatingSystem}');
    buffer.writeln('os version:    ${Platform.operatingSystemVersion}');
    buffer.writeln('dart:          ${Platform.version}');
    buffer.writeln('locale:        ${controller.settings.localeCode}');

    _section(buffer, 'Account');
    final account = controller.account;
    buffer.writeln('unlocked:      ${controller.isUnlocked}');
    buffer.writeln('stage:         ${controller.stage.name}');
    // A boolean rather than the address. Whether a hidden service is published is
    // the diagnostic question; which one it is, is the user's to keep.
    buffer.writeln('has onion:     ${account?.hasAddress ?? false}');
    buffer.writeln('address live:  ${account?.addressVerified ?? false}');
    buffer.writeln('display name:  ${account == null || account.displayName.isEmpty ? 'unset' : 'set'}');
    buffer.writeln('contacts:      ${controller.contacts.length}');

    _section(buffer, 'Tor');
    final tor = controller.tor;
    if (tor == null) {
      buffer.writeln('manager:       not created yet');
    } else {
      final status = tor.status;
      buffer.writeln('stage:         ${status.stage.name}');
      buffer.writeln('progress:      ${(status.progress * 100).round()}%');
      buffer.writeln('started:       ${tor.isStarted}');
      buffer.writeln('tor version:   ${status.torVersion ?? 'unknown'}');
      buffer.writeln('using bridges: ${status.usingBridges}');
      buffer.writeln('socks port:    ${status.socksPort == null ? 'not chosen' : 'assigned'}');
      buffer.writeln('control port:  ${status.controlPort == null ? 'not chosen' : 'assigned'}');
      if (status.summary.isNotEmpty) buffer.writeln('summary:       ${status.summary}');
      if (status.error != null) buffer.writeln('error:         ${status.error}');
      if (status.warning != null) buffer.writeln('warning:       ${status.warning}');

      _section(buffer, 'Tor log (most recent last)');
      final log = tor.log;
      if (log.isEmpty) {
        buffer.writeln('(empty)');
      } else {
        for (final line in log) {
          buffer.writeln(line);
        }
      }
    }

    // The configured transport, reported whether or not a manager exists.
    //
    // This used to sit inside the `tor != null` branch above, which meant a report
    // taken before networking had finished — exactly the state a user is in when
    // Tor will not start, which is the whole reason they are writing a bug report
    // — said nothing about the bridges at all. The settings are read from the
    // account, not from the daemon, so they are available from the moment the
    // vault is open.
    //
    // The mode and the number of lines, never the lines themselves: a bridge line
    // contains the address of a relay somebody chose, and for a user behind a
    // censor that is the most sensitive string in the application.
    _section(buffer, 'Configured transport');
    final torSettings = controller.settings.torSettings;
    buffer.writeln('bridge mode:   ${torSettings.effectiveMode.name}');
    buffer.writeln('bridge lines:  ${torSettings.bridgeLines.length}');
    buffer.writeln('uses bridges:  ${torSettings.usesBridges}');
    buffer.writeln('onion service: ${torSettings.enableOnionService}');
    buffer.writeln('virtual port:  ${torSettings.virtualPort}');

    _section(buffer, 'Mesh');
    final mesh = controller.mesh;
    if (mesh == null) {
      buffer.writeln('service:       not created yet');
    } else {
      buffer.writeln('configured:    ${mesh.isConfigured}');
      buffer.writeln('peers known:   ${mesh.peers.length}');
      buffer.writeln('reachable:     ${mesh.peers.values.where((p) => p.isReachable).length}');
      // Counted separately, because these disagree exactly when something is wrong: a peer that
      // answered recently with no connection open cannot be written to, and a report showing
      // only "reachable" hides that — which is how "it just says online" survived several rounds
      // of reading these numbers.
      buffer.writeln('open links:    ${mesh.liveConnectionCount}');
      buffer.writeln('outbox:        ${mesh.outboxSize} envelopes waiting');
      buffer.writeln('mailbox:       ${mesh.mailboxSize} envelopes held for others');
      buffer.writeln('holding bytes: ${mesh.mailboxBytes}');
      final failure = mesh.lastFailure;
      if (failure != null) buffer.writeln('last failure:  $failure');
    }

    _section(buffer, 'Attachment transfers');
    final failures = controller.transferFailures;
    if (failures.isEmpty) {
      buffer.writeln('failures:      none this session');
    } else {
      buffer.writeln('failures:      ${failures.length}');
      // The attachment id is a random opaque string that identifies a record, not
      // a person or a file name, and without it a transfer failure cannot be
      // matched to the message it belongs to.
      for (final failure in failures) {
        buffer.writeln('  $failure');
      }
    }

    _section(buffer, 'Connection attempts');
    // Named by address prefix rather than by name: a report is something a user sends to
    // somebody else, and a contact's *name* identifies a person while eight characters of a
    // v3 address identify a machine nobody can look up. The prefix is enough to match an
    // entry against the bubble the user is looking at, which is the whole purpose.
    final pending = controller.pendingHandshakes.toList(growable: false)..sort();
    if (pending.isEmpty) {
      buffer.writeln('awaiting:      none — every contact has an exchange key');
    } else {
      buffer.writeln('awaiting:      ${pending.length}');
      for (final onion in pending) {
        // Three states, not two. "No attempt has failed yet" used to cover both "a dial is
        // running right now" and "nothing has ever tried", which are opposite situations —
        // one means wait, the other means the pump is not working — and the report could
        // not tell them apart.
        final failure = controller.handshakeFailureFor(onion);
        final state = controller.isHandshaking(onion)
            ? 'dialling now'
            : failure ?? 'no attempt yet — waiting for the next retry';
        buffer.writeln('  ${_shorten(onion)}: $state');
      }
    }
    final achieved = controller.establishedPeers.toList(growable: false)..sort();
    buffer.writeln('established:   ${achieved.isEmpty ? 'none' : achieved.map(_shorten).join(', ')}');
    final failed = controller.handshakeFailures;
    if (failed.isNotEmpty) {
      buffer.writeln('failures:      ${failed.length}');
      for (final entry in failed.entries) {
        buffer.writeln('  ${_shorten(entry.key)}: ${entry.value}');
      }
    }

    _section(buffer, 'Relay policy');    final policy = controller.settings.relayPolicy;
    buffer.writeln('enabled:       ${policy.enabled}');
    buffer.writeln('contacts only: ${policy.onlyForContacts}');
    buffer.writeln('max stored:    ${policy.maxStoredBytes ~/ (1024 * 1024)} MB');
    buffer.writeln('max envelopes: ${policy.maxEnvelopes}');
    buffer.writeln('retention:     ${policy.retention.inHours} h');
    buffer.writeln('max hops:      ${policy.maxHops}');

    _section(buffer, 'Interface');
    buffer.writeln('notifications: ${controller.settings.notificationsEnabled}');
    final status = controller.statusMessage;
    if (status != null && status.isNotEmpty) {
      buffer.writeln('last message:  $status');
    }
    final failure = controller.failure;
    if (failure != null) {
      buffer.writeln('failure:       $failure');
    }

    _section(buffer, 'Event log');
    buffer.write(logBook.describe());

    _section(buffer, 'Note');
    buffer.writeln(
      'This report contains no messages, contact names, onion addresses, file '
      'names or keys. It names the software, the operating system and what Tor '
      'reported. Read it before sending it.',
    );

    return buffer.toString();
  }

  /// A plain-text report as UTF-8 bytes, for writing to a file.
  static List<int> encode(AppController controller) =>
      utf8.encode(build(controller));

  /// A file name that sorts usefully and identifies the build.
  ///
  /// No timestamp beyond the day: a support request does not need the minute, and
  /// a file name is one more place a detail can leak from.
  static String suggestedFileName() {
    final now = DateTime.now();
    final day = '${now.year}-${_two(now.month)}-${_two(now.day)}';
    return 'darkflow-diagnostics-$day.txt';
  }

  static void _section(StringBuffer buffer, String title) {
    buffer.writeln();
    buffer.writeln('--- $title ---');
  }

  /// Eight characters of an address, enough to match an entry to a conversation.
  ///
  /// Not the whole address: a report is written to be sent to somebody else, and a full
  /// onion address is a reachable identifier. Eight characters cannot be dialled and are
  /// enough to tell two entries apart in a list a person is looking at.
  static String _shorten(String onion) =>
      onion.length <= 8 ? onion : '${onion.substring(0, 8)}…';

  static String _two(int value) => value.toString().padLeft(2, '0');
}
