import 'package:kaspium_wallet/dotk/dotk_registry.dart';
import 'package:kaspium_wallet/kaspa/bip340/bip340.dart' show getPublicKey;
import 'package:kaspium_wallet/kaspa/kaspa.dart';
import 'package:kaspium_wallet/kaspa/rpc/grpc/rpc.pb.dart';

import 'dotk_fake_node.dart';

final testRegistry = DotkRegistry.testnet10;

class TestKey {
  final Uint8List privateKey;
  final Uint8List publicKey;
  final Address address;

  TestKey(String privateHex)
    : privateKey = hexToBytes(privateHex),
      publicKey = hexToBytes(getPublicKey(privateHex)),
      address = Address.publicKey(
        prefix: testRegistry.prefix,
        publicKey: hexToBytes(getPublicKey(privateHex)),
      );
}

class FakeSigner implements SignerBase {
  final List<TestKey> keys;

  FakeSigner(this.keys);

  TestKey? _keyOf(Address address) =>
      keys.where((k) => k.address.encoded == address.encoded).firstOrNull;

  @override
  Future<bool> canSignForAddress(Address address) async =>
      _keyOf(address) != null;

  @override
  Future<Uint8List> sign(Uint8List data, Address address) async =>
      signSchnorr(hash: data, privateKey: _keyOf(address)!.privateKey);
}

/// A node that holds UTXOs, keeps a mempool and can refuse submissions
class FakeTxNode implements RpcService {
  final utxos = <Utxo>[];
  final mempool = <String>{};
  final submitted = <RawTransaction>[];
  var calls = 0;
  var offline = false;
  double feerate = 1;

  /// The priority bucket, which is [feerate] where unset
  double? priorityFeerate;

  /// The ready mempool mass the experimental estimate reports, or null for a
  /// node that does not answer it
  BigInt? readyMass;

  final replaced = <RawTransaction>[];

  /// Answers an error to throw for a submission, or null to take it
  Object? Function(RawTransaction tx)? refuse;

  /// Runs before each UTXO read, with the addresses it reads
  void Function(Iterable<String> addresses)? beforeUtxos;

  void _call() {
    calls++;
    if (offline) {
      throw Exception('Void Client: offline');
    }
  }

  @override
  Future<Iterable<Utxo>> getUtxosByAddresses(
    Iterable<String> addresses,
  ) async {
    _call();
    beforeUtxos?.call(addresses);
    return utxos.where((u) => addresses.contains(u.address)).toList();
  }

  @override
  Future<(String, Transaction)> submitTransactionReplacement(
    RawTransaction transaction,
  ) async {
    _call();
    replaced.add(transaction);
    final id = transactionIdV1(transaction);
    mempool.add(id);
    return (
      id,
      Transaction(transactionId: id, blockTime: 0, isAccepted: false),
    );
  }

  @override
  Future<Iterable<MempoolEntryByAddress>> getMempoolEntriesByAddresses(
    Iterable<String> addresses, {
    bool filterTransactionPool = false,
    bool includeOrphanPool = false,
  }) async {
    _call();
    return [
      MempoolEntryByAddress(
        address: addresses.first,
        sending: [
          for (final id in mempool)
            MempoolEntry(
              fee: 0,
              isOrphan: false,
              transaction: Transaction(
                transactionId: id,
                blockTime: 0,
                isAccepted: false,
              ),
            ),
        ],
      ),
    ];
  }

  @override
  Future<FeeEstimate> getFeeEstimate() async {
    _call();
    return FeeEstimate(
      priorityBucket: FeerateBucket(
        feerate: priorityFeerate ?? feerate,
        estimatedSeconds: 1,
      ),
      normalBuckets: [FeerateBucket(feerate: feerate, estimatedSeconds: 60)],
    );
  }

  @override
  Future<(FeeEstimate, BigInt?)> getFeeEstimateExperimental() async {
    final mass = readyMass;
    if (mass == null) {
      throw RpcException(RPCError(message: 'unknown method'));
    }
    return (await getFeeEstimate(), mass);
  }

  @override
  Future<String> submitTransaction(
    RawTransaction transaction, {
    bool allowOrphan = false,
  }) async {
    _call();
    submitted.add(transaction);
    if (refuse?.call(transaction) case final error?) {
      throw error;
    }
    final id = transactionIdV1(transaction);
    mempool.add(id);
    return id;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The DAA score every [registryUtxo] was accepted at
const kDeedDaaScore = 10;

Utxo registryUtxo(
  String address,
  Outpoint outpoint,
  BigInt amount,
  ScriptPublicKey spk, {
  bool covenant = false,
  bool coinbase = false,
}) => Utxo(
  address: address,
  outpoint: outpoint,
  utxoEntry: UtxoEntry(
    amount: amount,
    scriptPublicKey: spk,
    blockDaaScore: .from(kDeedDaaScore),
    isCoinbase: coinbase,
    covenantId: covenant ? testRegistry.covenantIdBytes : null,
  ),
);

final gapLo = Uint8List(32);
final gapHi = Uint8List.fromList(List.filled(32, 0xff));

final primaryBlob = encodeRecords({
  'primary': true,
  'url': 'https://kaspa.org',
}, sorted: true);

RpcException refusal(String message) =>
    RpcException(RPCError(message: message));
