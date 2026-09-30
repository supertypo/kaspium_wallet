import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../app_providers.dart';
import '../../app_styles.dart';
import '../../kaspa/kaspa.dart';
import '../../l10n/l10n.dart';
import '../../util/ui_util.dart';
import '../../util/util.dart';
import '../../wallet_address/address_details_sheet.dart';
import '../../widgets/action_buttons_wrapper.dart';
import '../../widgets/address_widgets.dart';
import '../../widgets/buttons.dart';
import '../../widgets/dismiss_action_buttons.dart';
import '../../widgets/sheet_util.dart';
import '../../widgets/sheet_widget.dart';
import '../dotk_error_text.dart';
import '../dotk_names.dart';
import '../dotk_proven_name.dart';
import '../dotk_record_edits.dart';
import '../dotk_registry.dart';
import '../dotk_sheet_parts.dart';
import '../dotk_subname.dart';
import '../dotk_tx_providers.dart';
import '../dotk_tx_service.dart';
import '../transfer_sheet/dotk_transfer_confirm_sheet.dart';
import '../transfer_sheet/dotk_transfer_sheet.dart';
import 'dotk_primary_chip.dart';
import 'dotk_record_row.dart';

/// One name the wallet owns: its owner, subnames and records
class DotkNameDetailsSheet extends HookConsumerWidget {
  final String name;

  const DotkNameDetailsSheet({super.key, required this.name});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final styles = ref.watch(stylesProvider);
    final l10n = l10nOf(context);

    final names = ref.watch(dotkWalletNamesProvider);
    final owned = names.ownedName(name);
    final prefix = ref.watch(addressPrefixProvider);
    final registry = DotkRegistry.forNetworkId(ref.watch(networkIdProvider));
    final busy = useState(false);

    // The name left the wallet's addresses while the sheet was open
    if (owned == null) {
      return SheetWidget(
        title: DotkName.display(name),
        // A .k name keeps its case, which the plain title would raise
        titleWidget: Text(
          DotkName.isolated(DotkName.display(name)),
          style: styles.textStyleHeader,
        ),
        mainWidget: Padding(
          padding: const .all(28),
          child: Text(
            // A name just registered, which the indexer does not list yet
            names.awaiting.contains(name)
                ? l10n.dotkBeingListed
                : l10n.dotkNameGone,
            textAlign: .center,
            style: styles.textStyleSettingItemSubheader,
          ),
        ),
        bottomWidget: const ActionButtonsWrapper(
          buttons: [CloseActionButton()],
        ),
      );
    }

    final canSign =
        !ref.watch(walletProvider).isViewOnly &&
        ref.watch(dotkTxServiceProvider) != null;
    // A change still being followed is not offered again meanwhile
    final following = names.isFollowing(owned.name);

    void transfer() => Sheets.showAppHeightNineSheet(
      context: context,
      theme: theme,
      widget: DotkTransferSheet(name: owned),
    );

    Future<void> unsetPrimary() async {
      final service = ref.read(dotkTxServiceProvider);
      final card = owned.card;
      if (service == null || card == null || busy.value) return;
      busy.value = true;
      try {
        final plan = await service.planUnsetPrimary(
          name: owned.name,
          owner: Address.decodeAddress(owned.address),
          card: card,
        );
        if (!context.mounted) return;
        Sheets.showAppHeightNineSheet(
          context: context,
          theme: theme,
          widget: DotkTransferConfirmSheet(name: owned, plan: plan),
        );
      } catch (e, st) {
        ref
            .read(loggerProvider)
            .w('Unset primary failed', error: e, stackTrace: st);
        if (e is DotkSettlingError) {
          // The next try reads the name once the indexer has caught up
          unawaited(
            ref
                .read(dotkWalletNamesProvider)
                .awaitName(owned.name, owned.address),
          );
        }
        ref.read(hapticUtilProvider).error();
        UIUtil.showSnackbar(dotkErrorText(e, l10n));
      } finally {
        if (context.mounted) busy.value = false;
      }
    }

    Future<void> setPrimary() async {
      final service = ref.read(dotkTxServiceProvider);
      if (service == null || busy.value) return;
      busy.value = true;
      try {
        final plan = await service.planSetPrimary(
          name: owned.name,
          owner: Address.decodeAddress(owned.address),
          card: owned.listedCard,
        );
        if (!context.mounted) return;
        Sheets.showAppHeightNineSheet(
          context: context,
          theme: theme,
          widget: DotkTransferConfirmSheet(name: owned, plan: plan),
        );
      } catch (e, st) {
        ref
            .read(loggerProvider)
            .w('Set primary failed', error: e, stackTrace: st);
        if (e is DotkSettlingError) {
          // The next try reads the name once the indexer has caught up
          unawaited(
            ref
                .read(dotkWalletNamesProvider)
                .awaitName(owned.name, owned.address),
          );
        }
        ref.read(hapticUtilProvider).error();
        UIUtil.showSnackbar(dotkErrorText(e, l10n));
      } finally {
        if (context.mounted) busy.value = false;
      }
    }

    final walletAddress = ref.watch(
      addressNotifierProvider.select(
        (notifier) => notifier.getAddress(owned.address),
      ),
    );
    final winner = owned.primary == .older
        ? names.names
              .where(
                (other) =>
                    other.address == owned.address && other.primary == .winner,
              )
              .firstOrNull
        : null;

    final subnames = <(String, String?)>[];
    final records = <MapEntry<String, Object>>[];
    for (final entry in owned.records.entries) {
      if (entry.key.startsWith(DotkSubname.recordPrefix)) {
        final label = entry.key.substring(DotkSubname.recordPrefix.length);
        subnames.add((
          DotkName.isolated('$label.${DotkName.display(owned.name)}'),
          DotkSubname.payee(entry.value, prefix),
        ));
      } else if (entry.key != DotkRecordEdits.primaryKey) {
        records.add(entry);
      }
    }
    subnames.sort((a, b) => a.$1.compareTo(b.$1));
    records.sort((a, b) => a.key.compareTo(b.key));

    Future<void> copy(String text, String message) async {
      await Clipboard.setData(ClipboardData(text: text));
      UIUtil.showSnackbar(message);
    }

    void showOwner() {
      if (walletAddress == null) {
        return;
      }
      Sheets.showAppHeightNineSheet(
        context: context,
        theme: theme,
        widget: AddressDetailsSheet(address: walletAddress),
      );
    }

    Widget state(String text, {Color? color}) => Padding(
      padding: const .symmetric(vertical: 14),
      child: Center(
        child: Text(
          text,
          style: styles.textStyleSettingItemSubheader.copyWith(
            fontSize: AppFontSizes.small,
            color: color,
          ),
          textAlign: .center,
        ),
      ),
    );

    Widget recordValue(Object value) => switch (value) {
      String() => Text(value),
      bool() => Text(value ? l10n.yes : l10n.no),
      Uint8List() => Text(l10n.dotkBinaryValue(value.length)),
      _ => const SizedBox(),
    };

    final siteUrl = registry?.siteUrl;

    return SheetWidget(
      title: DotkName.display(owned.name),
      titleWidget: Column(
        children: [
          DotkProvenName(
            DotkName.display(owned.name),
            style: styles.textStyleHeader.copyWith(color: theme.dotkAccent),
          ),
          if (owned.primary != .none) ...[
            const SizedBox(height: 4),
            DotkPrimaryChip(owned.primary),
          ],
        ],
      ),
      mainWidget: ListView(
        padding: const .symmetric(horizontal: 24),
        children: [
          if (following)
            Padding(
              padding: const .only(top: 12),
              child: DotkNotice(l10n.dotkChangeConfirming),
            ),
          if (owned.primary == .older && winner != null)
            Padding(
              padding: const .only(top: 12),
              child: DotkNotice(
                l10n.dotkOlderPrimaryNotice(DotkName.display(winner.name)),
                kind: .warning,
                action: canSign && !following ? l10n.dotkUnsetPrimary : null,
                onAction: unsetPrimary,
              ),
            ),
          // A new card copies the proven records, so a card the wallet cannot
          // read or has not proven yet would lose its content
          if (canSign &&
              owned.primary == .none &&
              !following &&
              (owned.recordsState == .none || owned.recordsState == .proven))
            Center(
              child: TextButton(
                onPressed: busy.value ? null : setPrimary,
                style: TextButton.styleFrom(
                  foregroundColor: theme.dotkAccent,
                  minimumSize: const Size(48, 48),
                ),
                child: Text(l10n.dotkSetPrimary.toUpperCase()),
              ),
            ),
          DotkSection(l10n.dotkOwner),
          DotkBox(
            children: [
              InkWell(
                onTap: showOwner,
                onLongPress: () => copy(owned.address, l10n.addressCopied),
                child: Padding(
                  padding: const .symmetric(vertical: 10),
                  child: Column(
                    crossAxisAlignment: .stretch,
                    children: [
                      Text(
                        walletAddress?.name ?? '',
                        style: styles.textStyleSettingItemHeader,
                      ),
                      const SizedBox(height: 2),
                      AddressThreeLineText(
                        address: owned.address,
                        type: .PRIMARY60,
                        textAlign: .start,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (subnames.isNotEmpty) ...[
            DotkSection(l10n.dotkSubnames),
            DotkBox(
              children: [
                for (final (subname, payee) in subnames)
                  DotkRecordRow(
                    label: subname,
                    stacked: true,
                    value: payee == null
                        ? const SizedBox()
                        : AddressOneLineText(address: payee, type: .PRIMARY60),
                    copyText: payee,
                  ),
              ],
            ),
          ],
          DotkSection(l10n.dotkRecords),
          switch (owned.recordsState) {
            .none => DotkBox(children: [state(l10n.dotkNoRecords)]),
            .unreadable => DotkBox(
              children: [state(l10n.dotkRecordsUnreadable)],
            ),
            // The indexer lists the new card a little after the node
            .unproven when following || names.isPolling(owned.name) => DotkBox(
              children: [state(l10n.dotkRecordsPending)],
            ),
            .unproven => DotkBox(
              children: [
                state(l10n.dotkRecordsUnproven, color: theme.warning),
              ],
            ),
            .proven when records.isEmpty => DotkBox(
              children: [state(l10n.dotkNoRecords)],
            ),
            .proven => DotkBox(
              children: [
                for (final MapEntry(:key, :value) in records)
                  DotkRecordRow.forRecord(
                    recordKey: key,
                    recordValue: value,
                    value: recordValue(value),
                  ),
              ],
            ),
          },
          if (owned.recordsState == .proven && records.isNotEmpty)
            Padding(
              padding: const .fromLTRB(4, 8, 4, 0),
              child: Text(
                l10n.dotkRecordsNote,
                style: styles.textStyleSettingItemSubheader,
              ),
            ),
          if (!canSign && ref.watch(walletProvider).isViewOnly)
            Padding(
              padding: const .only(top: 16),
              child: DotkNotice(l10n.dotkWatchOnly),
            ),
          const SizedBox(height: 12),
        ],
      ),
      bottomWidget: ActionButtonsWrapper(
        buttons: [
          if (canSign)
            PrimaryButton(
              title: l10n.transfer,
              disabled: following || busy.value,
              onPressed: transfer,
            ),
          if (siteUrl != null)
            PrimaryOutlineButton(
              title: l10n.dotkViewOnSite,
              onPressed: () => openUrl('$siteUrl/names/${owned.name}'),
            ),
          if (!canSign) const CloseActionButton(),
        ],
      ),
    );
  }
}
