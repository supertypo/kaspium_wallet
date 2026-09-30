import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../app_providers.dart';
import '../../l10n/l10n.dart';
import '../../widgets/action_buttons_wrapper.dart';
import '../../widgets/buttons.dart';
import '../../widgets/item_divider.dart';
import '../../widgets/sheet_header_button.dart';
import '../../widgets/sheet_util.dart';
import '../../widgets/sheet_widget.dart';
import '../dotk_logo.dart';
import '../dotk_names.dart';
import '../dotk_owned_name.dart';
import '../dotk_registration_notifier.dart';
import '../dotk_registry.dart';
import '../dotk_sheet_parts.dart';
import '../dotk_tx_providers.dart';
import '../register_sheet/dotk_register_progress_sheet.dart';
import '../register_sheet/dotk_register_sheet.dart';
import 'dotk_name_details_sheet.dart';
import 'dotk_name_item.dart';

/// Every .k name the wallet's addresses own, proven against the wallet's node
class DotkNamesSheet extends HookConsumerWidget {
  const DotkNamesSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final styles = ref.watch(stylesProvider);
    final l10n = l10nOf(context);

    final notifier = ref.watch(dotkWalletNamesProvider);
    final names = notifier.names;
    final failed = notifier.failed;

    useEffect(() {
      Future.microtask(notifier.refreshIfStale);
      return null;
    }, [notifier]);

    void showName(DotkOwnedName name) {
      Sheets.showAppHeightNineSheet(
        context: context,
        theme: theme,
        widget: DotkNameDetailsSheet(name: name.name),
      );
    }

    final inFlight = notifier.inFlight;
    final rows = <DotkOwnedName>[
      for (final flight in inFlight.values)
        if (!names.any((name) => name.name == flight.name.name)) flight.name,
      ...names,
    ];

    final registrations = ref.watch(dotkRegistrationProvider);
    // A finished registration keeps its row until the indexer lists the name
    final registering = [
      ...registrations.entries,
      for (final name in notifier.awaiting) ?registrations.entry(name),
    ].where((entry) => !names.any((name) => name.name == entry.name)).toList();
    final canSign =
        !ref.watch(walletProvider).isViewOnly &&
        ref.watch(dotkTxServiceProvider) != null;

    void showRegistration(String name) => Sheets.showAppHeightNineSheet(
      context: context,
      theme: theme,
      widget: DotkRegisterProgressSheet(name: name),
    );

    final VoidCallback? onRegister = canSign
        ? () => Sheets.showAppHeightNineSheet(
            context: context,
            theme: theme,
            widget: const DotkRegisterSheet(),
          )
        : null;

    // A registration that stopped, or that waits long enough to be at risk,
    // while its reservation still stands. A taken, raced or dropped one
    // holds nothing, and its row says it stopped.
    final unfinished = registering
        .where(
          (entry) =>
              entry.split != null &&
              (entry.stage == .failed ||
                  (entry.stage != .done &&
                      entry.pendingSeenAt != null &&
                      !registrations.isRunning(entry.name))),
        )
        .firstOrNull;

    Widget unfinishedBanner(DotkRegistrationEntry entry) {
      final display = DotkName.display(entry.name);
      // The time left counts in blocks, and the banner changes once a minute
      final minutes = ref.watch(
        lastKnownVirtualDaaScoreProvider.select(
          (_) => registrations.minutesLeft(entry.name),
        ),
      );
      final registry = DotkRegistry.forNetworkId(ref.read(networkIdProvider));
      final deposit = dotkAmount(
        dotkAtRisk(registry?.params),
        ref.read(kasSymbolProvider),
      );
      final text = minutes == null || minutes == 0
          ? l10n.dotkUnfinishedLate(display)
          : l10n.dotkUnfinished(display, minutes, deposit);
      return Padding(
        padding: const .fromLTRB(20, 4, 20, 8),
        child: DotkNotice(
          text,
          kind: .warning,
          action: l10n.dotkResume,
          onAction: () => showRegistration(entry.name),
        ),
      );
    }

    Widget status() {
      final text = notifier.isScanning
          ? l10n.dotkNamesChecking(notifier.checked, notifier.total)
          : notifier.hasScanned && names.isNotEmpty
          ? l10n.dotkNamesSummary(names.length, notifier.addressCount)
          : null;
      return Column(
        children: [
          if (notifier.isScanning)
            Padding(
              padding: const .symmetric(horizontal: 40, vertical: 4),
              child: LinearProgressIndicator(
                value: notifier.total == 0
                    ? null
                    : notifier.checked / notifier.total,
                minHeight: 3,
                color: theme.dotkAccent,
                backgroundColor: theme.text10,
                borderRadius: .circular(2),
              ),
            ),
          if (text != null)
            Padding(
              padding: const .only(bottom: 6),
              child: Semantics(
                // Only the summary is read out, not every address checked
                liveRegion: !notifier.isScanning,
                child: Text(
                  text,
                  style: styles.textStyleSettingItemSubheader,
                  textAlign: .center,
                ),
              ),
            ),
        ],
      );
    }

    Widget incomplete() => Padding(
      padding: const .fromLTRB(20, 4, 20, 8),
      child: DotkNotice(
        l10n.dotkNamesIncomplete(failed.length),
        kind: .warning,
        action: l10n.dotkRetry,
        onAction: notifier.isScanning
            ? null
            : () => notifier.scan(onlyFailed: true),
      ),
    );

    Widget empty() => ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 80),
        const Center(child: DotkLogo(size: 64)),
        const SizedBox(height: 16),
        Semantics(
          // The scan's answer, like the summary a list gets
          liveRegion: true,
          child: Text(
            l10n.dotkNamesEmpty,
            style: styles.textStyleSettingItemHeader60,
            textAlign: .center,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.dotkNamesChecked(notifier.walletTotal),
          style: styles.textStyleSettingItemSubheader,
          textAlign: .center,
        ),
      ],
    );

    final showEmpty =
        rows.isEmpty &&
        registering.isEmpty &&
        notifier.hasScanned &&
        !notifier.isScanning &&
        failed.isEmpty;

    return SheetWidget(
      title: l10n.dotkNames,
      titleWidget: const DotkWordmark(),
      leftWidget: SheetHeaderButton(
        icon: Icons.add,
        visible: onRegister != null,
        onPressed: onRegister,
        tooltip: l10n.dotkRegisterName,
      ),
      // Hidden while a scan runs, which the progress bar shows
      rightWidget: SheetHeaderButton(
        icon: Icons.refresh,
        visible: !notifier.isScanning,
        onPressed: notifier.scan,
        tooltip: l10n.dotkRefresh,
      ),
      mainWidget: Column(
        children: [
          status(),
          if (unfinished != null) unfinishedBanner(unfinished),
          if (failed.isNotEmpty && !notifier.isScanning) incomplete(),
          Expanded(
            child: RefreshIndicator.adaptive(
              color: theme.dotkAccent,
              onRefresh: notifier.scan,
              child: showEmpty
                  ? empty()
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const .only(bottom: 20),
                      itemCount: registering.length + rows.length,
                      separatorBuilder: (_, _) => const ItemDivider(),
                      itemBuilder: (_, index) {
                        if (index < registering.length) {
                          final entry = registering[index];
                          return DotkRegistrationItem(
                            entry: entry,
                            onPressed: () => showRegistration(entry.name),
                          );
                        }
                        final row = rows[index - registering.length];
                        final flight = inFlight[row.name];
                        return DotkNameItem(
                          name: row,
                          status: flight == null ? null : l10n.dotkTransferring,
                          subtitle: flight == null
                              ? null
                              : l10n.dotkTransferredTo(flight.target),
                          onPressed: () => showName(row),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
      bottomWidget: showEmpty && onRegister != null
          ? ActionButtonsWrapper(
              buttons: [
                PrimaryButton(
                  title: l10n.dotkRegisterName,
                  onPressed: onRegister,
                ),
              ],
            )
          : const SizedBox(),
    );
  }
}
