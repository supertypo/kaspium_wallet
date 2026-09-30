import '../kaspa/kaspa.dart';

/// transient: can go through later. stale: the node holds this or a
/// conflicting transaction. fatal: no node takes it. unknown: not a mempool
/// verdict, so the node may or may not hold it.
enum DotkRejectVerdict { transient, stale, fatal, unknown }

/// The fragments are the mempool's own wording, the same list @dotk/sdk-tx
/// matches.
abstract class DotkReject {
  // Fatal first. A mass rejection also names a transaction id, and "not
  // standard" carries a nested reason that can say anything.
  static const _fatal = [
    'is larger than max allowed size of',
    'is not standard:',
    'impossible to have a matching UTXO entry',
    'due to incomputable storage mass',
  ];

  static const _duplicate = [
    'is already in the mempool',
    'already accepted by the consensus',
  ];

  static const _doubleSpend = 'already spent by transaction';

  static const _stale = [_doubleSpend, ..._duplicate];

  static const _transient = [
    'is an orphan where orphan is disallowed',
    'lacking a matching UTXO entry',
    'spends an immature UTXO',
    'full with transactions with higher priority',
  ];

  static DotkRejectVerdict classifyMessage(String message) {
    if (_fatal.any(message.contains)) return .fatal;
    if (_stale.any(message.contains)) return .stale;
    if (_transient.any(message.contains)) return .transient;
    return .unknown;
  }

  static DotkRejectVerdict classify(Object error) => switch (error) {
    RpcException(:final message) => classifyMessage(message),
    _ => .unknown,
  };

  /// Whether the node already holds the transaction itself, in its mempool
  /// or accepted
  static bool isDuplicate(Object error) =>
      error is RpcException && _duplicate.any(error.message.contains);

  /// Whether the node refused the transaction because another transaction
  /// spends [outpoint]. kaspad writes it as `(txid, index)` or
  /// `output index of transaction txid`.
  static bool spends(Object error, Outpoint outpoint) {
    if (error is! RpcException || !error.message.contains(_doubleSpend)) {
      return false;
    }
    final message = error.message;
    final id = outpoint.transactionId;
    final index = outpoint.index;
    return message.contains('($id, $index)') ||
        message.contains('output $index of transaction $id ');
  }
}
