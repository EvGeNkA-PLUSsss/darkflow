import 'package:flutter/material.dart';

import '../../../data/models/message.dart';
import '../../../design/design.dart';

/// The card that stands in for a file, a photo or any other attachment.
///
/// It renders the metadata it is given and a caller-supplied [preview] for
/// images: this package must not touch `dart:io`, so the decrypted bytes
/// (`Attachment.localPath`) are turned into a widget by the app layer, which is
/// the only place that knows how to open the vault. The card consequently stays
/// testable and side-effect free.
class AttachmentBubble extends StatelessWidget {
  const AttachmentBubble({
    required this.attachment,
    this.outgoing = false,
    this.preview,
    this.onOpen,
    this.maxWidthFactor = AppMetrics.bubbleMaxWidthFactor,
    super.key,
  });

  final Attachment attachment;

  /// Accent fill for the account's own files, surface fill for the peer's.
  final bool outgoing;

  /// A rendered image for [Attachment.isImage] attachments, usually an
  /// `Image.file` over the decrypted cache entry. Null shows a placeholder
  /// glyph instead, which is the honest state while a transfer is running.
  final Widget? preview;

  /// Opens the file. Null leaves the card inert rather than tappable-but-dead.
  final ValueChanged<Attachment>? onOpen;

  /// Share of the row's free width the card may take.
  final double maxWidthFactor;

  /// Height of the image area, measured from the attachment mockup.
  static const double previewHeight = 180;

  @override
  Widget build(BuildContext context) {
    final foreground = outgoing ? AppColors.textOnAccent : AppColors.textPrimary;
    final muted = foreground.withValues(alpha: 0.75);
    final isImage = attachment.isImage;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final available = constraints.maxWidth;
        final maxWidth = available.isFinite ? available * maxWidthFactor : available;

        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpen == null ? null : () => onOpen!(attachment),
            child: Container(
              decoration: BoxDecoration(
                color: outgoing ? AppColors.accent : AppColors.surface,
                borderRadius: BorderRadius.circular(AppMetrics.bubbleRadius),
              ),
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                // `start` rather than `stretch`: stretch would demand a finite
                // width from the parent, and the row below fills the card's
                // width on its own.
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isImage) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        height: previewHeight,
                        width: double.infinity,
                        child: preview ??
                            ColoredBox(
                              color: AppColors.surfaceHigh,
                              child: Icon(
                                Icons.image_outlined,
                                size: 40,
                                color: foreground.withValues(alpha: 0.45),
                              ),
                            ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: outgoing
                              ? AppColors.textOnAccent.withValues(alpha: 0.18)
                              : AppColors.surfaceHigh,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(_iconFor(attachment.mimeType), size: 20, color: foreground),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              attachment.fileName,
                              style: AppTypography.title.copyWith(
                                fontSize: 15,
                                color: foreground,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              // "Receiving" is only true of the peer's file. An
                              // outgoing one is in *our* vault before the bubble
                              // is built, so calling it "Receiving" described the
                              // wrong device to the person who sent it.
                              '${attachment.readableSize} · '
                              '${attachment.transferComplete ? (outgoing ? 'Sent' : 'Complete') : (outgoing ? 'Preparing' : 'Receiving')}',
                              style: AppTypography.caption.copyWith(color: muted),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (!attachment.transferComplete) ...[
                    const SizedBox(height: 12),
                    _TransferRow(
                      progress: attachment.transferProgress,
                      fill: outgoing ? AppColors.textOnAccent : AppColors.accent,
                      labelColor: muted,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Picks a glyph from the MIME type. The name is deliberately not consulted:
  /// the sender's declaration is the only trustworthy hint, and a mismatch here
  /// costs nothing more than a generic icon.
  static IconData _iconFor(String mimeType) {
    if (mimeType.startsWith('image/')) return Icons.image_outlined;
    if (mimeType.startsWith('video/')) return Icons.videocam_outlined;
    if (mimeType.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (mimeType.startsWith('text/')) return Icons.description_outlined;
    if (mimeType == 'application/pdf') return Icons.picture_as_pdf_outlined;
    if (mimeType.contains('zip') ||
        mimeType.contains('tar') ||
        mimeType.contains('compressed') ||
        mimeType.contains('archive')) {
      return Icons.folder_zip_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}

/// The 4 pt transfer bar plus its percentage.
class _TransferRow extends StatelessWidget {
  const _TransferRow({
    required this.progress,
    required this.fill,
    required this.labelColor,
  });

  final double progress;
  final Color fill;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    final clamped = progress.clamp(0.0, 1.0);
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 4,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.surfaceHigh,
              borderRadius: BorderRadius.circular(2),
            ),
            // AppProgressBar hard-codes the accent fill, which vanishes on an
            // accent card, and it needs a tight width; this row supplies a
            // swapped fill instead and relies on [Expanded] for the width.
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: clamped,
              child: ColoredBox(color: fill),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${(clamped * 100).round()}%',
          style: AppTypography.caption.copyWith(color: labelColor),
        ),
      ],
    );
  }
}
