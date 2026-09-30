import 'package:flutter_test/flutter_test.dart';
import 'package:kaspium_wallet/kaspa/kaspa.dart';
import 'package:kaspium_wallet/kaspa/rpc/grpc/rpc.pb.dart';
import 'package:kaspium_wallet/kaspa/rpc/grpc_converters.dart';

final _address = Address.decodeAddress(
  'kaspa:qpvtxyhfm0x63y97g2ktamen5ngpdmjwpslcf92quu5x5e5ag3uezpj2gt9km',
);

void main() {
  group('converters', () {
    test('send covenant bindings, compute budgets and covenant ids', () {
      final covenantId = hexToBytes('ab' * 32);
      final entry = UtxoEntry(
        amount: .from(5),
        scriptPublicKey: payToAddressScript(_address),
        blockDaaScore: .from(7),
        isCoinbase: false,
        covenantId: covenantId,
      );
      final tx = RawTransaction(
        version: 1,
        inputs: [
          RawInput(
            address: _address,
            previousOutpoint: Outpoint(transactionId: 'aa' * 32, index: 3),
            signatureScript: Uint8List.fromList([1, 2]),
            sequence: .zero,
            computeBudget: 150,
            utxoEntry: entry,
          ),
        ],
        outputs: [
          RawOutput(
            value: .from(100),
            scriptPublicKey: payToAddressScript(_address),
            covenant: CovenantBinding(
              authorizingInput: 2,
              covenantId: covenantId,
            ),
          ),
          RawOutput(
            value: .from(1),
            scriptPublicKey: payToAddressScript(_address),
          ),
        ],
        lockTime: .zero,
        subnetworkId: kSubnetworkIdNative,
        gas: .zero,
      );

      final wire = RpcTransaction.fromBuffer(
        encodeTransaction(tx).writeToBuffer(),
      );
      expect(wire.inputs.single.computeBudget, 150);
      expect(wire.outputs[0].hasCovenant(), isTrue);
      expect(wire.outputs[0].covenant.authorizingInput, 2);
      expect(wire.outputs[0].covenant.covenantId, covenantId.hex);
      expect(wire.outputs[1].hasCovenant(), isFalse);

      final utxo = RpcUtxoEntry.fromBuffer(
        encodeUtxoEntry(entry).writeToBuffer(),
      );
      expect(decodeUtxoEntry(utxo).covenantId, covenantId);
      expect(
        decodeUtxoEntry(
          RpcUtxoEntry.fromBuffer(
            encodeUtxoEntry(entry.copyWith(covenantId: null)).writeToBuffer(),
          ),
        ).covenantId,
        isNull,
      );
    });
  });
}
