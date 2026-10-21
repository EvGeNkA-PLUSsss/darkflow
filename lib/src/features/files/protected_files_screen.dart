import 'package:flutter/material.dart';

import '../../data/models/protected_file.dart';
import '../../design/design.dart';
import 'widgets/file_vault_tile.dart';

/// One row in the protected-files list. Define it in protected_files_screen.dart.
///
/// It carries the raw fields rather than presentation strings so the vault can
/// be described — and asserted on — without the widget layer.
class ProtectedFileEntry {
  const ProtectedFileEntry({
    required this.id,
    required this.fileName,
    required this.sizeBytes,
    required this.addedAt,
    required this.mimeType,
    this.savedTo,
  });

  /// Stable identifier; the vault addresses the file by this, not by name, since
  /// two files may share a name.
  final String id;

  final String fileName;
  final int sizeBytes;

  /// When the ciphertext was written into the vault.
  final DateTime addedAt;

  /// The detected media type, used for the glyph and for the opener.
  final String mimeType;

  /// Where a decrypted copy was last saved, when the user chose to keep one.
  ///
  /// Shown, not acted on: a path the user picked once may have been moved or
  /// deleted since, and opening it on the strength of the record would open the
  /// wrong file or nothing at all.
  final String? savedTo;

  /// True when a decrypted copy exists outside the vault.
  bool get hasSavedCopy => savedTo != null && savedTo!.isNotEmpty;

  /// The size as a person would say it, e.g. `'2.4 MB'`.
  String get readableSize => formatBytes(sizeBytes);
}

/// DarkFlow's password-protected file vault.
///
/// The whole screen is a view over a vault the caller owns: it is unlocked by
/// the caller, listed by the caller and emptied by the caller. That keeps the
/// password out of the widget tree entirely.
class ProtectedFilesScreen extends StatelessWidget {
  const ProtectedFilesScreen({
    required this.unlocked,
    required this.files,
    required this.onUnlock,
    required this.onAddFiles,
    this.onOpen,
    this.onExport,
    this.onRemove,
    this.totalBytes = 0,
    this.busy = false,
    this.onBack,
    super.key,
  });

  /// False until the account password has been entered for this session. While
  /// false the list is not even built, so no names are rendered.
  final bool unlocked;

  /// The vault's contents; ignored while locked.
  final List<ProtectedFileEntry> files;

  /// Asks for the password and unlocks the vault.
  final VoidCallback onUnlock;

  /// Opens the file picker and seals whatever the user chooses.
  final VoidCallback onAddFiles;

  /// Opens one file with the system handler.
  ///
  /// Null means the action does not exist yet, and the tile then leaves it out of
  /// its menu entirely — rather than rendering an entry that is enabled, tappable
  /// and does nothing, which is how this screen read while every one of these
  /// callbacks was a literal `(_) {}`.
  final void Function(ProtectedFileEntry entry)? onOpen;

  /// Writes a decrypted copy somewhere the user chooses.
  final void Function(ProtectedFileEntry entry)? onExport;

  /// Drops one file from the vault.
  final void Function(ProtectedFileEntry entry)? onRemove;

  /// The vault's size on disk. When it is zero the sum of [files] is used, so
  /// the summary is right even if the caller does not track the total.
  final int totalBytes;

  /// True while the vault is being unlocked or files are being sealed; the
  /// bottom action then shows a spinner.
  final bool busy;

  /// Pops the route; no back affordance is drawn when null.
  final VoidCallback? onBack;

  /// Horizontal inset of the cards. The sheet's rows are full-bleed, but cards
  /// need breathing room from the screen edges.
  static const double _listInset = AppMetrics.screenPadding;

  /// Vertical gap between two cards.
  static const double _cardGap = 10;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      child: SafeArea(
        bottom: false,
        child: Stack(
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _VaultHeader(
                  fileCount: files.length,
                  totalBytes: totalBytes > 0 ? totalBytes : _sumBytes(files),
                ),
                Expanded(
                  child: unlocked
                      ? _VaultList(
                          files: files,
                          onOpen: onOpen,
                          onExport: onExport,
                          onRemove: onRemove,
                        )
                      : _LockedVault(onUnlock: onUnlock, busy: busy),
                ),
                if (unlocked)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppMetrics.controlInset,
                        8,
                        AppMetrics.controlInset,
                        16,
                      ),
                      child: PrimaryButton(
                        label: 'Add files',
                        busy: busy,
                        onPressed: onAddFiles,
                      ),
                    ),
                  ),
              ],
            ),
            if (onBack != null)
              Positioned(
                top: 4,
                left: 4,
                child: IconButton(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                  color: AppColors.textPrimary,
                  tooltip: 'Back',
                ),
              ),
          ],
        ),
      ),
    );
  }

  static int _sumBytes(List<ProtectedFileEntry> files) =>
      files.fold(0, (int total, ProtectedFileEntry entry) => total + entry.sizeBytes);
}

/// The fixed top block: title, the promise the vault makes, and its size.
class _VaultHeader extends StatelessWidget {
  const _VaultHeader({required this.fileCount, required this.totalBytes});

  final int fileCount;
  final int totalBytes;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const ScreenTitle('Protected files'),
          const SizedBox(height: 10),
          Text(
            'Every file is encrypted with a key derived from your account '
            'password before it touches the disk, so nothing in this list is '
            'readable without unlocking the vault.',
            textAlign: TextAlign.center,
            style: AppTypography.secondary,
          ),
          const SizedBox(height: 12),
          Text(
            '$fileCount ${fileCount == 1 ? 'file' : 'files'} · '
            '${formatBytes(totalBytes)}',
            textAlign: TextAlign.center,
            style: AppTypography.caption,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// The vault while it is locked: a glyph, and the one button that changes that.
class _LockedVault extends StatelessWidget {
  const _LockedVault({required this.onUnlock, required this.busy});

  final VoidCallback onUnlock;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.lock_outline, size: 56, color: AppColors.textSecondary),
            const SizedBox(height: 20),
            Text(
              'The vault is locked. Unlock it to see what it holds, or to add '
              'something to it.',
              textAlign: TextAlign.center,
              style: AppTypography.secondary,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: 220,
              child: PrimaryButton(
                label: 'Unlock vault',
                busy: busy,
                onPressed: onUnlock,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The list of sealed files, or an honest empty state.
class _VaultList extends StatelessWidget {
  const _VaultList({
    required this.files,
    required this.onOpen,
    required this.onExport,
    required this.onRemove,
  });

  final List<ProtectedFileEntry> files;
  final void Function(ProtectedFileEntry entry)? onOpen;
  final void Function(ProtectedFileEntry entry)? onExport;
  final void Function(ProtectedFileEntry entry)? onRemove;

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'Nothing protected yet. Add a file and it is encrypted before it is '
            'written.',
            textAlign: TextAlign.center,
            style: AppTypography.secondary,
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        ProtectedFilesScreen._listInset,
        0,
        ProtectedFilesScreen._listInset,
        24,
      ),
      itemCount: files.length,
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: ProtectedFilesScreen._cardGap),
      itemBuilder: (BuildContext context, int index) => _tileFor(files[index]),
    );
  }

  Widget _tileFor(ProtectedFileEntry entry) {
    return FileVaultTile(
      fileName: entry.fileName,
      mimeType: entry.mimeType,
      sizeLabel: entry.readableSize,
      // The saved copy is mentioned in the tile rather than only in the menu,
      // because "is this file still only in the vault" is the thing a user of a
      // protected-files screen needs to know at a glance.
      addedLabel: 'Added ${_formatDate(entry.addedAt)}'
          '${entry.hasSavedCopy ? ' · copy saved' : ''}',
      // Null stays null, so the tile's own contract — "no menu entry when the
      // action is absent" — is what actually happens. Wrapping each in a closure
      // that calls a no-op made the entry look available and do nothing.
      onOpen: onOpen == null ? null : () => onOpen!(entry),
      onExport: onExport == null ? null : () => onExport!(entry),
      onRemove: onRemove == null ? null : () => onRemove!(entry),
    );
  }
}

/// The month names used by [_formatDate]. Spelled out rather than pulled from a
/// locale so a file's date never changes shape with the device language.
const List<String> _months = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// `'3 Mar 2025'` in the device's local time.
String _formatDate(DateTime value) {
  final local = value.toLocal();
  return '${local.day} ${_months[local.month - 1]} ${local.year}';
}
