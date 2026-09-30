import 'dart:convert';

import '../kaspa/network.dart';
import '../kaspa/transaction/txscript.dart';
import '../kaspa/types.dart';
import '../kaspa/utils.dart';

part 'dotk_registry_data.dart';

/// The registry's economic constants, in sompi, as the covenants were
/// compiled with them.
class DotkParams {
  final BigInt fee1ch;
  final BigInt fee2ch;
  final BigInt fee3ch;
  final BigInt fee4ch;
  final BigInt fee5plus;
  final BigInt bond;
  final BigInt deposit;
  final BigInt gapValue;
  final BigInt cardValue;

  /// How long a PENDING deed is protected before anyone can evict it, in DAA
  final int tEvict;

  DotkParams._(_DotkDeployment d)
    : fee1ch = .from(d.fee1ch),
      fee2ch = .from(d.fee2ch),
      fee3ch = .from(d.fee3ch),
      fee4ch = .from(d.fee4ch),
      fee5plus = .from(d.fee5plus),
      bond = .from(d.bond),
      deposit = .from(d.deposit),
      gapValue = .from(d.gapValue),
      cardValue = .from(d.cardValue),
      tEvict = d.tEvict;

  /// The registration fee for a bare name, by its length in bytes
  BigInt feeForName(String bare) => switch (utf8.encode(bare).length) {
    <= 1 => fee1ch,
    2 => fee2ch,
    3 => fee3ch,
    4 => fee4ch,
    _ => fee5plus,
  };
}

class DotkRegistry {
  static const _deedStateOffset = 1;
  static const _deedStateLength = 103;

  final String network;
  final AddressPrefix prefix;

  /// The dotk.name site for this network, without a trailing slash
  final String siteUrl;

  final String covenantId;
  final Uint8List deedBytecode;
  final Uint8List gapBytecode;
  final int gapStateOffset;
  final int gapStateLength;

  /// Dispatch tags as the deployment manifest freezes them
  final Uint8List splitTag;
  final Uint8List activateTag;
  final Uint8List transferTag;

  /// Where activation pays the registration fee
  final Uint8List devfundScriptPublicKey;

  final DotkParams params;

  /// The four bytes a card sweep pushes and a card payload opens with
  final Uint8List cardMagic;

  DotkRegistry._(_DotkDeployment d)
    : network = d.network,
      prefix = d.prefix,
      siteUrl = d.siteUrl,
      covenantId = d.covenantId,
      deedBytecode = hexToBytes(d.deedBytecode),
      gapBytecode = hexToBytes(d.gapBytecode),
      gapStateOffset = d.gapStateOffset,
      gapStateLength = d.gapStateLength,
      splitTag = hexToBytes(d.splitTag),
      activateTag = hexToBytes(d.activateTag),
      transferTag = hexToBytes(d.transferTag),
      devfundScriptPublicKey = hexToBytes(d.devfundScriptPublicKey),
      params = DotkParams._(d),
      cardMagic = ascii.encode(d.cardMagic);

  static final mainnet = DotkRegistry._(_mainnet);

  static final testnet10 = DotkRegistry._(_testnet10);

  static DotkRegistry? forNetworkId(String networkId) => switch (networkId) {
    kKaspaNetworkIdMainnet => mainnet,
    kKaspaNetworkIdTestnet10 => testnet10,
    _ => null,
  };

  Uint8List get covenantIdBytes => hexToBytes(covenantId);

  /// The deed bytes before its state, which a split hands the gap covenant
  Uint8List get deedPrefix =>
      Uint8List.sublistView(deedBytecode, 0, _deedStateOffset);

  /// The deed bytes after its state
  Uint8List get deedSuffix =>
      Uint8List.sublistView(deedBytecode, _deedStateOffset + _deedStateLength);

  Uint8List deedRedeem(Uint8List state) =>
      _redeem(deedBytecode, _deedStateOffset, _deedStateLength, state);

  Uint8List gapRedeem(Uint8List state) =>
      _redeem(gapBytecode, gapStateOffset, gapStateLength, state);

  ScriptPublicKey deedScriptPublicKey(Uint8List state) =>
      scriptHashScriptPublicKey(deedRedeem(state));

  ScriptPublicKey gapScriptPublicKey(Uint8List state) =>
      scriptHashScriptPublicKey(gapRedeem(state));

  Address deedAddress(Uint8List state) =>
      scriptHashAddress(deedRedeem(state), prefix);

  Address gapAddress(Uint8List state) =>
      scriptHashAddress(gapRedeem(state), prefix);

  static Uint8List _redeem(
    Uint8List bytecode,
    int offset,
    int length,
    Uint8List state,
  ) {
    if (state.length != length) {
      throw ArgumentError('State must be $length bytes, got ${state.length}');
    }
    return Uint8List.fromList(bytecode)..setAll(offset, state);
  }
}

/// The P2SH locking script of a redeem script: `OP_BLAKE2B <hash> OP_EQUAL`
ScriptPublicKey scriptHashScriptPublicKey(Uint8List redeem) => ScriptPublicKey(
  scriptPublicKey: payToScriptHashScript(blake2bDigest(data: redeem)),
  version: kAddressScriptHashScriptPublicKeyVersion,
);

Address scriptHashAddress(Uint8List redeem, AddressPrefix prefix) =>
    Address.scriptHash(
      prefix: prefix,
      hash: blake2bDigest(data: redeem),
    );

class _DotkDeployment {
  final String network;
  final AddressPrefix prefix;
  final String siteUrl;
  final String covenantId;
  final String deedTemplateHash;
  final String gapTemplateHash;
  final int gapStateOffset;
  final int gapStateLength;
  final String splitTag;
  final String activateTag;
  final String transferTag;
  final String devfundScriptPublicKey;
  final int fee1ch;
  final int fee2ch;
  final int fee3ch;
  final int fee4ch;
  final int fee5plus;
  final int bond;
  final int deposit;
  final int gapValue;
  final int cardValue;
  final int tEvict;
  final String cardMagic;
  final String deedBytecode;
  final String gapBytecode;

  const _DotkDeployment({
    required this.network,
    required this.prefix,
    required this.siteUrl,
    required this.covenantId,
    required this.deedTemplateHash,
    required this.gapTemplateHash,
    required this.gapStateOffset,
    required this.gapStateLength,
    required this.splitTag,
    required this.activateTag,
    required this.transferTag,
    required this.devfundScriptPublicKey,
    required this.fee1ch,
    required this.fee2ch,
    required this.fee3ch,
    required this.fee4ch,
    required this.fee5plus,
    required this.bond,
    required this.deposit,
    required this.gapValue,
    required this.cardValue,
    required this.tEvict,
    required this.cardMagic,
    required this.deedBytecode,
    required this.gapBytecode,
  });
}
