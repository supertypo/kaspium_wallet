import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../app_providers.dart';
import '../../app_styles.dart';
import '../../kaspa/kaspa.dart';
import '../../l10n/l10n.dart';
import '../../util/ui_util.dart';
import '../../widgets/action_buttons_wrapper.dart';
import '../../widgets/buttons.dart';
import '../../widgets/dialog.dart';
import '../../widgets/dismiss_action_buttons.dart';
import '../../widgets/sheet_util.dart';
import '../../widgets/sheet_widget.dart';
import '../dotk_done_sheet.dart';
import '../dotk_error_text.dart';
import '../dotk_names.dart';
import '../dotk_registry.dart';
import '../dotk_sheet_parts.dart';
import '../dotk_tx.dart';
import '../dotk_tx_providers.dart';
import '../dotk_tx_service.dart';
import '../names_sheet/dotk_name_details_sheet.dart';
import '../transfer_sheet/dotk_transfer_confirm_sheet.dart';
import 'dotk_register_sheet.dart';

/// A registration while it runs, when it is done, and when it failed
class DotkRegisterProgressSheet extends HookConsumerWidget {
  final String name;

  const DotkRegisterProgressSheet({super.key, required this.name});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final styles = ref.watch(stylesProvider);
    final l10n = l10nOf(context);

    final registrations = ref.watch(dotkRegistrationProvider);
    final entry = registrations.entry(name);
    final names = ref.watch(dotkWalletNamesProvider);
    final display = DotkName.display(name);
    final registry = DotkRegistry.forNetworkId(ref.watch(networkIdProvider));
    final deposit = dotkAmount(
      dotkAtRisk(registry?.params),
      ref.watch(kasSymbolProvider),
    );
    // The sheet shows a failure itself, so the home screen does not repeat it
    useEffect(() => registrations.onScreen(name), [registrations, name]);
    final resuming = useState(false);
    final settingPrimary = useState(false);
    final stage = entry?.stage;
    // The deed this wallet's activation made, which carries no card
    final activationId = useMemoized(() {
      final activateTx = entry?.activateTx;
      return activateTx == null ? null : transactionIdV1(activateTx);
    }, [entry?.activate]);

    // The registration was dismissed while the sheet was open
    if (entry == null) {
      return SheetWidget(
        title: l10n.dotkRegistering,
        mainWidget: Padding(
          padding: const .all(28),
          child: Text(
            l10n.dotkRegistrationGone,
            textAlign: .center,
            style: styles.textStyleSettingItemSubheader,
          ),
        ),
        bottomWidget: const ActionButtonsWrapper(
          buttons: [CloseActionButton()],
        ),
      );
    }

    final owner = ref.watch(
      addressNotifierProvider.select(
        (notifier) => notifier.getAddress(entry.owner),
      ),
    );

    Future<void> resume() async {
      if (resuming.value) return;
      resuming.value = true;
      final navigator = Navigator.of(context);
      final theme = ref.read(themeProvider);
      try {
        var need = await registrations.resume(name);
        if (need == .auth && context.mounted) {
          final auth = await ref
              .read(authUtilProvider)
              .authenticateForSecret(context, l10n.dotkRegisterAuth(display));
          if (!auth) return;
          need = await registrations.resume(name, signed: true);
        }
        // The sheet may have been closed while the node answered, and then
        // what the navigator would pop is another route
        if (!context.mounted) return;
        switch (need) {
          case .auth || .none:
            break;
          case .unanswered:
            UIUtil.showSnackbar(l10n.dotkErrorNetwork);
          case .taken:
            UIUtil.showSnackbar(l10n.dotkRegistered(display));
            navigator.pop();
          case .newReservation:
            await registrations.dismiss(name);
            if (!context.mounted) return;
            navigator.pop();
            if (!navigator.mounted) return;
            Sheets.showAppHeightNineSheet(
              context: navigator.context,
              theme: theme,
              widget: DotkRegisterSheet(
                initialName: name,
                initialOwner: entry.owner,
              ),
            );
        }
      } on DotkTxError catch (e) {
        UIUtil.showSnackbar(dotkErrorText(e, l10n));
      } finally {
        if (context.mounted) resuming.value = false;
      }
    }

    Future<void> setPrimary() async {
      final service = ref.read(dotkTxServiceProvider);
      final owned = names.ownedName(name);
      if (service == null || owned == null || settingPrimary.value) return;
      settingPrimary.value = true;
      try {
        final plan = await service.planSetPrimary(
          name: name,
          owner: Address.decodeAddress(owned.address),
          card: owned.listedCard,
          knownDeedTxId: activationId,
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
            ref.read(dotkWalletNamesProvider).awaitName(name, owned.address),
          );
        }
        ref.read(hapticUtilProvider).error();
        UIUtil.showSnackbar(dotkErrorText(e, l10n));
      } finally {
        if (context.mounted) settingPrimary.value = false;
      }
    }

    void viewName() {
      final navigator = Navigator.of(context);
      navigator.pop();
      Sheets.showAppHeightNineSheet(
        context: navigator.context,
        theme: theme,
        widget: DotkNameDetailsSheet(name: name),
      );
    }

    final small = styles.textStyleSettingItemSubheader.copyWith(
      fontSize: AppFontSizes.small,
    );

    if (stage == .done) {
      final owned = names.ownedName(name);
      final hasPrimary = names.names.any(
        (other) => other.address == entry.owner && other.primary == .winner,
      );
      // Offered only once: while the deed is still the activation and no
      // change for it is under way. A card the wallet cannot read or has not
      // proven would lose its content to a new one.
      final offerPrimary =
          owned != null &&
          !hasPrimary &&
          owned.primary == .none &&
          owned.deed.outpoint.transactionId == activationId &&
          !names.isFollowingAt(entry.owner) &&
          (owned.recordsState == .none || owned.recordsState == .proven);

      return DotkDoneSheet(
        title: l10n.dotkIsYours(display),
        titleProven: true,
        subtitle: l10n.dotkOwnerIs(owner?.name ?? entry.owner),
        address: entry.owner,
        action: l10n.dotkViewName(display),
        onAction: viewName,
        extra: offerPrimary
            ? DotkNotice(
                l10n.dotkNoPrimaryOffer(owner?.name ?? '', display),
                action: l10n.dotkSetPrimary,
                onAction: setPrimary,
              )
            : null,
      );
    }

    if (stage == .failed) {
      final message = switch (entry.failure) {
        .notConfirmed => l10n.dotkNotConfirmedYet,
        .dropped => l10n.dotkReservationDropped,
        .raced => l10n.dotkRaced,
        .evicted => l10n.dotkEvicted(deposit),
        .taken => l10n.dotkRegistered(display),
        _ => l10n.dotkRegistrationStopped,
      };
      return SheetWidget(
        title: l10n.dotkRegistrationFailedTitle,
        mainWidget: ListView(
          padding: const .symmetric(horizontal: 28),
          children: [
            Text(
              DotkName.isolated(display),
              textAlign: .center,
              style: styles.textStyleHeader.copyWith(color: theme.dotkAccent),
            ),
            const SizedBox(height: 18),
            Semantics(
              liveRegion: true,
              child: DotkNotice(message, kind: .danger),
            ),
          ],
        ),
        bottomWidget: ActionButtonsWrapper(
          buttons: [
            PrimaryButton(
              title: l10n.dotkResume,
              disabled: resuming.value,
              onPressed: resume,
            ),
            PrimaryOutlineButton(
              title: l10n.dotkDismiss,
              onPressed: () async {
                final navigator = Navigator.of(context);
                Future<void> dismiss() async {
                  await registrations.dismiss(name);
                  if (context.mounted) navigator.pop();
                }

                // A reservation that can still be mined would be evicted
                // with its deposit if nothing follows it
                if (await registrations.isDismissSafe(name)) {
                  await dismiss();
                } else if (context.mounted) {
                  await AppDialogs.showConfirmDialog(
                    context,
                    l10n.dotkDismiss,
                    l10n.dotkDismissUnsafe(deposit),
                    l10n.dotkDismiss.toUpperCase(),
                    dismiss,
                  );
                }
              },
            ),
          ],
        ),
      );
    }

    final seen = entry.pendingSeenAt != null;
    final activating = stage == .activating;
    Widget step(
      String text, {
      required bool done,
      required bool now,
      String? note,
    }) {
      final color = done || now ? theme.dotkAccent : theme.text30;
      return Padding(
        padding: const .symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: .start,
          children: [
            Container(
              width: 24,
              height: 24,
              alignment: .center,
              decoration: BoxDecoration(
                shape: .circle,
                color: done ? theme.dotkAccent : null,
                border: .all(color: color, width: 2),
              ),
              child: done
                  ? Icon(Icons.check, size: 16, color: theme.backgroundDark)
                  : now
                  ? SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(theme.dotkAccent),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: .start,
                children: [
                  Semantics(
                    liveRegion: now,
                    child: Text(
                      text,
                      style: styles.textStyleSettingItemHeader.copyWith(
                        color: done || now ? theme.text : theme.text60,
                      ),
                    ),
                  ),
                  if (note != null) Text(note, style: small),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return SheetWidget(
      title: l10n.dotkRegistering,
      mainWidget: ListView(
        padding: const .symmetric(horizontal: 32),
        children: [
          Text(
            DotkName.isolated(display),
            textAlign: .center,
            style: styles.textStyleHeader.copyWith(color: theme.dotkAccent),
          ),
          const SizedBox(height: 18),
          step(
            l10n.dotkStepReserve,
            done: stage != .reserving,
            now: stage == .reserving,
          ),
          step(
            l10n.dotkStepWait,
            done: seen || activating,
            now: stage == .waiting && !seen,
            note: l10n.dotkStepWaitNote,
          ),
          step(
            l10n.dotkStepActivate,
            done: false,
            now: activating || (stage == .waiting && seen),
          ),
          const SizedBox(height: 28),
          Text(l10n.dotkCanClose, textAlign: .center, style: small),
        ],
      ),
      bottomWidget: const ActionButtonsWrapper(buttons: [CloseActionButton()]),
    );
  }
}
