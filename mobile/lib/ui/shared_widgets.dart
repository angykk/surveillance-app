import 'package:flutter/material.dart';

import 'app_theme.dart';

/// A translucent rounded label for text over a camera feed.
class OverlayPill extends StatelessWidget {
  const OverlayPill({
    super.key,
    required this.child,
    this.icon,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  });

  final Widget child;
  final Widget? icon;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(color: AppColors.overlay, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[icon!, const SizedBox(width: 6)],
          Flexible(child: child),
        ],
      ),
    );
  }
}

/// A translucent round icon button for controls over a camera feed.
class OverlayButton extends StatelessWidget {
  const OverlayButton({super.key, required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filled(
      style: IconButton.styleFrom(backgroundColor: AppColors.overlay, foregroundColor: AppColors.white),
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}

/// A centered message, with an optional icon above it and an action (e.g.
/// a retry button) below, for empty, error and waiting states. Scrollable
/// because a landscape phone has little height to spare.
class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.message,
    this.icon,
    this.iconSize = 48,
    this.iconColor,
    this.textColor,
    this.action,
    this.actionSpacing = 16,
    this.padding = const EdgeInsets.all(24),
  });

  final String message;
  final IconData? icon;
  final double iconSize;
  /// Null for the theme's outline color.
  final Color? iconColor;

  /// Null for the theme's text color.
  final Color? textColor;
  final Widget? action;
  final double actionSpacing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: iconSize, color: iconColor ?? Theme.of(context).colorScheme.outline),
              SizedBox(height: iconSize / 3),
            ],
            Text(message, textAlign: TextAlign.center, style: TextStyle(color: textColor)),
            if (action != null) ...[SizedBox(height: actionSpacing), action!],
          ],
        ),
      ),
    );
  }
}

/// Asks a yes/no question. True only if [confirmLabel] was tapped.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(confirmLabel)),
      ],
    ),
  );
  return confirmed == true;
}

/// The app-bar action back to the mode picker, on screens that are a
/// mode's first step (signing in, pairing a camera).
class SwitchModeButton extends StatelessWidget {
  const SwitchModeButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.swap_horiz),
      label: const Text('Switch mode'),
    );
  }
}

/// A filled button that shows a spinner, and can't be tapped, while
/// [loading].
class LoadingButton extends StatelessWidget {
  const LoadingButton({super.key, required this.loading, required this.onPressed, required this.label});

  final bool loading;

  /// Null disables the button.
  final VoidCallback? onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: loading ? null : onPressed,
      child: loading
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : Text(label),
    );
  }
}
