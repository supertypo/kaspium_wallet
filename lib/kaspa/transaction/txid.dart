import 'dart:typed_data';

import 'package:blake3_dart/blake3_dart.dart';

import '../types.dart';
import '../utils.dart';

const kTransactionRestDomain = 'TransactionRest';
const kTransactionV1IdDomain = 'TransactionV1Id';
const kPayloadDigestDomain = 'PayloadDigest';

/// blake3 keyed with the domain string, zero-padded to 32 bytes
Uint8List _blake3Hash(Uint8List data, {required String domain}) {
  final key = Uint8List(32)..setAll(0, stringToBytesUtf8(domain));
  return blake3Keyed(key, data);
}

void _addUint16(BytesBuilder builder, int value) => builder.add(
  (ByteData(2)..setUint16(0, value, .little)).buffer.asUint8List(),
);

void _addUint32(BytesBuilder builder, int value) => builder.add(
  (ByteData(4)..setUint32(0, value, .little)).buffer.asUint8List(),
);

void _addUint64(BytesBuilder builder, BigInt value) =>
    builder.add(value.toInt64().toBytes());

/// The id of a version 1 transaction. Signature scripts, compute budgets and
/// the payload bytes are outside the hashed rest, so a transaction can be
/// identified before it is signed.
String transactionIdV1(RawTransaction tx) {
  if (tx.version < 1) {
    throw ArgumentError('Only version 1 transaction ids are computed here');
  }

  final builder = BytesBuilder();
  _addUint16(builder, tx.version);
  _addUint64(builder, .from(tx.inputs.length));
  for (final input in tx.inputs) {
    builder.add(hexToBytes(input.previousOutpoint.transactionId));
    _addUint32(builder, input.previousOutpoint.index);
    _addUint64(builder, .zero); // empty signature script
    _addUint64(builder, input.sequence);
  }
  _addUint64(builder, .from(tx.outputs.length));
  for (final output in tx.outputs) {
    _addUint64(builder, output.value);
    _addUint16(builder, output.scriptPublicKey.version);
    final script = output.scriptPublicKey.scriptPublicKey;
    _addUint64(builder, .from(script.length));
    builder.add(script);
    builder.addByte(output.covenant != null ? 1 : 0);
    if (output.covenant case final covenant?) {
      _addUint16(builder, covenant.authorizingInput);
      builder.add(covenant.covenantId);
    }
  }
  _addUint64(builder, tx.lockTime);
  builder.add(tx.subnetworkId);
  _addUint64(builder, tx.gas);
  _addUint64(builder, .zero); // empty payload

  final payload = _blake3Hash(
    tx.payload ?? Uint8List(0),
    domain: kPayloadDigestDomain,
  );
  final rest = _blake3Hash(builder.takeBytes(), domain: kTransactionRestDomain);

  return _blake3Hash(
    Uint8List.fromList([...payload, ...rest]),
    domain: kTransactionV1IdDomain,
  ).hex;
}
