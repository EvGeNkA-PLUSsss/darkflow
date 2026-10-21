import 'package:flutter/material.dart';

import '../../design/design.dart';

/// The management actions for one contact: rename, clear the history, delete.
///
/// All three live in one sheet rather than as three rows on the profile screen,
/// because the profile is also rendered for an address that has not been saved
/// yet and because the conversation list offers the same three actions from a
/// long press. The sheet is the single surface both entry points share, so a
/// change to the wording of a warning cannot reach one of them and miss the
/// other.
///
/// Every action is destructive in a different way, so each one states its
/// consequence before it runs. Nothing is written until the confirmation inside
/// the sheet is answered: the sheet itself only reports the choice.
class ContactActionsSheet extends StatefulWidget {
  const ContactActionsSheet({
    required this.displayName,
    required this.messageCount,
    required this.onRename,
    required this.onClearHistory,
    required this.onDelete,
    super.key,
  });

  /// The contact's current name, used as the pre-filled value of the rename
  /// dialog and as the label in the confirmations.
  final String displayName;

  /// How many messages the contact's thread holds.
  ///
  /// "Clear chat history" is only rendered when this is greater than zero: an
  /// action that would delete nothing is a control that does nothing.
  final int messageCount;

  /// Applies a new name and reports whether it was accepted.
  ///
  /// The sheet stays open on false, so a name the account layer refuses does not
  /// look like it worked.
  final Future<bool> Function(String displayName) onRename;

  /// Drops the messages and attachments of this conversation. Called only after
  /// the consequence has been confirmed.
  final VoidCallback onClearHistory;

  /// Removes the contact and everything filed under it. Called only after the
  /// consequence has been confirmed.
  final Future<void> Function() onDelete;

  /// Opens the sheet as a modal bottom sheet, in the style of
  /// [AddContactSheet.show].
  static Future<void> show(
    BuildContext context, {
    required String displayName,
    required int messageCount,
    required Future<bool> Function(String displayName) onRename,
    required VoidCallback onClearHistory,
    required Future<void> Function() onDelete,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext context) => ContactActionsSheet(
        displayName: displayName,
        messageCount: messageCount,
        onRename: onRename,
        onClearHistory: onClearHistory,
        onDelete: onDelete,
      ),
    );
  }

  @override
  State<ContactActionsSheet> createState() => _ContactActionsSheetState();
}

class _ContactActionsSheetState extends State<ContactActionsSheet> {
  Future<void> _rename() async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _RenameContactDialog(initialName: widget.displayName),
    );
    if (chosen == null || !mounted) return;

    final applied = await widget.onRename(chosen);
    if (!mounted) return;
    if (applied) {
      Navigator.of(context).pop();
      return;
    }
    // The only way the account layer refuses a name this dialog approved is a
    // contact that disappeared underneath it, which the caller has already
    // handled; leaving the sheet up says "not done" rather than pretending.
  }

  Future<void> _clearHistory() async {
    final confirmed = await _confirm(
      context,
      title: 'Clear chat history?',
      message: 'Every message with ${widget.displayName} is deleted from this '
          'device, and so is every file or voice note they carried. The contact '
          'stays, so nothing has to be set up again — but there is no back-up '
          'and this cannot be undone. The other side keeps their own copy.',
      confirmLabel: 'Clear history',
    );
    if (!confirmed || !mounted) return;
    widget.onClearHistory();
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final confirmed = await _confirm(
      context,
      title: 'Delete ${widget.displayName}?',
      message: 'This removes the contact from this device: the name, the pinned '
          'identity key and the pinned onion address, the whole message history, '
          'and every attachment in it. There is no back-up and this cannot be '
          'undone. Your account, and the messages on the other side, are not '
          'affected.',
      confirmLabel: 'Delete',
    );
    if (!confirmed || !mounted) return;
    await widget.onDelete();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: safeBottom),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppMetrics.screenPadding,
            20,
            AppMetrics.screenPadding,
            24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                widget.displayName,
                style: AppTypography.h2.copyWith(fontSize: 20),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppMetrics.gap),
              AppListSection(
                children: <Widget>[
                  AppListRow(label: 'Rename', onTap: () => _rename()),
                  if (widget.messageCount > 0)
                    AppListRow(
                      label: 'Clear chat history',
                      subtitle: widget.messageCount == 1
                          ? '1 message'
                          : '${widget.messageCount} messages',
                      labelColor: AppColors.danger,
                      onTap: () => _clearHistory(),
                    ),
                  AppListRow(
                    label: 'Delete contact',
                    labelColor: AppColors.danger,
                    onTap: () => _delete(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks for a new display name, pre-filled with the current one.
///
/// Validation is deliberately forgiving — trim, refuse the empty string, cap the
/// length — because a display name is a label for the user, not a claim about the
/// contact: it never reaches the peer and cannot change who a message is
/// encrypted to. The cap matches [AppController.maxDisplayNameLength], which is
/// enforced again where the record is written.
class _RenameContactDialog extends StatefulWidget {
  const _RenameContactDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameContactDialog> createState() => _RenameContactDialogState();
}

class _RenameContactDialogState extends State<_RenameContactDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );

  String get _trimmed => _name.text.trim();

  bool get _valid => _trimmed.isNotEmpty && _trimmed.length <= maxNameLength;

  /// Kept in step with `AppController.maxDisplayNameLength`; duplicated here so
  /// the dialog can explain the limit without importing the account layer.
  static const int maxNameLength = 64;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_valid) return;
    Navigator.of(context).pop(_trimmed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Rename contact'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppTextField(
            controller: _name,
            hint: 'Name',
            autofocus: true,
            textInputAction: TextInputAction.done,
            onChanged: (String _) => setState(() {}),
            onSubmitted: (String _) => _submit(),
          ),
          const SizedBox(height: 8),
          Text(
            // The name is local: saying so here stops the reasonable assumption
            // that renaming tells the contact anything.
            'This name is only stored on this device.',
            style: AppTypography.caption,
          ),
          if (_trimmed.length > maxNameLength) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              'At most $maxNameLength characters.',
              style: AppTypography.caption.copyWith(color: AppColors.danger),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _valid ? _submit : null,
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

/// The destructive confirmation: what happens, then the two answers.
///
/// Every destructive action in the app goes through one of these rather than its
/// own copy of an [AlertDialog], so the shape of the warning cannot drift between
/// them, and the danger colour cannot be forgotten on one of them.
Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return answer ?? false;
}
