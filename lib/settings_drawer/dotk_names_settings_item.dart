import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_providers.dart';
import '../dotk/dotk_logo.dart';
import '../dotk/names_sheet/dotk_names_sheet.dart';
import '../l10n/l10n.dart';
import '../widgets/sheet_util.dart';

/// The dot.k lockup in the drawer. It opens the names the wallet owns.
class DotkNamesSettingsItem extends ConsumerWidget {
  const DotkNamesSettingsItem({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final styles = ref.watch(stylesProvider);
    final l10n = l10nOf(context);

    void showNames() {
      Sheets.showAppHeightNineSheet(
        context: context,
        theme: theme,
        widget: const DotkNamesSheet(),
      );
    }

    return TextButton(
      style: styles.defaultTextButtonStyle,
      onPressed: showNames,
      child: Semantics(
        label: '${l10n.dotkNameLabel}, ${l10n.dotkNames}',
        excludeSemantics: true,
        // Matches SingleLineItem's icon slot and text start
        child: Container(
          height: 60,
          margin: const .directional(start: 30),
          alignment: AlignmentDirectional.centerStart,
          padding: const .directional(start: 3),
          child: DotkWordmark(
            logoSize: 24,
            gap: 16,
            style: styles.textStyleSettingItemHeader,
          ),
        ),
      ),
    );
  }
}
