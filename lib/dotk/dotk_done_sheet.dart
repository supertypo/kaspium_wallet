import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_icons.dart';
import '../app_providers.dart';
import '../app_styles.dart';
import '../l10n/l10n.dart';
import '../util/util.dart';
import '../widgets/action_buttons_wrapper.dart';
import '../widgets/address_widgets.dart';
import '../widgets/buttons.dart';
import '../widgets/dismiss_action_buttons.dart';
import '../widgets/sheet_handle.dart';
import '../widgets/sheet_wrapper.dart';
import 'dotk_proven_name.dart';

/// Shown once a .k name transaction is sent
class DotkDoneSheet extends ConsumerWidget {
  final String title;
  final bool titleProven;
  final String? subtitle;
  final String? address;
  final String? txId;
  final String? note;

  /// Shown under the summary, like an offer to set a primary name
  final Widget? extra;

  /// A button over Close, in place of View Transaction
  final String? action;
  final VoidCallback? onAction;

  const DotkDoneSheet({
    super.key,
    required this.title,
    this.titleProven = false,
    this.subtitle,
    this.address,
    this.txId,
    this.note,
    this.extra,
    this.action,
    this.onAction,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final styles = ref.watch(stylesProvider);
    final l10n = l10nOf(context);

    final txId = this.txId;
    final titleStyle = styles.textStyleSettingItemHeaderLarge;

    void showTx() {
      if (txId == null) return;
      openUrl(ref.read(blockExplorerProvider).urlForTx(txId));
    }

    return SheetWrapper(
      child: Column(
        children: [
          const SheetHandle(),
          Expanded(
            child: ListView(
              padding: const .symmetric(horizontal: 28),
              children: [
                const SizedBox(height: 50),
                Icon(AppIcons.success, size: 80, color: theme.dotkAccent),
                const SizedBox(height: 24),
                Semantics(
                  header: true,
                  liveRegion: true,
                  child: titleProven
                      ? DotkProvenName(title, style: titleStyle)
                      : Text(title, style: titleStyle, textAlign: .center),
                ),
                if (subtitle case final subtitle?) ...[
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    style: styles.textStyleSettingItemSubheader.copyWith(
                      fontSize: AppFontSizes.small,
                    ),
                    textAlign: .center,
                  ),
                ],
                if (address case final address?) ...[
                  const SizedBox(height: 4),
                  AddressOneLineText(address: address, type: .PRIMARY60),
                ],
                if (txId != null) ...[
                  const SizedBox(height: 24),
                  Container(
                    padding: const .symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: theme.text05,
                      border: .all(color: theme.text10),
                      borderRadius: .circular(12),
                    ),
                    child: Row(
                      children: [
                        Text(
                          l10n.dotkTransaction,
                          style: styles.textStyleSettingItemSubheader.copyWith(
                            fontSize: AppFontSizes.small,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            txId,
                            maxLines: 1,
                            overflow: .ellipsis,
                            textAlign: .end,
                            style: styles.textStyleAddressText60,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (note case final note?) ...[
                  const SizedBox(height: 12),
                  Text(
                    note,
                    style: styles.textStyleSettingItemSubheader,
                    textAlign: .center,
                  ),
                ],
                if (extra case final extra?) ...[
                  const SizedBox(height: 24),
                  extra,
                ],
              ],
            ),
          ),
          ActionButtonsWrapper(
            buttons: [
              if (action != null)
                PrimaryOutlineButton(title: action!, onPressed: onAction)
              else if (txId != null)
                PrimaryOutlineButton(
                  title: l10n.viewTransaction,
                  onPressed: showTx,
                ),
              const CloseActionButton(),
            ],
          ),
        ],
      ),
    );
  }
}
