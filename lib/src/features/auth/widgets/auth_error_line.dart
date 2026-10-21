import 'package:flutter/material.dart';

import '../../../design/design.dart';

/// A fixed-height slot for a failure message coming from the app layer.
///
/// Every auth screen needs the same behaviour — show the message in
/// [AppColors.danger] but never let the surrounding controls move — so the
/// reserved height lives here rather than being guessed per screen. The slot is
/// always present: with a null [text] it holds nothing but still occupies its
/// [height], which is what stops "Next" from jumping down the moment a wrong
/// password is rejected.
class AuthErrorLine extends StatelessWidget {
  const AuthErrorLine({
    required this.text,
    this.height = 22,
    this.align = Alignment.bottomCenter,
    super.key,
  });

  /// The message, or null when there is nothing to report.
  final String? text;

  /// Total space kept free for the message, including its leading gap.
  final double height;

  /// Where the text sits inside the reserved box. Bottom alignment keeps the
  /// message close to the control it describes.
  final Alignment align;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Align(
        alignment: align,
        child: Text(
          // The empty string keeps the slot occupied while there is no message.
          text ?? '',
          textAlign: TextAlign.center,
          style: AppTypography.caption.copyWith(color: AppColors.danger),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
