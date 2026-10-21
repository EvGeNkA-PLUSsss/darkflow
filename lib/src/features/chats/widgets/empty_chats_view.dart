import 'package:flutter/material.dart';

import '../../../design/design.dart';

/// The state [ChatsScreen] shows before the account has a single contact.
///
/// It is deliberately illustration-free: the mockups have no artwork, and the
/// only thing a brand-new account can usefully do is add someone by address, so
/// the view ends in exactly that button.
class EmptyChatsView extends StatelessWidget {
  const EmptyChatsView({required this.onAddContact, super.key});

  /// Opens [AddContactSheet]. Required because the empty state is otherwise a
  /// dead end.
  final VoidCallback onAddContact;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 40% opacity keeps the glyph present without competing with the
            // headline, as the specification asks.
            Icon(
              Icons.forum_outlined,
              size: 64,
              color: AppColors.textSecondary.withValues(alpha: 0.4),
            ),
            const SizedBox(height: AppMetrics.gap),
            const Text(
              'No conversations yet',
              style: AppTypography.title,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Add someone by their .onion address to start.',
              style: AppTypography.secondary,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            // Hugging the label would make the button jump between locales, so
            // the width is fixed and centred instead.
            SizedBox(
              width: 220,
              child: PrimaryButton(label: 'Add contact', onPressed: onAddContact),
            ),
          ],
        ),
      ),
    );
  }
}
