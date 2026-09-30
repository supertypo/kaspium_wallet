import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_providers.dart';
import '../kaspa/kaspa.dart';
import '../transactions/transaction_types.dart';
import 'dotk_tx_providers.dart';

/// What tells the wallet's own transactions apart from .k ones
typedef DotkWalletView = ({
  bool Function(String address) ownsAddress,
  bool Function(Outpoint outpoint) ownsOutpoint,
  Set<String> splitTxIds,
});

/// Whether a pending transaction is a .k name transaction: it spends an
/// output no wallet address holds, like a deed, or it is the split of a
/// registration this wallet runs. A cancel or a replacement leaves it alone.
/// An input whose address is not resolved counts by its coin.
bool _isDotkTx(Tx tx, DotkWalletView view) {
  if (view.splitTxIds.contains(tx.id)) return true;
  for (final (at, input) in tx.apiTx.inputs.indexed) {
    final data = at < tx.inputData.length ? tx.inputData[at] : null;
    final foreign = data == null
        ? !view.ownsOutpoint(input.previousOutpoint)
        : !view.ownsAddress(data.address);
    if (foreign) return true;
  }
  return false;
}

/// Whether [tx] is one of this wallet's .k name transactions
bool isWalletDotkTx(WidgetRef ref, Tx tx) {
  final view = _walletView(ref);
  return view != null && _isDotkTx(tx, view);
}

/// Null while .k names are off, when no transaction is one
DotkWalletView? _walletView(WidgetRef ref) {
  if (!ref.read(dotkNamesAvailableProvider)) return null;
  final coins = {
    for (final utxo in ref.read(utxoListProvider)) utxo.outpoint,
  };
  return (
    ownsAddress: ref.read(addressNotifierProvider).containsAddress,
    ownsOutpoint: coins.contains,
    splitTxIds: {
      for (final entry in ref.read(dotkRegistrationProvider).entries)
        entry.splitTxId,
    },
  );
}

/// The wallet's pending transactions apart from its .k name transactions,
/// and the outpoints those spend, which a new send must not spend again
({IList<Tx> others, ISet<Outpoint> dotkSpent}) pendingTxsBesideDotk(
  WidgetRef ref,
) {
  final pending = ref.read(txNotifierProvider).pendingTxs;
  final view = _walletView(ref);
  if (view == null) {
    return (others: pending, dotkSpent: const ISetConst({}));
  }
  return splitPendingTxs(pending, view: view);
}

({IList<Tx> others, ISet<Outpoint> dotkSpent}) splitPendingTxs(
  Iterable<Tx> pending, {
  required DotkWalletView view,
}) {
  final others = <Tx>[];
  final dotkSpent = <Outpoint>{};
  for (final tx in pending) {
    if (_isDotkTx(tx, view)) {
      dotkSpent.addAll(tx.apiTx.inputs.map((input) => input.previousOutpoint));
    } else {
      others.add(tx);
    }
  }
  return (others: others.lock, dotkSpent: dotkSpent.lock);
}
