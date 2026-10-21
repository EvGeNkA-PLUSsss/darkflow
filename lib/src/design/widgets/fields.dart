import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_colors.dart';
import '../app_metrics.dart';
import '../app_typography.dart';

/// A filled, borderless text field matching the mockups: 56 pt tall, 12 pt
/// radius, `#2C2C2C` fill. Focus is signalled with a 1.5 pt accent outline,
/// which the static mockups do not show but which the app needs.
class AppTextField extends StatefulWidget {
  const AppTextField({
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.focusNode,
    this.maxLines = 1,
    this.minLines,
    this.prefixIcon,
    this.suffix,
    this.readOnly = false,
    this.autofocus = false,
    this.enabled = true,
    this.validator,
    this.inputFormatters,
    this.autofillHints,
    super.key,
  });

  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final int maxLines;
  final int? minLines;
  final IconData? prefixIcon;
  final Widget? suffix;
  final bool readOnly;
  final bool autofocus;
  final bool enabled;
  final String? Function(String?)? validator;
  final List<TextInputFormatter>? inputFormatters;
  final Iterable<String>? autofillHints;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late final FocusNode _focusNode = widget.focusNode ?? FocusNode();
  bool _ownsFocusNode = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _ownsFocusNode = widget.focusNode == null;
    _focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) setState(() => _focused = _focusNode.hasFocus);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final multiline = widget.maxLines != 1;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: widget.enabled ? AppColors.surface : AppColors.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppMetrics.fieldRadius),
        border: Border.all(
          color: _focused ? AppColors.fieldBorderFocused : AppColors.fieldBorder,
          width: 1.5,
        ),
      ),
      constraints: BoxConstraints(
        minHeight: AppMetrics.fieldHeight,
        maxHeight: multiline ? double.infinity : AppMetrics.fieldHeight,
      ),
      padding: EdgeInsets.symmetric(
        horizontal: AppMetrics.fieldTextPadding - 1.5,
        vertical: multiline ? 12 : 0,
      ),
      alignment: multiline ? Alignment.topLeft : Alignment.centerLeft,
      child: Row(
        crossAxisAlignment: multiline ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          if (widget.prefixIcon != null) ...[
            Icon(widget.prefixIcon, size: 20, color: AppColors.textSecondary),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: TextFormField(
              controller: widget.controller,
              focusNode: _focusNode,
              obscureText: widget.obscure,
              keyboardType: widget.keyboardType,
              textInputAction: widget.textInputAction,
              onFieldSubmitted: widget.onSubmitted,
              onChanged: widget.onChanged,
              maxLines: widget.maxLines,
              minLines: widget.minLines,
              readOnly: widget.readOnly,
              autofocus: widget.autofocus,
              enabled: widget.enabled,
              validator: widget.validator,
              inputFormatters: widget.inputFormatters,
              autofillHints: widget.autofillHints,
              cursorColor: AppColors.accent,
              style: AppTypography.input,
              // A password must not be selectable.
              //
              // Copying it out — into a clipboard history, a screen recorder, or
              // a chat window — is the single easiest way for a password that is
              // supposed to exist only in the user's head to end up somewhere
              // else. Turning off interactive selection removes the long-press
              // toolbar, the drag handles and the keyboard shortcuts at once.
              enableInteractiveSelection: !widget.obscure,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: widget.hint,
                hintStyle: AppTypography.placeholder,
                errorStyle: AppTypography.caption.copyWith(color: AppColors.danger),
              ),
            ),
          ),
          if (widget.suffix != null) ...[
            const SizedBox(width: 8),
            widget.suffix!,
          ],
        ],
      ),
    );
  }
}

/// A label + field pair used on the Settings screen and in dialogs.
class LabeledField extends StatelessWidget {
  const LabeledField({
    required this.label,
    required this.field,
    this.help,
    super.key,
  });

  final String label;
  final Widget field;
  final String? help;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTypography.sectionLabel),
        const SizedBox(height: 10),
        field,
        if (help != null) ...[
          const SizedBox(height: 8),
          Text(help!, style: AppTypography.caption),
        ],
      ],
    );
  }
}
