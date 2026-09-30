import '../kaspa/types.dart';
import '../kaspa/utils.dart';

/// A signed transaction as JSON, so a registration can keep its activation
/// until the reservation is mined. Nothing in it is secret.
abstract class DotkTxCodec {
  static Map<String, Object?> toJson(RawTransaction tx) => {
    'version': tx.version,
    'inputs': [
      for (final input in tx.inputs)
        {
          'address': input.address.encoded,
          'transactionId': input.previousOutpoint.transactionId,
          'index': input.previousOutpoint.index,
          'signatureScript': input.signatureScript.hex,
          'sequence': input.sequence.toString(),
          'sigOpCount': input.sigOpCount,
          'computeBudget': input.computeBudget,
          'utxoEntry': input.utxoEntry.toJson(),
        },
    ],
    'outputs': [
      for (final output in tx.outputs)
        {
          'value': output.value.toString(),
          'scriptPublicKey': output.scriptPublicKey.toJson(),
          if (output.covenant case final covenant?)
            'covenant': {
              'authorizingInput': covenant.authorizingInput,
              'covenantId': covenant.covenantId.hex,
            },
        },
    ],
    'lockTime': tx.lockTime.toString(),
    'subnetworkId': tx.subnetworkId.hex,
    'gas': tx.gas.toString(),
    'payload': tx.payload?.hex,
  };

  static RawTransaction fromJson(Map<String, dynamic> json) => RawTransaction(
    version: json['version'] as int,
    inputs: [
      for (final input in (json['inputs'] as List).cast<Map<String, dynamic>>())
        RawInput(
          address: Address.decodeAddress(input['address'] as String),
          previousOutpoint: Outpoint(
            transactionId: input['transactionId'] as String,
            index: input['index'] as int,
          ),
          signatureScript: hexToBytes(input['signatureScript'] as String),
          sequence: .parse(input['sequence'] as String),
          sigOpCount: input['sigOpCount'] as int,
          computeBudget: input['computeBudget'] as int,
          utxoEntry: UtxoEntry.fromJson(
            (input['utxoEntry'] as Map).cast<String, dynamic>(),
          ),
        ),
    ],
    outputs: [
      for (final output
          in (json['outputs'] as List).cast<Map<String, dynamic>>())
        RawOutput(
          value: .parse(output['value'] as String),
          scriptPublicKey: ScriptPublicKey.fromJson(
            (output['scriptPublicKey'] as Map).cast<String, dynamic>(),
          ),
          covenant: switch (output['covenant']) {
            final Map<String, dynamic> covenant => CovenantBinding(
              authorizingInput: covenant['authorizingInput'] as int,
              covenantId: hexToBytes(covenant['covenantId'] as String),
            ),
            _ => null,
          },
        ),
    ],
    lockTime: .parse(json['lockTime'] as String),
    subnetworkId: hexToBytes(json['subnetworkId'] as String),
    gas: .parse(json['gas'] as String),
    payload: switch (json['payload']) {
      final String payload => hexToBytes(payload),
      _ => null,
    },
  );
}
