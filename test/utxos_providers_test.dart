import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspium_wallet/kaspa/kaspa.dart';
import 'package:kaspium_wallet/utxos/utxos_providers.dart';

final _address = Address.decodeAddress(
  'kaspa:qpvtxyhfm0x63y97g2ktamen5ngpdmjwpslcf92quu5x5e5ag3uezpj2gt9km',
);

Utxo _utxo(String txId, int index, BigInt amount, {bool covenant = false}) =>
    Utxo(
      address: _address.encoded,
      outpoint: Outpoint(transactionId: txId, index: index),
      utxoEntry: UtxoEntry(
        amount: amount,
        scriptPublicKey: payToAddressScript(_address),
        blockDaaScore: .from(10),
        isCoinbase: false,
        covenantId: covenant ? hexToBytes('ab' * 32) : null,
      ),
    );

void main() {
  group('spendable UTXOs', () {
    test('leave out covenant, reserved and immature coinbase outputs', () {
      final plain = _utxo('aa' * 32, 0, .from(10));
      final covenant = _utxo('aa' * 32, 1, .from(30), covenant: true);
      final reserved = _utxo('bb' * 32, 2, .from(20));
      final coinbase = plain.copyWith(
        outpoint: Outpoint(transactionId: 'cc' * 32, index: 0),
        utxoEntry: plain.utxoEntry.copyWith(isCoinbase: true),
      );
      final larger = plain.copyWith(
        outpoint: Outpoint(transactionId: 'dd' * 32, index: 0),
        utxoEntry: plain.utxoEntry.copyWith(amount: .from(50)),
      );

      final spendable = spendableUtxosOf(
        [plain, covenant, reserved, coinbase, larger],
        virtualDaaScore: .from(500),
        reserved: ISet({Outpoint(transactionId: 'bb' * 32, index: 2)}),
      );
      expect(spendable, [larger, plain]);
      expect(
        spendableUtxosOf([coinbase], virtualDaaScore: .from(2000)),
        [coinbase],
      );
    });
  });
}
