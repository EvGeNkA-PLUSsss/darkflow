import 'package:flutter/material.dart';

import '../../../design/design.dart';

/// One card in the protected-files list.
///
/// The tile is told only what to draw — a name, a mime type and two already
/// formatted labels — so the vault screen stays the single place that knows how
/// to read a `ProtectedFileEntry`.
class FileVaultTile extends StatelessWidget {
  const FileVaultTile({
    required this.fileName,
    required this.mimeType,
    required this.sizeLabel,
    required this.addedLabel,
    this.onOpen,
    this.onExport,
    this.onRemove,
    super.key,
  });

  /// The file's own name, shown on a single ellipsised line.
  final String fileName;

  /// Used only to pick the glyph and its colour.
  final String mimeType;

  /// Pre-formatted size, e.g. `'2.4 MB'`.
  final String sizeLabel;

  /// Pre-formatted "added" line, e.g. `'Added 3 Mar 2025'`.
  final String addedLabel;

  /// Opens the file with the system handler; the menu entry is hidden when null.
  final VoidCallback? onOpen;

  /// Writes a decrypted copy wherever the user asks; hidden when null.
  final VoidCallback? onExport;

  /// Drops the file from the vault; hidden when null.
  final VoidCallback? onRemove;

  /// Side of the rounded mime glyph, matching the design.
  static const double _iconSize = 40;

  /// Radius of the mime glyph's plate. Not a design token: the token radiuses
  /// are sized for 56 pt controls, and they look bulbous on a 40 pt square.
  static const double _iconRadius = 10;

  @override
  Widget build(BuildContext context) {
    final hasMenu = onOpen != null || onExport != null || onRemove != null;
    return _HoverSurface(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            _MimeGlyph(mimeType: mimeType),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.title.copyWith(fontSize: 15),
                  ),
                  const SizedBox(height: 4),
                  Text('$sizeLabel · $addedLabel', style: AppTypography.caption),
                ],
              ),
            ),
            if (hasMenu)
              _VaultMenu(onOpen: onOpen, onExport: onExport, onRemove: onRemove),
          ],
        ),
      ),
    );
  }
}

/// The `#2C2C2C`, 12 pt-radius card with desktop hover feedback.
class _HoverSurface extends StatefulWidget {
  const _HoverSurface({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_HoverSurface> createState() => _HoverSurfaceState();
}

class _HoverSurfaceState extends State<_HoverSurface> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          decoration: BoxDecoration(
            color: _hovered && widget.onTap != null
                ? AppColors.surfacePressed
                : AppColors.surface,
            borderRadius: BorderRadius.circular(AppMetrics.fieldRadius),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// The rounded mime plate. The glyph is chosen from the mime family so a user
/// can spot a photo amongst documents at a glance.
class _MimeGlyph extends StatelessWidget {
  const _MimeGlyph({required this.mimeType});

  final String mimeType;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: FileVaultTile._iconSize,
      height: FileVaultTile._iconSize,
      decoration: BoxDecoration(
        color: AppColors.surfacePressed,
        borderRadius: BorderRadius.circular(FileVaultTile._iconRadius),
      ),
      alignment: Alignment.center,
      child: Icon(_iconFor(mimeType), size: 20, color: _colourFor(mimeType)),
    );
  }

  /// Maps a mime type onto one of the families the vault can hold. Anything
  /// unrecognised gets the generic document glyph, never a blank plate.
  static IconData _iconFor(String mimeType) {
    final type = mimeType.toLowerCase();
    if (type.startsWith('image/')) return Icons.image_outlined;
    if (type.startsWith('video/')) return Icons.movie_outlined;
    if (type.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (type.startsWith('text/')) return Icons.description_outlined;
    if (type.contains('pdf')) return Icons.picture_as_pdf_outlined;
    if (type.contains('zip') || type.contains('tar') || type.contains('compressed')) {
      return Icons.folder_zip_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  /// Family colours drawn from the palette only, so the vault never introduces a
  /// colour the rest of the app does not have.
  static Color _colourFor(String mimeType) {
    final type = mimeType.toLowerCase();
    if (type.startsWith('image/') || type.startsWith('video/')) return AppColors.accent;
    if (type.startsWith('audio/')) return AppColors.online;
    if (type.contains('pdf')) return AppColors.danger;
    if (type.contains('zip') || type.contains('tar') || type.contains('compressed')) {
      return AppColors.warning;
    }
    return AppColors.textSecondary;
  }
}

/// The overflow menu: open, export, remove.
class _VaultMenu extends StatelessWidget {
  const _VaultMenu({required this.onOpen, required this.onExport, required this.onRemove});

  final VoidCallback? onOpen;
  final VoidCallback? onExport;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_VaultAction>(
      tooltip: 'File actions',
      color: AppColors.surfacePressed,
      icon: const Icon(Icons.more_vert, size: 20, color: AppColors.textSecondary),
      onSelected: (_VaultAction action) => switch (action) {
        _VaultAction.open => onOpen?.call(),
        _VaultAction.export => onExport?.call(),
        _VaultAction.remove => onRemove?.call(),
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<_VaultAction>>[
        if (onOpen != null)
          const PopupMenuItem<_VaultAction>(
            value: _VaultAction.open,
            child: Text('Open', style: AppTypography.body),
          ),
        if (onExport != null)
          const PopupMenuItem<_VaultAction>(
            value: _VaultAction.export,
            child: Text('Export', style: AppTypography.body),
          ),
        if (onRemove != null)
          PopupMenuItem<_VaultAction>(
            value: _VaultAction.remove,
            child: Text(
              'Remove',
              style: AppTypography.body.copyWith(color: AppColors.danger),
            ),
          ),
      ],
    );
  }
}

/// What the overflow menu can ask for. An enum rather than three closures so the
/// menu items and the handler cannot drift apart.
enum _VaultAction { open, export, remove }
