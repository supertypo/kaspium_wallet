import 'dart:async';

import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stream_transform/stream_transform.dart';

import '../app_providers.dart';
import '../database/boxes.dart';
import '../kaspa/types.dart';
import 'utxos_notifier.dart';

final _utxoBoxProvider = Provider.autoDispose<TypedBox<Utxo>>((ref) {
  final boxInfo = ref.watch(walletBoxInfoProvider);
  final db = ref.watch(dbProvider);

  final boxKey = boxInfo.utxo.boxKey;
  final box = db.getTypedBox<Utxo>(boxKey);

  return box;
});

final utxosChangedProvider = StreamProvider.autoDispose((ref) {
  final rpc = ref.watch(kaspaRpcProvider);
  final addresses = ref.watch(allAddressesProvider);

  ref.onDispose(() async {
    try {
      await rpc.stopNotifyingUtxosChanged(addresses);
    } catch (_) {}
  });

  return rpc.notifyUtxosChanged(addresses);
});

final utxosChangedDebouncedProvider = StreamProvider.autoDispose((ref) {
  final controller = StreamController<UtxosChanged>();
  ref.listen(utxosChangedProvider, (_, next) {
    if (next.asData?.value case final message?) {
      controller.add(message);
    }
  });

  ref.onDispose(controller.close);

  return controller.stream
      .debounceBuffer(const Duration(milliseconds: 500))
      .map(UtxosChanged.merge)
      .where((merged) => merged.added.isNotEmpty || merged.removed.isNotEmpty);
});

final utxoNotifierProvider = ChangeNotifierProvider.autoDispose((ref) {
  final rpc = ref.watch(kaspaRpcProvider);
  final utxoBox = ref.watch(_utxoBoxProvider);
  final log = ref.watch(loggerProvider);

  final notifier = UtxosNotifier(
    rpc: rpc,
    utxoBox: utxoBox,
    log: log,
  );

  ref.listen(
    balanceNotifierProvider.select((notifier) => notifier.balances),
    (_, balances) {
      log.d('UTXOs - Refresh with balances for ${balances.keys}');
      notifier.refreshWithBalances(balances: balances);
    },
  );

  ref.listen(utxosChangedDebouncedProvider, (_, next) {
    if (next.asData?.value case final message?) {
      final addresses = Set.of(
        message.removed.followedBy(message.added).map((utxo) => utxo.address),
      );
      log.d('UTXOs - Refresh with utxos changed for $addresses');
      notifier.refresh(addresses: addresses);
    }
  });

  ref.onDispose(() {
    notifier.disposed = true;
  });

  return notifier;
});

final utxoListProvider = Provider.autoDispose((ref) {
  return ref.watch(
    utxoNotifierProvider.select((notifier) => notifier.utxoList),
  );
});

/// Outpoints a normal send must not spend, like the change output that a
/// signed but unsent .k name activation spends
final reservedOutpointsProvider = StateProvider.family<ISet<Outpoint>, String>(
  (ref, key) => const ISetConst({}),
);

String reservedOutpointsKey(String walletId, String networkId) =>
    '$walletId#$networkId';

/// A covenant UTXO belongs to its covenant, and a reserved one to a pending
/// transaction, so neither funds a send
List<Utxo> spendableUtxosOf(
  Iterable<Utxo> utxos, {
  required BigInt virtualDaaScore,
  ISet<Outpoint> reserved = const ISetConst({}),
}) {
  final spendableUtxos = utxos.where((utxo) {
    if (utxo.utxoEntry.covenantId != null) {
      return false;
    }
    if (reserved.contains(utxo.outpoint)) {
      return false;
    }
    if (!utxo.utxoEntry.isCoinbase) {
      return true;
    }
    return utxo.utxoEntry.blockDaaScore + .from(1000) < virtualDaaScore;
  }).toList();

  spendableUtxos.sort(
    (a, b) => b.utxoEntry.amount.compareTo(a.utxoEntry.amount),
  );

  return spendableUtxos;
}

final spendableUtxosProvider = Provider.autoDispose((ref) {
  final utxos = ref.watch(utxoListProvider);
  final walletId = ref.watch(walletProvider.select((wallet) => wallet.wid));
  final networkId = ref.watch(networkIdProvider);
  final reserved = ref.watch(
    reservedOutpointsProvider(reservedOutpointsKey(walletId, networkId)),
  );
  final virtualDaaScore = ref.read(lastKnownVirtualDaaScoreProvider);

  return spendableUtxosOf(
    utxos,
    virtualDaaScore: virtualDaaScore,
    reserved: reserved,
  );
});

final selectedUtxosProvider =
    StateProvider.autoDispose<ISet<Utxo>>((ref) => ISet());
