import 'package:flutter_test/flutter_test.dart';
import 'package:kaspium_wallet/dotk/dotk_pending_txs.dart';
import 'package:kaspium_wallet/kaspa/kaspa.dart';
import 'package:kaspium_wallet/transactions/transaction_types.dart';

const kWallet = 'kaspa:qwallet';
const kDeed = 'kaspa:pdeed';

/// A null input address is one the wallet could not resolve
Tx _tx(String id, List<String?> inputs) => Tx(
  apiTx: Transaction(
    transactionId: id,
    blockTime: 0,
    isAccepted: false,
    inputs: [
      for (final (index, _) in inputs.indexed)
        TransactionInput(
          transactionId: id,
          index: index,
          previousOutpointHash: 'in-$id',
          previousOutpointIndex: BigInt.from(index),
          signatureScript: '',
          sigOpCount: 1,
        ),
    ],
  ),
  inputData: [
    for (final address in inputs)
      address == null ? null : TxInputData(address: address, amount: 1),
  ],
);

void main() {
  test('a new send leaves .k transactions and the coins they spend', () {
    final split = splitPendingTxs(
      [
        _tx('split', [kWallet]),
        _tx('activate', [kDeed, kWallet]),
        _tx('transfer', [null, kWallet]),
        _tx('send', [kWallet]),
        _tx('pay', [null]),
      ],
      view: (
        ownsAddress: (address) => address == kWallet,
        // The unresolved deed input of the transfer is no wallet coin
        ownsOutpoint: (outpoint) => outpoint.transactionId != 'in-transfer',
        splitTxIds: {'split'},
      ),
    );

    expect(split.others.map((tx) => tx.id), ['send', 'pay']);
    expect(split.dotkSpent, {
      Outpoint(transactionId: 'in-split', index: 0),
      Outpoint(transactionId: 'in-activate', index: 0),
      Outpoint(transactionId: 'in-activate', index: 1),
      Outpoint(transactionId: 'in-transfer', index: 0),
      Outpoint(transactionId: 'in-transfer', index: 1),
    });
  });
}
