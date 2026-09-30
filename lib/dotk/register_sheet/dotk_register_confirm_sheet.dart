import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../app_providers.dart';
import '../../l10n/l10n.dart';
import '../../util/ui_util.dart';
import '../../widgets/action_buttons_wrapper.dart';
import '../../widgets/buttons.dart';
import '../../widgets/dismiss_action_buttons.dart';
import '../../widgets/sheet_util.dart';
import '../../widgets/sheet_widget.dart';
import '../dotk_error_text.dart';
import '../dotk_names.dart';
import '../dotk_registration_notifier.dart';
import '../dotk_registry.dart';
import '../dotk_sheet_parts.dart';
import '../dotk_tx_providers.dart';
import '../dotk_tx_service.dart';
import 'dotk_register_progress_sheet.dart';

const _kDaaPerMinute = DotkRegistrationNotifier.kDaaPerSecond * 60;

/// The cost and risk of a registration, before the wallet signs it
class DotkRegisterConfirmSheet extends HookConsumerWidget {
  final DotkRegistrationPlan plan;

  const DotkRegisterConfirmSheet({super.key, required this.plan});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final styles = ref.watch(stylesProvider);
    final l10n = l10nOf(context);

    final busy = useState(false);
    final display = DotkName.display(plan.name);
    final owner = ref.watch(
      addressNotifierProvider.select(
        (notifier) => notifier.getAddress(plan.owner.encoded),
      ),
    );
    final params = DotkRegistry.forNetworkId(
      ref.watch(networkIdProvider),
    )?.params;
    final symbol = ref.watch(kasSymbolProvider);
    String kas(BigInt raw) => dotkAmount(raw, symbol);

    Future<void> register() async {
      final service = ref.read(dotkTxServiceProvider);
      if (service == null || busy.value) return;
      busy.value = true;
      final navigator = Navigator.of(context);

      final auth = await ref
          .read(authUtilProvider)
          .authenticateForSecret(context, l10n.dotkRegisterAuth(display));
      if (!auth || !context.mounted) {
        busy.value = false;
        return;
      }

      final registrations = ref.read(dotkRegistrationProvider);
      // A refusal shows in the progress sheet opened next, not twice
      final release = registrations.onScreen(plan.name);
      try {
        final signed = await service.signRegistration(plan);
        await registrations.start(signed);
      } catch (e, st) {
        release();
        busy.value = false;
        ref
            .read(loggerProvider)
            .w('Registration failed', error: e, stackTrace: st);
        ref.read(hapticUtilProvider).error();
        UIUtil.showSnackbar(dotkErrorText(e, l10n));
        return;
      }
      if (!navigator.mounted) {
        release();
        return;
      }

      // Close this sheet and the search under it
      for (var i = 0; i < 2 && navigator.canPop(); i++) {
        navigator.pop();
      }
      if (!navigator.mounted) {
        release();
        return;
      }
      Sheets.showAppHeightNineSheet(
        context: navigator.context,
        theme: theme,
        widget: DotkRegisterProgressSheet(name: plan.name),
      );
      // The progress sheet holds the name from its first frame
      WidgetsBinding.instance.addPostFrameCallback((_) => release());
    }

    return PopScope(
      canPop: !busy.value,
      child: SheetWidget(
        title: l10n.dotkConfirmRegistration,
        mainWidget: ListView(
          padding: const .symmetric(horizontal: 28),
          children: [
            const SizedBox(height: 6),
            Text(
              DotkName.isolated(display),
              textAlign: .center,
              style: styles.textStyleHeader.copyWith(color: theme.dotkAccent),
            ),
            Text(
              l10n.dotkOwnerIs(owner?.name ?? plan.owner.encoded),
              textAlign: .center,
              style: styles.textStyleSettingItemSubheader,
            ),
            DotkSection(l10n.dotkCost),
            DotkBox(
              children: [
                DotkValueRow(l10n.dotkRegistrationFee, kas(plan.tier)),
                DotkValueRow(l10n.dotkLockedWithName, kas(plan.locked)),
                DotkValueRow(l10n.dotkNetworkFees, kas(plan.networkFee)),
                Divider(height: 1, color: theme.text10),
                DotkValueRow(l10n.dotkTotal, kas(plan.total), bold: true),
              ],
            ),
            Padding(
              padding: const .fromLTRB(4, 8, 4, 14),
              child: Text(
                l10n.dotkLockedNote(kas(plan.locked)),
                style: styles.textStyleSettingItemSubheader,
              ),
            ),
            DotkNotice(
              l10n.dotkKeepOpen(
                (params?.tEvict ?? 0) ~/ _kDaaPerMinute,
                kas(dotkAtRisk(params)),
              ),
              kind: .danger,
            ),
            const SizedBox(height: 12),
          ],
        ),
        bottomWidget: ActionButtonsWrapper(
          buttons: [
            PrimaryButton(
              title: l10n.dotkRegister,
              disabled: busy.value,
              onPressed: register,
            ),
            if (!busy.value) const CancelActionButton(),
          ],
        ),
      ),
    );
  }
}
