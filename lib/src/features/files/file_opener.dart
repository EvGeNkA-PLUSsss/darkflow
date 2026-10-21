import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/models/protected_file.dart';
import '../../design/design.dart';

/// Launching a decrypted file with whatever the desktop associates with it.
///
/// ## Why this is a separate concern
///
/// Opening a file means handing a decrypted copy to another program, which is a
/// privacy decision rather than a convenience: the copy leaves the vault's
/// protection the moment it is on screen in someone else's application, and any
/// program on the machine can then read it. That is why the caller asks first —
/// see `confirmAndOpenFile` in the interface layer — and why nothing here decides
/// on its own.
abstract final class FileOpener {
  /// True when this platform has a way to open a file by association.
  static bool get isSupported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Asks the desktop to open [file].
  ///
  /// Returns null on success, or a sentence explaining the failure. A `Future`
  /// that never reports a problem would leave a button that looks like it worked
  /// while nothing appeared.
  static Future<String?> open(File file) async {
    if (!isSupported) {
      // Android and iOS have no "open by association" from a path: a file has to
      // be handed to an application through the platform's own share or view
      // intent, which is a plugin this build does not carry. Saying so beats a
      // control that silently does nothing.
      return 'Opening a file from the vault is not available on this platform yet. '
          'Use "Save forever" to write a decrypted copy you can open.';
    }
    if (!file.existsSync()) {
      return 'That file is no longer in the vault.';
    }
    try {
      final Process process;
      if (Platform.isWindows) {
        // `start` is a shell built-in, so it has to go through the shell — and the
        // empty first argument is `start`'s own "this is the title" parameter,
        // without which a quoted path is taken as a window title and nothing
        // opens.
        process = await Process.start(
          'cmd',
          <String>['/c', 'start', '', file.path],
          runInShell: false,
          mode: ProcessStartMode.detached,
        );
      } else if (Platform.isMacOS) {
        process = await Process.start(
          'open',
          <String>[file.path],
          mode: ProcessStartMode.detached,
        );
      } else {
        process = await Process.start(
          'xdg-open',
          <String>[file.path],
          mode: ProcessStartMode.detached,
        );
      }
      // Detached: the launcher returns as soon as the file is handed over, and the
      // process itself is the user's, not ours to supervise.
      process.exitCode.ignore();
      return null;
    } on Object catch (error) {
      return 'Could not open that file: $error';
    }
  }

  /// Reveals [file] in the platform's file manager instead of opening it.
  ///
  /// Offered as the cautious alternative: it shows the user where the decrypted
  /// copy is without handing its contents to an application.
  static Future<String?> reveal(File file) async {
    if (!file.existsSync()) return 'That file is no longer in the vault.';
    try {
      if (Platform.isWindows) {
        final Process process = await Process.start(
          'explorer',
          <String>['/select,${file.path}'],
          mode: ProcessStartMode.detached,
        );
        process.exitCode.ignore();
        return null;
      }
      if (Platform.isMacOS) {
        final Process process = await Process.start(
          'open',
          <String>['-R', file.path],
          mode: ProcessStartMode.detached,
        );
        process.exitCode.ignore();
        return null;
      }
      // Linux file managers have no portable "reveal this file", so the containing
      // directory is opened instead.
      final Process process = await Process.start(
        'xdg-open',
        <String>[file.parent.path],
        mode: ProcessStartMode.detached,
      );
      process.exitCode.ignore();
      return null;
    } on Object catch (error) {
      return 'Could not show that file: $error';
    }
  }
}

/// What has to be shown before a sealed file is handed to another application.
///
/// A dialog rather than a snack bar: the consequence is permanent and not
/// undone by locking the vault, and a message that disappears on its own is the
/// wrong shape for a decision.
Future<bool> confirmOpenFile(
  BuildContext context, {
  required ProtectedFile file,
}) async {
  final agreed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Open this file?'),
      content: Text(
        '“${file.fileName}” will be decrypted and handed to another application, '
        'which means anything running on this device can read it while it is open. '
        'Locking DarkFlow deletes the temporary copy, but a program that already '
        'has it can keep it.',
        style: AppTypography.secondary,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('confirm-open-file'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Open'),
        ),
      ],
    ),
  );
  return agreed ?? false;
}
