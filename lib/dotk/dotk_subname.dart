import 'dart:typed_data';

import 'package:pointycastle/ecc/curves/secp256k1.dart';

import '../kaspa/types/address.dart';
import '../kaspa/types/address_prefix.dart';
import '../kaspa/utils.dart';

/// One `sub:<label>` record on a name's card, read as the address it pays.
///
/// The value carries no network prefix and no checksum, so a reader renders it
/// under the prefix the registry answered with.
///
/// A payee is the claim of whoever owns the parent name.
abstract class DotkSubname {
  static const _recordPrefix = 'sub:';

  /// The whole CBOR item: the head bytes `0x58 0x21`, which introduce a byte
  /// string of 33 bytes, then the scheme byte and its 32-byte payload.
  static const _valueLength = 35;

  // The two ECDSA schemes hold the compressed key's x with its y parity in the
  // scheme byte, and the larger byte is the even one.
  static const _schnorr = 0x00;
  static const _scriptHash = 0x03;
  static const _ecdsaOddY = 0x85;
  static const _ecdsaEvenY = 0x86;

  static final _secp256k1 = ECCurve_secp256k1();

  static String recordKey(String label) => '$_recordPrefix$label';

  /// The address a record value pays, or null.
  static String? payee(Object? value, AddressPrefix prefix) {
    // A CBOR text or flag item arrives as JSON text or a boolean, so a value
    // that is not an opaque item is a refusal rather than a surprise
    if (value is! Map<String, Object?>) {
      return null;
    }
    final bytes = _hex(value['opaque']);
    if (bytes == null ||
        bytes.length != _valueLength ||
        bytes[0] != 0x58 ||
        bytes[1] != 0x21) {
      return null;
    }
    final scheme = bytes[2];
    final payload = Uint8List.sublistView(bytes, 3);
    if (payload.every((byte) => byte == 0)) {
      return null;
    }

    switch (scheme) {
      case _schnorr:
        if (!_onCurve(_compressed(0x02, payload))) {
          return null;
        }
        return Address.publicKey(prefix: prefix, publicKey: payload).encoded;
      case _scriptHash:
        return Address.scriptHash(prefix: prefix, hash: payload).encoded;
      case _ecdsaOddY:
      case _ecdsaEvenY:
        final key = _compressed(0x02 | (scheme & 0x01), payload);
        if (!_onCurve(key)) {
          return null;
        }
        return Address.pubKeyECDSA(prefix: prefix, publicKey: key).encoded;
      default:
        return null;
    }
  }

  /// Whether a compressed key is a point. Roughly half of all 32-byte strings
  /// are not an x on the curve.
  static bool _onCurve(Uint8List compressedKey) {
    try {
      return _secp256k1.curve.decodePoint(compressedKey) != null;
    } catch (_) {
      return false;
    }
  }

  static Uint8List _compressed(int sec1Prefix, Uint8List payload) {
    final key = Uint8List(33);
    key[0] = sec1Prefix;
    key.setRange(1, 33, payload);

    return key;
  }

  static Uint8List? _hex(Object? text) {
    if (text is! String) {
      return null;
    }
    try {
      return hexToBytes(text);
    } catch (_) {
      return null;
    }
  }
}
