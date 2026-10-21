import 'package:flutter/material.dart';

import '../../../design/design.dart';

/// One selectable recording input.
///
/// A small value type rather than the plugin's `InputDevice`, so this screen does
/// not depend on the audio plugin: the interface was the last thing to learn about
/// microphones and it should not be the thing that breaks when the plugin's types
/// change.
class MicrophoneOption {
  const MicrophoneOption({
    required this.id,
    required this.label,
    this.isDefault = false,
  });

  /// The platform's identifier, passed to the recorder unchanged.
  final String id;

  /// What the user sees. May be the identifier itself when the platform does not
  /// report a name, which is honest rather than invented.
  final String label;

  /// True for the device the system would pick on its own.
  final bool isDefault;

  /// An id that means "let the system choose".
  static const String systemDefaultId = '__system_default__';
}

/// Picks which microphone voice messages are recorded from.
///
/// Present on desktop only, because that is where the choice exists: Windows
/// exposes several inputs and the one the system prefers is frequently the wrong
/// one — a laptop's built-in array instead of the headset the user is wearing —
/// which a user experiences as "the microphone does not work". Android and iOS
/// route the microphone themselves and report no device list, so the row explains
/// that instead of offering an empty picker.
class MicrophonePicker extends StatelessWidget {
  const MicrophonePicker({
    required this.devices,
    required this.selectedId,
    required this.onSelected,
    this.loading = false,
    this.onRefresh,
    super.key,
  });

  /// What the platform reported. Empty means it does not enumerate devices.
  final List<MicrophoneOption> devices;

  /// The chosen device, or null for the system default.
  final String? selectedId;

  final ValueChanged<String?> onSelected;
  final bool loading;

  /// Re-reads the device list, for a headset plugged in after the screen opened.
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(AppColors.accent),
              ),
            ),
            SizedBox(width: 12),
            // Flexible, because this row sits inside a column capped at the
            // content width and then inset: the message plus the spinner came to two
            // pixels more than the space available, which is a rendering error
            // rather than a wrapped sentence.
            Flexible(
              child: Text('Looking for microphones…', style: AppTypography.secondary),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (devices.isEmpty) ...<Widget>[
          // Said plainly rather than shown as an empty list: a picker with nothing
          // in it reads as a bug, and on a phone there is genuinely nothing to
          // choose.
          Text(
            'This platform chooses the microphone itself, so there is nothing to '
            'select here.',
            style: AppTypography.secondary,
          ),
        ] else ...<Widget>[
          for (final device in devices)
            _MicrophoneRow(
              label: device.label,
              selected: device.id == selectedId,
              onTap: () => onSelected(device.id),
            ),
          _MicrophoneRow(
            key: const Key('microphone-system-default'),
            label: 'System default',
            selected: selectedId == null,
            onTap: () => onSelected(null),
          ),
        ],
        if (onRefresh != null) ...<Widget>[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onRefresh,
              // A plain label rather than `TextButton.icon`: the icon variant
              // builds a `Row` whose spacing does not shrink with its label, and
              // inside this column — capped at the content width and then inset —
              // it overflowed by two pixels. The action reads fine as words.
              child: const Text('Look again'),
            ),
          ),
        ],
      ],
    );
  }
}

/// One row of the picker: a label and a tick when it is the chosen one.
class _MicrophoneRow extends StatelessWidget {
  const _MicrophoneRow({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          children: <Widget>[
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 20,
              color: selected ? AppColors.accent : AppColors.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: AppTypography.body,
                // One line, ellipsised. A device name is an identifier, not prose:
                // letting it wrap made the row taller than the list expects and
                // pushed its intrinsic width past the space available, which showed
                // up as a two-pixel overflow rather than as a wrapped name.
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
