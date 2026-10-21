import 'package:flutter/material.dart';

import '../../design/design.dart';

/// A one-field editor that refuses a bad value on the spot.
///
/// ## Why this is a widget and not a `showDialog` with a local variable
///
/// The account rename used to be written as a `showDialog` whose error text was a
/// plain `String?` declared in the enclosing function and mutated inside a
/// `StatefulBuilder`. That cannot work: the closure passed to `showDialog`'s
/// `builder` captured the variable's *value* at the moment it was called, so
/// `setDialogState(() => error = …)` rebuilt a subtree that still read the old
/// null, and the message never appeared. Pressing Save with an empty field did
/// nothing at all — no error, no dialog close, no rename — which is exactly what
/// "the rename is completely broken" describes.
///
/// Holding the message in a [State] makes the rebuild it triggers the same state
/// the text is read from, so there is no stale copy to read.
class TextPromptDialog extends StatefulWidget {
  const TextPromptDialog({
    required this.title,
    required this.initialValue,
    required this.hint,
    required this.help,
    required this.maxLength,
    this.emptyError = 'A value is required.',
    super.key,
  });

  final String title;
  final String initialValue;
  final String hint;

  /// Shown under the field while the value is acceptable.
  final String help;

  final int maxLength;
  final String emptyError;

  @override
  State<TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<TextPromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      setState(() => _error = widget.emptyError);
      return;
    }
    if (value.length > widget.maxLength) {
      setState(() {
        _error = 'That is longer than ${widget.maxLength} characters.';
      });
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AppTextField(
            key: const Key('text-prompt-field'),
            controller: _controller,
            hint: widget.hint,
            autofocus: true,
            // Enter submits, which is what a one-field dialog invites.
            onSubmitted: (String _) => _submit(),
          ),
          const SizedBox(height: 10),
          Text(
            _error ?? widget.help,
            style: AppTypography.caption.copyWith(
              color: _error == null ? AppColors.textSecondary : AppColors.danger,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('text-prompt-save'),
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Asks for a value and returns it, or null when the user cancelled.
///
/// [maxLength] is passed in rather than assumed so that the dialog and whatever
/// enforces the limit cannot disagree about it.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  required String initialValue,
  required String hint,
  required String help,
  required int maxLength,
  String emptyError = 'A value is required.',
}) =>
    showDialog<String>(
      context: context,
      builder: (BuildContext _) => TextPromptDialog(
        title: title,
        initialValue: initialValue,
        hint: hint,
        help: help,
        maxLength: maxLength,
        emptyError: emptyError,
      ),
    );
