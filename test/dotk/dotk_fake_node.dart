import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaspium_wallet/dotk/dotk_proof.dart';
import 'package:kaspium_wallet/dotk/dotk_registry.dart';
import 'package:kaspium_wallet/kaspa/kaspa.dart';

final kDeedTxId = 'dd' * 32;

Utxo fakeUtxo(
  String address, {
  String? transactionId,
  int index = 0,
  int daaScore = 0,
  String? covenantId,
}) => Utxo(
  address: address,
  outpoint: Outpoint(transactionId: transactionId ?? kDeedTxId, index: index),
  utxoEntry: UtxoEntry(
    amount: BigInt.one,
    scriptPublicKey: ScriptPublicKey(scriptPublicKey: Uint8List(0), version: 0),
    blockDaaScore: BigInt.from(daaScore),
    isCoinbase: false,
    covenantId: covenantId == null ? null : hexToBytes(covenantId),
  ),
);

class FakeNode implements RpcService {
  final utxos = <Utxo>[];
  final asked = <List<String>>[];

  /// Holds a registry deed at every address it is asked about
  final String? deedsEverywhere;

  FakeNode({this.deedsEverywhere});

  @override
  Future<Iterable<Utxo>> getUtxosByAddresses(Iterable<String> addresses) async {
    asked.add(addresses.toList());
    if (deedsEverywhere case final covenantId?) {
      return [
        for (final address in addresses)
          fakeUtxo(address, covenantId: covenantId),
      ];
    }
    return utxos.where((utxo) => addresses.contains(utxo.address)).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DotkProver provingEverything() => DotkProver(
  FakeNode(deedsEverywhere: DotkRegistry.mainnet.covenantId),
  registry: DotkRegistry.mainnet,
  prefix: .kaspa,
);

/// A CBOR record blob, enough of the encoder for the record sets in the
/// vectors. [sorted] orders the keys by their encoded bytes, as the SDK does.
Uint8List encodeRecords(Map<String, dynamic> records, {bool sorted = false}) {
  final out = BytesBuilder();
  void head(int major, int length) => out.add(switch (length) {
    < 24 => [major << 5 | length],
    < 256 => [major << 5 | 24, length],
    _ => [major << 5 | 25, length >> 8, length & 0xff],
  });
  void text(String value) {
    final bytes = utf8.encode(value);
    head(3, bytes.length);
    out.add(bytes);
  }

  final entries = records.entries.toList();
  if (sorted) {
    List<int> encoded(String key) {
      final bytes = utf8.encode(key);
      final length = bytes.length;
      return [
        ...(length < 24 ? [0x60 | length] : [0x78, length]),
        ...bytes,
      ];
    }

    int order(List<int> a, List<int> b) {
      for (var i = 0; i < a.length && i < b.length; i++) {
        if (a[i] != b[i]) return a[i] - b[i];
      }
      return a.length - b.length;
    }

    entries.sort((a, b) => order(encoded(a.key), encoded(b.key)));
  }
  head(5, entries.length);
  for (final MapEntry(:key, :value) in entries) {
    text(key);
    switch (value) {
      case bool flag:
        out.addByte(flag ? 0xf5 : 0xf4);
      case String value:
        text(value);
      case {'opaque': String hex}:
        out.add(hexToBytes(hex));
    }
  }
  return out.toBytes();
}

/// Waits for [done], and fails after five seconds, naming [reason]
Future<void> until(bool Function() done, {String? reason}) async {
  final stop = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(stop)) {
      fail('Timed out waiting for ${reason ?? 'a condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
