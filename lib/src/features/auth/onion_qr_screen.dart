import 'package:flutter/material.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import '../../design/design.dart';
import 'auth_scaffold.dart';

/// The `.onion` address as a QR code.
///
/// This is how two people start talking without a server in the middle: one
/// shows the code, the other scans it, and the scanner now holds the exact
/// username it needs. The screen therefore treats the code as the primary
/// content and the string as its backup — a reader who cannot scan can still
/// read or select the address underneath.
class OnionQrScreen extends StatelessWidget {
  const OnionQrScreen({
    required this.onionAddress,
    required this.onCopy,
    this.title = 'Your .onion address',
    this.onBack,
    super.key,
  });

  /// The address to encode. It is used verbatim: no scheme, no prefix, because
  /// the address *is* the identifier a peer stores.
  final String onionAddress;

  /// Copies the address to the clipboard. Owned by the app layer so this screen
  /// needs no platform channels.
  final VoidCallback onCopy;

  /// Screen title. Overridable because the same card is used to show someone
  /// else's address, where "Your" would be wrong.
  final String title;

  /// Null hides the back button, for the case where the code is shown inside a
  /// flow that has its own navigation.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: onBack == null ? null : AuthBackButton(onPressed: onBack),
        title: Text(title, style: AppTypography.h2),
      ),
      child: SafeArea(
        top: false,
        // A phone in landscape cannot fit the card and both buttons, so the
        // whole body scrolls rather than clipping the address.
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: AppMetrics.screenPadding),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppMetrics.maxContentWidth),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppMetrics.screenPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(child: _QrCard(data: onionAddress)),
                    const SizedBox(height: 24),
                    const _AddressCaption(),
                    const SizedBox(height: 10),
                    SelectableText(
                      onionAddress,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: AppTypography.mono,
                    ),
                    const SizedBox(height: 24),
                    const _SharingNote(),
                    const SizedBox(height: 32),
                    PrimaryButton(label: 'Copy', onPressed: onCopy),
                    // "Close" only exists when the caller supplied somewhere to
                    // go: a button that cannot act is worse than no button.
                    if (onBack != null) ...[
                      const SizedBox(height: AppMetrics.gap),
                      SecondaryButton(label: 'Close', onPressed: onBack),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The white tile the QR code is printed on.
///
/// Dark-on-white is not a style choice: an inverted symbol is rejected by many
/// scanners, and the quiet zone the standard requires can only be white. The
/// card also carries its own padding so the quiet zone is never clipped by the
/// rounded corner.
class _QrCard extends StatelessWidget {
  const _QrCard({required this.data});

  final String data;

  /// Padding inside the card, i.e. the visual width of the quiet zone.
  static const double _padding = 28;

  /// The symbol's edge length, small enough to fit a 390 pt canvas beside its
  /// margins but large enough that each module stays a whole pixel.
  static const double _size = 232;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(_padding),
      decoration: BoxDecoration(
        color: AppColors.textPrimary,
        borderRadius: BorderRadius.circular(AppMetrics.fieldRadius),
      ),
      child: SizedBox.square(
        dimension: _size,
        child: PrettyQrView.data(
          data: data,
          // The highest correction level, because this code may be read off a
          // screen at an angle, through a camera, in poor light.
          errorCorrectLevel: QrErrorCorrectLevel.H,
          decoration: const PrettyQrDecoration(
            // Square modules and a full module density keep the symbol crisp;
            // the library's default "smooth" shape rounds the joins.
            shape: PrettyQrSquaresSymbol(color: Color(0xFF000000)),
            // One module of white between the symbol and the card's padding: the
            // standard's four-module quiet zone, plus this, is what the white
            // card already provides around the code.
            quietZone: PrettyQrQuietZone.modules(1),
          ),
        ),
      ),
    );
  }
}

/// A label above the plain-text address, so it is obvious the string is the
/// same thing the code encodes rather than a separate detail.
class _AddressCaption extends StatelessWidget {
  const _AddressCaption();

  @override
  Widget build(BuildContext context) {
    return Text(
      'Address',
      textAlign: TextAlign.center,
      style: AppTypography.caption,
    );
  }
}

/// The explanation of what the code actually grants, in the two facts a user
/// needs before showing it to someone.
class _SharingNote extends StatelessWidget {
  const _SharingNote();

  @override
  Widget build(BuildContext context) {
    return Text(
      'This address is your username. Anyone who has it can start a '
      'conversation with you, so share it only with people you want to hear '
      'from.',
      textAlign: TextAlign.center,
      style: AppTypography.secondary,
    );
  }
}
