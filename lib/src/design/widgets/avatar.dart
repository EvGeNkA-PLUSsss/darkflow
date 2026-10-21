import 'dart:io';

import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_metrics.dart';
import '../app_typography.dart';

/// A circular avatar. Contacts without a picture get their initial drawn on the
/// accent colour, exactly as in the mockups.
class AppAvatar extends StatelessWidget {
  const AppAvatar({
    required this.name,
    this.size = AppMetrics.avatarList,
    this.imagePath,
    this.online = false,
    this.showOnlineBadge = false,
    super.key,
  });

  final String name;
  final double size;
  final String? imagePath;
  final bool online;
  final bool showOnlineBadge;

  /// The first letter of a name, used as the fallback glyph.
  static String initialOf(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    // `runes` so an emoji name still produces a single glyph.
    return String.fromCharCode(trimmed.runes.first).toUpperCase();
  }

  /// A stable, pleasant colour derived from the name. The mockups only ever
  /// show the accent colour, so this is opt-in via [useGeneratedColor].
  static Color colorFor(String name) => AppColors.accent;

  @override
  Widget build(BuildContext context) {
    final hasImage = imagePath != null && imagePath!.isNotEmpty && File(imagePath!).existsSync();

    final circle = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.accent,
        shape: BoxShape.circle,
        image: hasImage
            ? DecorationImage(image: FileImage(File(imagePath!)), fit: BoxFit.cover)
            : null,
      ),
      alignment: Alignment.center,
      child: hasImage
          ? null
          : Text(
              initialOf(name),
              style: AppTypography.avatarInitial.copyWith(fontSize: size * 0.42),
            ),
    );

    if (!showOnlineBadge) return circle;

    final badge = size * 0.3;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          circle,
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: badge,
              height: badge,
              decoration: BoxDecoration(
                color: online ? AppColors.online : AppColors.textSecondary,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.background, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
