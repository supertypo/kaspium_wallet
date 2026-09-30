import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../app_providers.dart';
import '../../app_styles.dart';
import '../../l10n/l10n.dart';
import '../../util/ui_util.dart';
import '../../widgets/action_buttons_wrapper.dart';
import '../../widgets/address_widgets.dart';
import '../../widgets/buttons.dart';
import '../../widgets/dismiss_action_buttons.dart';
import '../../widgets/sheet_util.dart';
import '../../widgets/sheet_widget.dart';
import '../dotk_done_sheet.dart';
import '../dotk_error_text.dart';
import '../dotk_names.dart';
import '../dotk_owned_name.dart';
import '../dotk_proven_name.dart';
import '../dotk_sheet_parts.dart';
import '../dotk_tx_providers.dart';
import '../dotk_tx_service.dart';

/// The last look at a transfer, or at a set or unset of primary, before the
/// wallet signs it
class DotkTransferConfirmSheet extends HookConsumerWidget {
  final DotkOwnedName name;
  final DotkTransferPlan plan;

  /// How the new owner is named, like `bob.k` or an address label
  final String target;

  const DotkTransferConfirmSheet({
    super.key,
    required this.name,
    required this.plan,
    this.target = '',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final styles = ref.watch(stylesProvider);
    final l10n = l10nOf(context);

    final busy = useState(false);
    final display = DotkName.display(name.name);
    final addresses = ref.watch(addressNotifierProvider);
    final from = addresses.getAddress(plan.from.encoded);
    final outside = addresses.getAddress(plan.to.encoded) == null;
    final symbol = ref.watch(kasSymbolProvider);
    final targetText = target.isEmpty ? plan.to.encoded : target;

    final primaryOn =
        plan.isSameOwner && plan.mintBlob != null && name.primary == .none;
    final title = !plan.isSameOwner
        ? l10n.dotkConfirmTransfer
        : primaryOn
        ? l10n.dotkSetPrimary
        : l10n.dotkUnsetPrimary;

    Future<void> send() async {
      final service = ref.read(dotkTxServiceProvider);
      if (service == null || busy.value) return;
      busy.value = true;
      final navigator = Navigator.of(context);

      final message = plan.isSameOwner
          ? l10n.dotkPrimaryAuth(display)
          : l10n.dotkTransferAuth(display);
      final auth = await ref
          .read(authUtilProvider)
          .authenticateForSecret(context, message);
      if (!auth || !context.mounted) {
        busy.value = false;
        return;
      }

      final String txId;
      try {
        txId = await service.sendTransfer(plan);
      } catch (e, st) {
        busy.value = false;
        ref.read(loggerProvider).w('Transfer failed', error: e, stackTrace: st);
        ref.read(hapticUtilProvider).error();
        UIUtil.showSnackbar(dotkErrorText(e, l10n));
        return;
      }
      ref.read(hapticUtilProvider).success();
      // As after a send: the coins it spends stay listed until it is mined
      ref.read(txMonitorProvider).watch(txId);
      ref.invalidate(pendingTxsProvider);

      // Address labels show the old names until asked again, once the node
      // has the transaction and once the change settles
      final labels = ref.read(dotkNamesProvider);
      final moved = {plan.from.encoded, plan.to.encoded};
      labels.refresh(moved);
      unawaited(
        ref
            .read(dotkWalletNamesProvider)
            .follow(
              name,
              to: plan.to.encoded,
              target: targetText,
              inFlight: !plan.isSameOwner,
              mintBlob: plan.mintBlob,
            )
            .then((_) => labels.refresh(moved)),
      );

      // A transfer also closes the transfer and details sheets under this
      // one, since the name has left them
      final pops = plan.isSameOwner ? 1 : 3;
      for (var i = 0; i < pops && navigator.canPop(); i++) {
        navigator.pop();
      }
      if (!navigator.mounted) return;
      Sheets.showAppHeightNineSheet(
        context: navigator.context,
        theme: theme,
        widget: plan.isSameOwner
            ? DotkDoneSheet(title: l10n.dotkPrimaryUpdated(display), txId: txId)
            : DotkDoneSheet(
                title: l10n.dotkTransferred(display),
                subtitle: l10n.dotkTransferredTo(targetText),
                address: plan.to.encoded,
                txId: txId,
                note: l10n.dotkListUpdates,
              ),
      );
    }

    final small = styles.textStyleSettingItemSubheader.copyWith(
      fontSize: AppFontSizes.small,
    );

    return PopScope(
      canPop: !busy.value,
      child: SheetWidget(
        title: title,
        mainWidget: ListView(
          padding: const .symmetric(horizontal: 28),
          children: [
            const SizedBox(height: 6),
            Center(
              child: DotkProvenName(
                display,
                style: styles.textStyleHeader.copyWith(
                  color: theme.dotkAccent,
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (plan.isSameOwner)
              Text(
                primaryOn
                    ? l10n.dotkSetPrimaryBody(display, from?.name ?? '')
                    : l10n.dotkUnsetPrimaryBody,
                style: small,
                textAlign: .center,
              )
            else ...[
              Text(
                from?.name ?? '',
                style: styles.textStyleSettingItemSubheader,
                textAlign: .center,
              ),
              Icon(Icons.arrow_downward, size: 18, color: theme.text60),
              const SizedBox(height: 8),
              DotkBox(
                children: [
                  const SizedBox(height: 6),
                  if (targetText != plan.to.encoded)
                    Center(
                      child: DotkName.isName(target)
                          ? DotkProvenName(
                              target,
                              style: styles.textStyleSettingItemHeader.copyWith(
                                color: theme.dotkAccent,
                              ),
                            )
                          : Text(
                              target,
                              style: styles.textStyleSettingItemHeader,
                            ),
                    ),
                  AddressThreeLineText(
                    address: plan.to.encoded,
                    type: .PRIMARY60,
                  ),
                  const SizedBox(height: 6),
                ],
              ),
            ],
            DotkSection(l10n.dotkDetails),
            DotkBox(
              children: [
                DotkValueRow(l10n.dotkNetworkFee, dotkAmount(plan.fee, symbol)),
                if (plan.cardHeld > .zero)
                  DotkValueRow(
                    l10n.dotkCardHeld,
                    dotkAmount(plan.cardHeld, symbol),
                  ),
                if (plan.cardHeld < .zero)
                  DotkValueRow(
                    l10n.dotkCardReturned,
                    dotkAmount(-plan.cardHeld, symbol),
                  ),
              ],
            ),
            if (plan.cardHeld > .zero)
              Padding(
                padding: const .fromLTRB(4, 8, 4, 0),
                child: Text(
                  l10n.dotkCardHeldNote(dotkAmount(plan.cardHeld, symbol)),
                  style: small,
                ),
              ),
            if (!plan.isSameOwner && plan.clearsRecords) ...[
              const SizedBox(height: 14),
              DotkNotice(l10n.dotkRecordsCleared, kind: .warning),
            ],
            if (!plan.isSameOwner && outside) ...[
              const SizedBox(height: 14),
              DotkNotice(l10n.dotkCannotUndo, kind: .danger),
            ],
            const SizedBox(height: 12),
          ],
        ),
        bottomWidget: ActionButtonsWrapper(
          buttons: [
            PrimaryButton(
              title: l10n.confirm,
              disabled: busy.value,
              onPressed: send,
            ),
            if (!busy.value) const CancelActionButton(),
          ],
        ),
      ),
    );
  }
}
