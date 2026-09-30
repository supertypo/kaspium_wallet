import 'dart:convert';

import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_providers.dart';
import '../kaspa/kaspa.dart';
import 'dotk_registration_notifier.dart';
import 'dotk_registry.dart';
import 'dotk_tx_service.dart';

/// The coins a .k name transaction can spend. The coins list shows a coin
/// as unspent until the transaction that spends it is mined.
final dotkFundingUtxosProvider = Provider.autoDispose<List<Utxo>>((ref) {
  final spent = {
    for (final tx in ref.watch(txNotifierProvider).pendingTxs)
      for (final input in tx.apiTx.inputs) input.previousOutpoint,
  };
  return ref
      .watch(spendableUtxosProvider)
      .where((utxo) => !spent.contains(utxo.outpoint))
      .toList();
});

/// The .k name transaction service for the current wallet and network, or
/// null where the network has no registry or the wallet's keys are ECDSA,
/// which the registry transactions are not signed with
final dotkTxServiceProvider = Provider.autoDispose<DotkTxService?>((ref) {
  final registry = DotkRegistry.forNetworkId(ref.watch(networkIdProvider));
  final wallet = ref.watch(walletProvider);
  if (registry == null || wallet.kind.type == .ecdsa) {
    return null;
  }
  final walletService = ref.watch(walletServiceProvider);
  final addresses = ref.watch(addressNotifierProvider);

  return DotkTxService(
    rpc: ref.watch(kaspaRpcProvider),
    registry: registry,
    signer: walletService.signer,
    isViewOnly: wallet.isViewOnly,
    spendableUtxos: () => ref.read(dotkFundingUtxosProvider),
    changeAddress: () async => (await addresses.changeAddress).address,
    listing: (name) =>
        dotkListingOf(ref.read(dotkServiceProvider), registry, name),
  );
});

/// The registrations this wallet started on this network, kept across
/// restarts. autoDispose only because the wallet provider is: the notifier
/// keeps running without listeners while the wallet and network stay.
final dotkRegistrationProvider = ChangeNotifierProvider.autoDispose((ref) {
  final walletId = ref.watch(walletProvider.select((wallet) => wallet.wid));
  final networkId = ref.watch(networkIdProvider);
  final repository = ref.read(settingsRepositoryProvider);
  final key = 'dotkRegistrations#$walletId#$networkId';
  final reservedKey = reservedOutpointsKey(walletId, networkId);
  final registry = DotkRegistry.forNetworkId(networkId);
  final log = ref.read(loggerProvider);
  ref.keepAlive();

  var alive = true;
  ref.onDispose(() => alive = false);

  final notifier = DotkRegistrationNotifier(
    service: () => ref.read(dotkTxServiceProvider),
    dotk: () => ref.read(dotkServiceProvider),
    // One JSON string, so the saved activation reads back with the exact
    // types it was written with
    load: () {
      final saved = repository.box.tryGet<String>(key);
      if (saved == null) {
        return const [];
      }
      // An entry this version cannot read is dropped, not the whole list
      final loaded = <DotkRegistrationEntry>[];
      try {
        for (final entry in jsonDecode(saved) as List<dynamic>) {
          try {
            loaded.add(
              DotkRegistrationEntry.fromJson(entry as Map<String, dynamic>),
            );
          } catch (e) {
            log.w('Dropped an unreadable .k name registration', error: e);
          }
        }
      } catch (e) {
        log.w('Dropped unreadable .k name registrations', error: e);
      }
      return loaded;
    },
    save: (entries) => repository.box.set(
      key,
      jsonEncode([for (final entry in entries) entry.toJson()]),
    ),
    onReserved: (reserved) {
      Future.microtask(() {
        if (alive) {
          ref.read(reservedOutpointsProvider(reservedKey).notifier).state =
              reserved.toISet();
        }
      });
    },
    holdFailed: () => ref.read(dotkEnabledProvider),
    virtualDaaScore: () => ref.read(lastKnownVirtualDaaScoreProvider),
    evictAfterDaa:
        registry?.params.tEvict ?? DotkRegistrationNotifier.kEvictAfterDaa,
    log: log,
  );

  // The node connection closes in the background, and a wait must not run
  // out while the app cannot reach the node
  if (ref.read(inBackgroundProvider)) {
    notifier.onBackground();
  }
  ref.listen(inBackgroundProvider, (_, inBackground) {
    if (inBackground) {
      notifier.onBackground();
    } else {
      notifier.onForeground();
    }
  });
  ref.listen(dotkEnabledProvider, (_, _) => notifier.publishReserved());
  Future.microtask(notifier.resumeAll);

  return notifier;
});
