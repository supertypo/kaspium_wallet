import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../app_providers.dart';
import '../app_router.dart';
import '../chain_state/chain_state.dart';
import '../dotk/dotk_names.dart';
import '../dotk/dotk_tx_providers.dart';
import '../l10n/l10n.dart';
import '../main_card/main_card.dart';
import '../settings_drawer/settings_drawer.dart';
import '../util/routes.dart';
import '../util/ui_util.dart';
import '../wallet_home/wallet_home.dart';
import '../widgets/network_banner.dart';
import 'lock_screen.dart';
import 'password_lock_screen.dart';

class HomeScreen extends HookConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    l10nWrapper.l10n = l10nOf(context);

    final scaffoldKey = ref.watch(homePageScaffoldKeyProvider);

    // Finishes .k name registrations a restart interrupted, and says when one
    // stops, wherever the user is
    ref.listen(dotkRegistrationProvider, (_, registrations) {
      final names = ref.read(dotkWalletNamesProvider);
      final labels = ref.read(dotkNamesProvider);
      for (final entry in registrations.takeNewlyDone()) {
        // The indexer lists the new name a little after the node shows it,
        // and the owner's label asks again once it does
        unawaited(
          names
              .awaitName(entry.name, entry.owner)
              .then((_) => labels.refresh([entry.owner])),
        );
      }
      for (final name in registrations.takeNewFailures()) {
        UIUtil.showSnackbar(
          l10nOf(context).dotkRegistrationStoppedNotice(DotkName.display(name)),
        );
      }
    });

    ref.listen(walletAuthProvider.select((walletAuth) => walletAuth.isLocked), (
      wasLocked,
      isLocked,
    ) {
      if (wasLocked == isLocked) {
        return;
      }
      if (isLocked) {
        final walletAuth = ref.read(walletAuthProvider);
        final lockScreen = walletAuth.needsLegacyPasswordAuth
            ? const PasswordLockScreen()
            : const LockScreen(autoTransition: false);

        appRouter.push(
          context,
          BarrierRoute(builder: (_) => lockScreen),
        );
      } else {
        if (appRouter.isTopRoute<BarrierRoute>(context)) {
          appRouter.pop(context);
        }
      }
    });

    void autoLock() {
      // whether we should avoid locking the app
      final lockDisabled = ref.read(lockDisabledProvider);
      if (lockDisabled) return;

      final notifier = ref.read(walletAuthProvider.notifier);
      notifier.autoLock();
    }

    Future<void> saveChainState() async {
      final virtualDaaScore = ref.read(lastKnownVirtualDaaScoreProvider);
      final blueScore = ref.read(virtualSelectedParentBlueScoreProvider);
      final repository = ref.read(settingsRepositoryProvider);
      await repository.setChainState(
        ChainState(
          virtualDaaScore: virtualDaaScore,
          virtualSelectedParentBlueScore: blueScore,
        ),
      );
    }

    useOnAppLifecycleStateChange((_, state) {
      switch (state) {
        case .inactive:
          saveChainState();
          break;
        case .hidden:
          break;
        case .paused:
          ref.read(inBackgroundProvider.notifier).state = true;
          autoLock();
          break;
        case .resumed:
          if (ref.read(inBackgroundProvider)) {
            final remote = ref.read(remoteRefreshProvider.notifier);
            remote.update((state) => state + 1);
          }

          ref.read(inBackgroundProvider.notifier).state = false;
          break;
        case .detached:
          break;
      }
    });

    final width = MediaQuery.widthOf(context);
    final drawerWidth = (width < 375) ? width * 0.94 : width * 0.85;

    return Scaffold(
      key: scaffoldKey,
      drawerEdgeDragWidth: 60,
      resizeToAvoidBottomInset: false,
      backgroundColor: theme.background,
      drawerScrimColor: theme.barrierWeaker,
      drawer: SizedBox(
        width: drawerWidth,
        child: const Drawer(child: SettingsSheet()),
      ),
      extendBody: true,
      body: SafeArea(
        maintainBottomViewPadding: true,
        child: ClipRect(
          child: NetworkBanner(
            child: Padding(
              padding: const .only(top: 4),
              child: const WalletHome(),
            ),
          ),
        ),
      ),
    );
  }
}
