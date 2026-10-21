import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../crypto/onion_address.dart';
import '../../design/design.dart';

/// What the add-contact sheet came back with.
///
/// A result rather than a callback that navigates. The sheet used to call `onAdd` and
/// then push the scanner itself, which meant the scanner was pushed *while the sheet was
/// still popping* — two navigator mutations in flight at once, and the race showed up as
/// a black screen behind the camera. Now the sheet closes and says what it wants, and the
/// caller does the one navigation that follows.
enum AddContactResult {
  /// The user typed an address and confirmed it.
  submitted,

  /// The user asked for the camera.
  scanRequested,

  /// Closed without doing anything.
  cancelled,
}

/// The sheet that adds a contact from an onion address.
///
/// There is no name to type and no directory to search: an onion address is
/// both the username and the public key, and the sheet says so rather than
/// pretending there is something to look up. Validation runs on every keystroke
/// against [OnionAddress], which also verifies the address's checksum, so an
/// address that passes here is one the network layer can actually reach.
class AddContactSheet extends StatefulWidget {
  const AddContactSheet({
    required this.onAdd,
    this.onScanQr,
    super.key,
  });

  /// Called with the normalised address and the display name to use. The sheet
  /// has no name field by design, so the app layer derives the name from the
  /// address — `Contact.fromOnion` falls back to the shortened form.
  final void Function(String onionAddress, String displayName) onAdd;

  /// Opens the QR scanner. When null the button is not rendered at all, because
  /// a disabled scan button would only be a decoration.
  final VoidCallback? onScanQr;

  /// Shows the sheet as a modal bottom sheet and reports what the user chose.
  ///
  /// `isScrollControlled` is required: the sheet grows with the keyboard, and
  /// without it the field would be squeezed under the on-screen keyboard.
  static Future<AddContactResult> show(
    BuildContext context, {
    required void Function(String onionAddress, String displayName) onAdd,
    VoidCallback? onScanQr,
  }) async {
    final result = await showModalBottomSheet<AddContactResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext context) => AddContactSheet(
        onAdd: onAdd,
        onScanQr: onScanQr,
      ),
    );
    return result ?? AddContactResult.cancelled;
  }

  @override
  State<AddContactSheet> createState() => _AddContactSheetState();
}

class _AddContactSheetState extends State<AddContactSheet> {
  final TextEditingController _address = TextEditingController();

  /// The normalised address, or null when what is typed is not a v3 onion yet.
  String? get _validAddress {
    final candidate = OnionAddress.normalise(_address.text);
    return OnionAddress.isValid(candidate) ? candidate : null;
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    final normalised = OnionAddress.normalise(text);
    _address.value = TextEditingValue(
      text: normalised,
      selection: TextSelection.collapsed(offset: normalised.length),
    );
    setState(() {});
  }

  void _submit() {
    final address = _validAddress;
    if (address == null) return;
    widget.onAdd(address, '');
    Navigator.of(context).pop(AddContactResult.submitted);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final address = _validAddress;
    final typed = _address.text.trim();

    return Padding(
      // Lifts the sheet above the keyboard, and keeps the buttons clear of the
      // home indicator when the keyboard is closed.
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.only(
            left: AppMetrics.screenPadding,
            right: AppMetrics.screenPadding,
            top: 20,
            bottom: 24 + safeBottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The sheet's title is the second heading of the flow, measured
              // at 20 pt rather than the 24 pt of a full screen.
              Text('Add contact', style: AppTypography.h2.copyWith(fontSize: 20)),
              const SizedBox(height: 10),
              const Text(
                'An onion address is the username and the key at the same time. '
                'There is no directory to search, which is exactly what makes '
                'DarkFlow private.',
                style: AppTypography.secondary,
              ),
              const SizedBox(height: AppMetrics.gap),
              AppTextField(
                controller: _address,
                hint: 'abcdef…xyz.onion',
                prefixIcon: Icons.alternate_email,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                autofocus: true,
                onChanged: (String _) => setState(() {}),
                onSubmitted: (String _) => _submit(),
              ),
              const SizedBox(height: 8),
              _Feedback(typed: typed, address: address),
              const SizedBox(height: AppMetrics.gap),
              PrimaryButton(
                label: 'Add',
                onPressed: address == null ? null : _submit,
              ),
              if (widget.onScanQr != null) ...[
                const SizedBox(height: AppMetrics.stackedButtonGap),
                SecondaryButton(
                  label: 'Scan QR code',
                  icon: Icons.qr_code_scanner,
                  // Closes and asks, rather than opening the camera from here. The
                  // scanner used to be pushed in the same turn as this sheet was
                  // popping, and two navigation mutations racing each other left a
                  // black screen behind the camera.
                  onPressed: () => Navigator.of(context).pop(
                    AddContactResult.scanRequested,
                  ),
                ),
              ],
              const SizedBox(height: AppMetrics.stackedButtonGap),
              _PasteAction(onPaste: _pasteFromClipboard),
            ],
          ),
        ),
      ),
    );
  }
}

/// The live validation line under the address field.
class _Feedback extends StatelessWidget {
  const _Feedback({required this.typed, required this.address});

  /// Exactly what the user has typed; empty means "nothing to say yet".
  final String typed;

  /// The normalised address once it validates, otherwise null.
  final String? address;

  @override
  Widget build(BuildContext context) {
    if (typed.isEmpty) {
      return const SizedBox(height: 18);
    }
    final address = this.address;
    if (address == null) {
      return SizedBox(
        height: 18,
        child: Text(
          'That is not a valid .onion address. Check for missing characters.',
          style: AppTypography.caption.copyWith(color: AppColors.danger),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    return SizedBox(
      height: 18,
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline, size: 14, color: AppColors.online),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Valid address · ${OnionAddress.shorten(address)}',
              style: AppTypography.caption.copyWith(color: AppColors.online),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Paste from clipboard", so a 56-character address never has to be typed.
class _PasteAction extends StatelessWidget {
  const _PasteAction({required this.onPaste});

  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPaste,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.content_paste, size: 18, color: AppColors.accent),
                const SizedBox(width: 8),
                Text(
                  'Paste from clipboard',
                  style: AppTypography.body.copyWith(fontSize: 15, color: AppColors.accent),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
