import 'package:flutter/material.dart';

import '../../../design/design.dart';

/// What a conversation row offers when it is long-pressed or right-clicked.
///
/// One item by design. Everything that changes a contact — renaming it, clearing
/// its history, deleting it — lives behind its profile, so the row menu is a
/// shortcut to that screen and not a second, thinner copy of it. A menu with three
/// more entries here would have to keep its own wording of the consequences in
/// step with the profile's.
///
/// An action is a plain callback rather than something that takes a context: it is
/// built inside the list, which is already under the navigator that has to open the
/// screen, and threading a context through the [showMenu] await is exactly the
/// "context across an async gap" mistake.
class PeerMenuAction {
  const PeerMenuAction({required this.label, required this.onChosen});

  final String label;
  final VoidCallback onChosen;
}

/// Shows [actions] at the point the row was pressed.
///
/// [ChatsScreen] and [ShellSidebar] both call this, so the phone list and the
/// desktop sidebar cannot drift into two different menus for the same row.
Future<void> showPeerMenu(
  BuildContext context, {
  required Offset position,
  required List<PeerMenuAction> actions,
}) async {
  if (actions.isEmpty) return;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return;

  final chosen = await showMenu<PeerMenuAction>(
    context: context,
    color: AppColors.surface,
    position: RelativeRect.fromRect(
      position & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: <PopupMenuEntry<PeerMenuAction>>[
      for (final action in actions)
        PopupMenuItem<PeerMenuAction>(
          value: action,
          height: AppMetrics.listTileHeight,
          child: Text(action.label, style: AppTypography.body),
        ),
    ],
  );
  if (chosen == null) return;
  chosen.onChosen();
}
