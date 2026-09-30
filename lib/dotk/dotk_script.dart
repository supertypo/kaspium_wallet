import 'dart:typed_data';

/// Kaspa's canonical script pushes, as kaspa_txscript's ScriptBuilder writes
/// them. A push that differs by one byte is a different script, a different
/// sighash and a rejected transaction.
class DotkScript {
  static const opFalse = 0x00;
  static const opPushData1 = 0x4c;
  static const opPushData2 = 0x4d;
  static const op1Negate = 0x4f;
  static const op1 = 0x51;
  static const op16 = 0x60;

  /// A signature push is 64 bytes of signature and one sighash type byte
  static const sigLength = 65;

  final _bytes = BytesBuilder();

  /// Pushes data the way the builder does. A single byte of 1 to 16, or 0x81,
  /// takes its one-opcode form.
  DotkScript addData(List<int> data) {
    if (data.length == 1 && data[0] == 0x81) {
      _bytes.addByte(op1Negate);
    } else if (data.length == 1 && data[0] >= 1 && data[0] <= 16) {
      _bytes.addByte(op1 - 1 + data[0]);
    } else {
      _rawData(data);
    }
    return this;
  }

  /// Pushes a script number. Small values take their own opcode.
  DotkScript addInt(int value) {
    if (value == 0) {
      _bytes.addByte(opFalse);
    } else if (value == -1 || (value >= 1 && value <= 16)) {
      _bytes.addByte(op1 - 1 + value);
    } else {
      _rawData(scriptNumber(value));
    }
    return this;
  }

  Uint8List bytes() => _bytes.toBytes();

  void _rawData(List<int> data) {
    final length = data.length;
    if (length == 0) {
      _bytes.addByte(opFalse);
      return;
    }
    if (length <= 75) {
      _bytes.addByte(length);
    } else if (length <= 0xff) {
      _bytes.add([opPushData1, length]);
    } else if (length <= 0xffff) {
      _bytes.add([opPushData2, length & 0xff, length >> 8]);
    } else {
      throw ArgumentError('Push of $length bytes is too large');
    }
    _bytes.add(data);
  }

  /// Little-endian magnitude with the sign in the top bit of the last byte
  static Uint8List scriptNumber(int value) {
    if (value == 0) {
      return Uint8List(0);
    }
    final negative = value < 0;
    var magnitude = value.abs();
    final out = <int>[];
    while (magnitude > 0) {
      out.add(magnitude & 0xff);
      magnitude >>= 8;
    }
    if (out.last & 0x80 != 0) {
      out.add(negative ? 0x80 : 0x00);
    } else if (negative) {
      out.last |= 0x80;
    }
    return Uint8List.fromList(out);
  }

  /// Where each data push's payload begins and how long it is. Stops at the
  /// first opcode that is not a push.
  static List<(int, int)> pushesOf(Uint8List script) {
    final found = <(int, int)>[];
    var at = 0;
    while (at < script.length) {
      final op = script[at];
      final int length;
      final int data;
      if (op >= 0x01 && op <= 0x4b) {
        length = op;
        data = at + 1;
      } else if (op == opPushData1 && at + 1 < script.length) {
        length = script[at + 1];
        data = at + 2;
      } else if (op == opPushData2 && at + 2 < script.length) {
        length = script[at + 1] | script[at + 2] << 8;
        data = at + 3;
      } else if (op == opFalse ||
          op == op1Negate ||
          (op >= op1 && op <= op16)) {
        at += 1;
        continue;
      } else {
        break;
      }
      if (data + length > script.length) {
        break;
      }
      found.add((data, length));
      at = data + length;
    }
    return found;
  }

  /// Writes a 65-byte signature over the first all-zero 65-byte push
  static Uint8List patchSignature(Uint8List script, Uint8List signature) {
    if (signature.length != sigLength) {
      throw ArgumentError('A signature push is $sigLength bytes');
    }
    for (final (at, length) in pushesOf(script)) {
      if (length == sigLength &&
          script.skip(at).take(sigLength).every((b) => b == 0)) {
        return Uint8List.fromList(script)..setAll(at, signature);
      }
    }
    throw StateError('The script carries no signature placeholder');
  }

  static bool hasPlaceholder(Uint8List script) => pushesOf(script).any(
    (push) =>
        push.$2 == sigLength &&
        script.skip(push.$1).take(sigLength).every((b) => b == 0),
  );
}
