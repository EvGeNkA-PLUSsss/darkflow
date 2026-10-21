import 'package:flutter/material.dart';

import '../../design/design.dart';
import 'widgets/microphone_picker.dart';

/// Chooses the microphone voice messages are recorded from.
///
/// A screen of its own rather than a dropdown, because enumerating the devices is
/// a platform call that can fail or come back empty, and that answer needs a place
/// to be shown — along with the "look again" action, which is how a headset
/// plugged in after this screen opened becomes selectable.
class MicrophoneScreen extends StatefulWidget {
  const MicrophoneScreen({
    required this.selectedId,
    required this.onSelected,
    required this.listDevices,
    this.onBack,
    super.key,
  });

  /// The stored choice, or null for the system default.
  final String? selectedId;

  /// Called when the user picks one. Null means the system default.
  final ValueChanged<String?> onSelected;

  /// Asks the platform for its inputs. Injected so the screen owns no plugin, and
  /// so a test can supply a list without an audio device.
  final Future<List<MicrophoneOption>> Function() listDevices;

  final VoidCallback? onBack;

  @override
  State<MicrophoneScreen> createState() => _MicrophoneScreenState();
}

class _MicrophoneScreenState extends State<MicrophoneScreen> {
  List<MicrophoneOption> _devices = const <MicrophoneOption>[];
  bool _loading = true;
  String? _failure;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.selectedId;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final devices = await widget.listDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      // Reported rather than shown as an empty list: "no microphones" and "the
      // platform refused to answer" are different problems, and only one of them
      // is worth the user doing anything about.
      setState(() {
        _failure = '$error';
        _loading = false;
      });
    }
  }

  void _choose(String? id) {
    setState(() => _selected = id);
    widget.onSelected(id);
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      child: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          child: CenteredContent(
            padding: EdgeInsets.zero,
            child: Stack(
              children: <Widget>[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Padding(
                      padding: EdgeInsets.only(top: 24),
                      child: ScreenTitle('Microphone'),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(32, 10, 32, 0),
                      child: Text(
                        'Which input a voice message is recorded from. The system '
                        'default is what most people want; pick a device here when '
                        'the wrong one keeps being used.',
                        textAlign: TextAlign.center,
                        style: AppTypography.secondary,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppMetrics.screenPadding,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          if (_failure != null) ...<Widget>[
                            Text(
                              'The device list could not be read: $_failure',
                              style: AppTypography.caption
                                  .copyWith(color: AppColors.danger),
                            ),
                            const SizedBox(height: 12),
                          ],
                          MicrophonePicker(
                            devices: _devices,
                            selectedId: _selected,
                            loading: _loading,
                            onSelected: _choose,
                            // Always offered, because a device list is a snapshot:
                            // a headset plugged in after this screen opened is
                            // simply not in it.
                            onRefresh: _load,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
                if (widget.onBack != null)
                  Positioned(
                    top: 4,
                    left: 4,
                    child: IconButton(
                      onPressed: widget.onBack,
                      icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                      color: AppColors.textPrimary,
                      tooltip: 'Back',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
