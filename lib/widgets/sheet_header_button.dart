import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_providers.dart';

class SheetHeaderButton extends ConsumerWidget {
  final IconData icon;
  final bool visible;
  final VoidCallback? onPressed;

  /// Names the button for screen readers and on a long press
  final String? tooltip;

  const SheetHeaderButton({
    super.key,
    required this.icon,
    this.visible = true,
    required this.onPressed,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final styles = ref.watch(stylesProvider);
    final button = TextButton(
      style: styles.sheetHeaderButtonStyle,
      onPressed: onPressed,
      child: Icon(icon, size: 24, color: theme.text),
    );

    return SizedBox(
      width: 50,
      height: 50,
      child: Visibility(
        visible: visible,
        maintainSize: true,
        maintainAnimation: true,
        maintainState: true,
        child: switch (tooltip) {
          final tooltip? => Tooltip(message: tooltip, child: button),
          null => button,
        },
      ),
    );
  }
}
