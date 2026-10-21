import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/file_vault.dart';
import '../data/models/message.dart';

/// The decrypted copies of image attachments that the interface can draw.
///
/// ## Why this is its own object
///
/// A preview is a decrypted file, so drawing one means decrypting it first, and
/// decrypting inside `build` would put file I/O — and a second copy of every
/// picture in the cache — in the middle of a frame. So the decryption happens off
/// the build path and the result is remembered here.
///
/// It was previously a handful of top-level maps and functions inside
/// `darkflow_app.dart`, which had two consequences worth naming: the logic could
/// not be tested at all, and it was impossible to tell by reading whether a
/// missing picture was a failed decryption or a cache that never learned about
/// one. Both are addressed by making it an object with a [revision] the interface
/// can listen to.
class AttachmentPreviewCache {
  AttachmentPreviewCache();

  final Map<String, String> _paths = <String, String>{};

  /// Attachments whose decryption is in flight, so a rebuild does not queue the
  /// same work twice.
  final Set<String> _pending = <String>{};

  /// Attachments whose decryption already failed.
  ///
  /// Without this the build path would retry the same hopeless decryption on every
  /// frame — an attachment deleted underneath us, or a file that never arrived —
  /// and each attempt is a file-system hit plus a vault lookup.
  final Set<String> _failed = <String>{};

  /// Bumped whenever what can be drawn changes.
  ///
  /// The interface listens to this. Without it the decryption completes and the
  /// picture stays a placeholder until something else happens to rebuild the
  /// screen, which is indistinguishable from the feature not working.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// True when [attachmentId] has a decrypted copy ready.
  @visibleForTesting
  bool hasPreview(String attachmentId) => _paths.containsKey(attachmentId);

  /// The decrypted path for [attachmentId], or null.
  String? pathFor(String attachmentId) => _paths[attachmentId];

  /// Drops everything, because the cache directory has been purged or an
  /// attachment's bytes have changed.
  void clear() {
    _paths.clear();
    _pending.clear();
    _failed.clear();
    revision.value++;
  }

  /// Resolves the previews for [attachments], starting any that are missing.
  ///
  /// Returns only the pictures that are ready *now*: a caller drawing a list
  /// cannot wait, and the rebuild that [revision] triggers is what brings the rest
  /// in. That is the whole contract, and it is why a caller must listen.
  Map<String, File> resolve(
    FileVault? vault,
    Iterable<Attachment> attachments,
  ) {
    // A locked vault has purged the cache directory, so every remembered path is
    // a file that no longer exists. Dropping them here rather than relying on the
    // caller to remember means a picture cannot be drawn from a stale path after
    // an unlock — the failure mode being a broken-image glyph on a photo that is
    // perfectly readable.
    if (vault == null || !vault.isUnlocked) {
      if (_paths.isNotEmpty) clear();
      return const <String, File>{};
    }

    final ready = <String, File>{};
    for (final attachment in attachments) {
      if (!attachment.isImage) continue;

      final known = _paths[attachment.id];
      if (known != null) {
        final file = File(known);
        if (file.existsSync()) {
          ready[attachment.id] = file;
          continue;
        }
        // The cache purge or a lock removed it underneath us. Forget the path so
        // the decryption runs again rather than drawing a broken image for ever.
        _paths.remove(attachment.id);
      }

      // Nothing to decrypt: the bytes have not arrived, or this one has already
      // been tried and failed.
      if (!attachment.transferComplete) continue;
      if (_failed.contains(attachment.id)) continue;

      unawaited(_decrypt(vault, attachment));
    }
    return ready;
  }

  Future<void> _decrypt(FileVault vault, Attachment attachment) async {
    if (_pending.contains(attachment.id)) return;
    _pending.add(attachment.id);
    try {
      if (!vault.isUnlocked) {
        // Not a failure of this attachment: a locked vault simply has nothing to
        // decrypt with. Recording it would mark the picture broken for the rest of
        // the session, so unlocking and redrawing would never bring it back.
        return;
      }      final file = await vault.materialise(
        attachmentId: attachment.id,
        fileName: attachment.fileName,
      );
      // A failed decryption must not be cached as a success, and a success must
      // not be recorded for an attachment whose bytes were replaced mid-flight.
      _paths[attachment.id] = file.path;
      _failed.remove(attachment.id);
      revision.value++;
    } on Object {
      // The placeholder stays. Recorded so the next frame does not try again.
      _failed.add(attachment.id);
    } finally {
      _pending.remove(attachment.id);
    }
  }
}
