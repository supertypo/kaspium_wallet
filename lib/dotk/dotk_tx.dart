import 'dart:convert';

import 'package:blake3_dart/blake3_dart.dart';

import '../kaspa/types.dart';
import '../kaspa/utils.dart';
import 'dotk_names.dart';
import 'dotk_registry.dart';
import 'dotk_script.dart';
import 'dotk_types.dart';

// The protocol seats of the registry transactions, byte for byte as
// @dotk/sdk-tx builds them. Pure: the caller reads every UTXO from the node.

class DotkTxError implements Exception {
  final String message;

  const DotkTxError(this.message);

  @override
  String toString() => 'DotkTxError: $message';
}

/// The compute budgets each input kind declares
abstract class DotkComputeBudget {
  static const transfer = 100;
  static const activate = 100;
  static const split = 150;

  /// A funding input and a card sweep
  static const funding = 20;
}

/// The state regions the covenants keep, one explicit data push per field
abstract class DotkState {
  static const statusPending = 0x01;
  static const statusActive = 0x02;

  static final zero32 = Uint8List(32);

  /// blake3 of the bare name, which partitions the registry keyspace
  static Uint8List keyOf(String bare) => blake3(ascii.encode(bare));

  /// blake3(name ‖ ownerType ‖ owner), which a split publishes and only the
  /// party who chose the owner can reveal
  static Uint8List claimOf(String bare, int ownerType, Uint8List owner) {
    _require32(owner, 'owner');
    return blake3(
      Uint8List.fromList([...ascii.encode(bare), ownerType, ...owner]),
    );
  }

  static Uint8List paddedName(String bare) {
    if (!DotkName.isValid(bare)) {
      throw DotkTxError('$bare is not a valid name');
    }
    return Uint8List(DotkName.maxLength)..setAll(0, ascii.encode(bare));
  }

  static Uint8List activeDeed(String bare, int ownerType, Uint8List owner) =>
      Uint8List.fromList([
        0x01,
        statusActive,
        0x20,
        ...keyOf(bare),
        0x01,
        ownerType,
        0x20,
        ..._require32(owner, 'owner'),
        0x20,
        ...paddedName(bare),
      ]);

  /// The PENDING deed a split writes, with the claim in the owner field
  static Uint8List pendingDeed(Uint8List key, Uint8List claim) =>
      Uint8List.fromList([
        0x01,
        statusPending,
        0x20,
        ..._require32(key, 'key'),
        0x01,
        DotkOwnerType.schnorr,
        0x20,
        ..._require32(claim, 'claim'),
        0x20,
        ...zero32,
      ]);

  static Uint8List gap(Uint8List lo, Uint8List hi) => Uint8List.fromList([
    0x20,
    ..._require32(lo, 'lo'),
    0x20,
    ..._require32(hi, 'hi'),
  ]);

  static Uint8List _require32(Uint8List bytes, String what) {
    if (bytes.length != 32) {
      throw DotkTxError('$what must be 32 bytes, got ${bytes.length}');
    }
    return bytes;
  }
}

abstract class DotkOwner {
  static final _p = BigInt.parse(
    'fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f',
    radix: 16,
  );

  static bool isSpenderType(int ownerType) =>
      ownerType == DotkOwnerType.schnorr ||
      ownerType == DotkOwnerType.ecdsaEvenY ||
      ownerType == DotkOwnerType.ecdsaOddY;

  /// Whether x is the x coordinate of a secp256k1 point
  static bool isOnCurve(Uint8List x) {
    final value = bytesToBigIntUnsigned(x);
    if (value >= _p) {
      return false;
    }
    final ySquared = (value.modPow(.from(3), _p) + .from(7)) % _p;
    return ySquared == .zero || ySquared.modPow((_p - .one) >> 1, _p) == .one;
  }

  /// Refuses an owner the covenant accepts but no one can ever spend, and
  /// the schemes approved by a co-present input, which nothing here builds
  static void validate(int ownerType, Uint8List owner, DotkRegistry registry) {
    if (owner.length != 32) {
      throw DotkTxError('The owner must be 32 bytes, got ${owner.length}');
    }
    if (owner.hex == registry.covenantId) {
      throw const DotkTxError('The owner is the registry covenant id');
    }
    if (owner.every((b) => b == 0)) {
      throw const DotkTxError('The owner is 32 zero bytes');
    }
    if (!isSpenderType(ownerType)) {
      throw DotkTxError('Owner scheme $ownerType is not signed for');
    }
    if (!isOnCurve(owner)) {
      throw const DotkTxError('The owner is not a point on the curve');
    }
  }
}

/// The state a card's redeem script commits to
class DotkCardState {
  static const payloadVersion = 1;

  final Uint8List key;

  /// blake3 of the record blob
  final Uint8List records;
  final int spenderType;
  final Uint8List spender;

  DotkCardState({
    required this.key,
    required this.records,
    required this.spenderType,
    required this.spender,
  }) {
    if (!DotkOwner.isSpenderType(spenderType)) {
      throw DotkTxError('A card spender is a key, not scheme $spenderType');
    }
    if (key.length != 32 || records.length != 32 || spender.length != 32) {
      throw const DotkTxError('Card fields must be 32 bytes');
    }
  }

  DotkCardState.forBlob(
    String bare,
    Uint8List blob, {
    required int spenderType,
    required Uint8List spender,
  }) : this(
         key: DotkState.keyOf(bare),
         records: blake3(blob),
         spenderType: spenderType,
         spender: spender,
       );

  Uint8List encode() =>
      Uint8List.fromList([...key, ...records, spenderType, ...spender]);

  /// `<key> <records> OP_DROP OP_DROP <magic> OP_EQUALVERIFY <spender> OP_CHECKSIG`
  Uint8List redeemScript(Uint8List magic) => Uint8List.fromList([
    0x20, ...key,
    0x20, ...records,
    0x75, 0x75, // OP_DROP OP_DROP
    magic.length, ...magic,
    0x88, // OP_EQUALVERIFY
    if (spenderType == DotkOwnerType.schnorr) ...[
      0x20, ...spender,
      0xac, // OP_CHECKSIG
    ] else ...[
      0x21, 0x02 | (spenderType & 0x01), ...spender,
      0xab, // OP_CHECKSIGECDSA
    ],
  ]);

  ScriptPublicKey scriptPublicKey(Uint8List magic) =>
      scriptHashScriptPublicKey(redeemScript(magic));

  Address address(DotkRegistry registry) =>
      scriptHashAddress(redeemScript(registry.cardMagic), registry.prefix);

  /// The key address that can sweep the card
  Address spenderAddress(AddressPrefix prefix) =>
      spenderType == DotkOwnerType.schnorr
      ? Address.publicKey(prefix: prefix, publicKey: spender)
      : Address.pubKeyECDSA(
          prefix: prefix,
          publicKey: Uint8List.fromList([
            0x02 | (spenderType & 0x01),
            ...spender,
          ]),
        );

  /// `<sig> <magic> <redeem>`, with a 65-byte placeholder for the signature
  Uint8List sweepSigScript(Uint8List magic) => Uint8List.fromList([
    ...DotkScript().addData(Uint8List(DotkScript.sigLength)).bytes(),
    ...DotkScript().addData(magic).bytes(),
    ...DotkScript().addData(redeemScript(magic)).bytes(),
  ]);
}

class DotkCardMint {
  final DotkCardState state;
  final Uint8List blob;

  DotkCardMint(this.state, this.blob) {
    if (blob.length > 16 * 1024) {
      throw const DotkTxError('The record blob is over 16 KiB');
    }
    if (blake3(blob).hex != state.records.hex) {
      throw const DotkTxError('The card state does not commit to its blob');
    }
  }

  /// magic ‖ version ‖ state ‖ blobLen:u16 LE ‖ blob
  Uint8List payload(Uint8List magic) => Uint8List.fromList([
    ...magic,
    DotkCardState.payloadVersion,
    ...state.encode(),
    blob.length & 0xff,
    blob.length >> 8,
    ...blob,
  ]);
}

/// A card the node holds, to be swept back to the wallet
class DotkCardSweep {
  final Utxo utxo;
  final DotkCardState state;

  const DotkCardSweep({required this.utxo, required this.state});
}

/// The cards a transfer carries: a card minted at output 1, and the inputs
/// that sweep older cards back
class DotkCardPlan {
  final DotkCardMint? mint;
  final List<DotkCardSweep> sweep;

  /// Whether the transfer retires a live card it does not sweep
  final bool retires;

  const DotkCardPlan({this.mint, this.sweep = const [], this.retires = false});
}

/// An ACTIVE deed as the node holds it
class DotkDeed {
  final String name;
  final int ownerType;
  final Uint8List owner;
  final Utxo utxo;

  const DotkDeed({
    required this.name,
    required this.ownerType,
    required this.owner,
    required this.utxo,
  });

  Uint8List get state => DotkState.activeDeed(name, ownerType, owner);
}

/// A gap as the node holds it, with the bounds the indexer reported
class DotkGap {
  final Uint8List lo;
  final Uint8List hi;
  final Utxo utxo;

  const DotkGap({required this.lo, required this.hi, required this.utxo});

  Uint8List get state => DotkState.gap(lo, hi);
}

/// A transaction with its protocol seats filled and nothing else
class DotkIntent {
  final RawTransaction base;

  /// What the protocol outputs need beyond what the protocol inputs hold
  final BigInt requiredFunding;

  /// The inputs signed under this package's own scripts, by index, with the
  /// wallet address whose key signs each
  final Map<int, Address> ownerSigInputs;

  /// The owner-signed inputs that are card sweeps
  final List<int> cardInputs;

  const DotkIntent({
    required this.base,
    required this.requiredFunding,
    this.ownerSigInputs = const {},
    this.cardInputs = const [],
  });
}

RawTransaction _emptyTx() => RawTransaction(
  version: 1,
  inputs: const [],
  outputs: const [],
  lockTime: .zero,
  subnetworkId: kSubnetworkIdNative,
  gas: .zero,
);

CovenantBinding _binding(DotkRegistry registry) =>
    CovenantBinding(authorizingInput: 0, covenantId: registry.covenantIdBytes);

/// One entrypoint's arguments, its dispatch tag and the redeem script
Uint8List _entrySigScript(
  void Function(DotkScript script) args,
  Uint8List tag,
  Uint8List redeem,
) {
  final script = DotkScript();
  args(script);
  script.addData(tag);
  script.addData(redeem);
  return script.bytes();
}

void _requireRegistryUtxo(Utxo utxo, DotkRegistry registry, String what) {
  if (utxo.utxoEntry.covenantId?.hex != registry.covenantId) {
    throw DotkTxError("The $what does not carry this registry's covenant id");
  }
}

bool _sameScript(ScriptPublicKey a, ScriptPublicKey b) =>
    a.version == b.version && a.scriptPublicKey.hex == b.scriptPublicKey.hex;

abstract class DotkIntents {
  /// `<newOwnerType> <newOwner> <sigs> <witness> <tag> <redeem>`, with the
  /// 65-byte placeholder for a missing signature
  static Uint8List transferSigScript({
    required DotkRegistry registry,
    required Uint8List state,
    required int newOwnerType,
    required Uint8List newOwner,
    Uint8List? signature,
    bool unsigned = false,
    int witness = 0,
  }) => _entrySigScript(
    (s) => s
      ..addData([newOwnerType])
      ..addData(newOwner)
      ..addData(unsigned ? [] : signature ?? Uint8List(DotkScript.sigLength))
      ..addInt(witness), // names an input for a script-hash owner only
    registry.transferTag,
    registry.deedRedeem(state),
  );

  /// The deed at input 0, its continuation at output 0 pinned to BOND, then
  /// the cards. [ownerAddress] signs the deed, each spender its card sweep.
  static DotkIntent transfer({
    required DotkRegistry registry,
    required DotkDeed deed,
    required Address ownerAddress,
    required int newOwnerType,
    required Uint8List newOwner,
    DotkCardPlan cards = const DotkCardPlan(),
  }) {
    final bond = registry.params.bond;
    if (deed.utxo.utxoEntry.amount != bond) {
      throw DotkTxError(
        'An ACTIVE deed holds exactly $bond sompi, this one holds '
        '${deed.utxo.utxoEntry.amount}',
      );
    }
    _requireRegistryUtxo(deed.utxo, registry, 'deed');

    final sameOwner =
        newOwnerType == deed.ownerType && newOwner.hex == deed.owner.hex;
    if (sameOwner &&
        cards.mint == null &&
        cards.sweep.isEmpty &&
        !cards.retires) {
      throw const DotkTxError(
        'This transfer mints no card and sweeps none, so it does nothing',
      );
    }
    DotkOwner.validate(newOwnerType, newOwner, registry);
    if (!DotkOwner.isSpenderType(deed.ownerType)) {
      throw DotkTxError('A deed under scheme ${deed.ownerType} is not signed');
    }

    final current = deed.state;
    if (!_sameScript(
      deed.utxo.utxoEntry.scriptPublicKey,
      registry.deedScriptPublicKey(current),
    )) {
      throw const DotkTxError('The UTXO does not pay to the deed derived here');
    }
    final next = DotkState.activeDeed(deed.name, newOwnerType, newOwner);

    final sigScript = transferSigScript(
      registry: registry,
      state: current,
      newOwnerType: newOwnerType,
      newOwner: newOwner,
    );

    final inputs = [
      RawInput(
        address: registry.deedAddress(current),
        previousOutpoint: deed.utxo.outpoint,
        signatureScript: sigScript,
        sequence: .zero,
        computeBudget: DotkComputeBudget.transfer,
        utxoEntry: deed.utxo.utxoEntry,
      ),
    ];
    final outputs = [
      RawOutput(
        value: bond,
        scriptPublicKey: registry.deedScriptPublicKey(next),
        covenant: _binding(registry),
      ),
    ];

    final mint = cards.mint;
    if (mint != null && mint.state.key.hex != DotkState.keyOf(deed.name).hex) {
      throw const DotkTxError('A card minted here must be for this name');
    }

    final ownerSigInputs = <int, Address>{0: ownerAddress};
    final cardInputs = <int>[];
    for (final card in cards.sweep) {
      final magic = registry.cardMagic;
      if (!_sameScript(
        card.utxo.utxoEntry.scriptPublicKey,
        card.state.scriptPublicKey(magic),
      )) {
        throw const DotkTxError('The UTXO does not pay to the card swept');
      }
      cardInputs.add(inputs.length);
      ownerSigInputs[inputs.length] = card.state.spenderAddress(
        registry.prefix,
      );
      inputs.add(
        RawInput(
          address: card.state.address(registry),
          previousOutpoint: card.utxo.outpoint,
          signatureScript: card.state.sweepSigScript(magic),
          sequence: .zero,
          computeBudget: DotkComputeBudget.funding,
          utxoEntry: card.utxo.utxoEntry,
        ),
      );
    }
    if (mint != null) {
      outputs.add(
        RawOutput(
          value: registry.params.cardValue,
          scriptPublicKey: mint.state.scriptPublicKey(registry.cardMagic),
        ),
      );
    }

    return DotkIntent(
      base: _emptyTx().copyWith(
        inputs: inputs,
        outputs: outputs,
        payload: mint?.payload(registry.cardMagic),
      ),
      requiredFunding: .zero,
      ownerSigInputs: ownerSigInputs,
      cardInputs: cardInputs,
    );
  }

  /// The commit of a registration: spend the gap covering the key, and write
  /// the two narrower gaps and the PENDING deed
  static DotkIntent split({
    required DotkRegistry registry,
    required DotkGap gap,
    required String name,
    required int ownerType,
    required Uint8List owner,
  }) {
    if (!DotkName.isValid(name)) {
      throw DotkTxError('$name is not a valid name');
    }
    DotkOwner.validate(ownerType, owner, registry);
    final params = registry.params;
    final key = DotkState.keyOf(name);
    final newbornValue = params.bond + params.deposit;

    _requireRegistryUtxo(gap.utxo, registry, 'gap');
    if (gap.utxo.utxoEntry.amount != params.gapValue) {
      throw DotkTxError(
        'A gap holds ${params.gapValue} sompi, this one holds '
        '${gap.utxo.utxoEntry.amount}',
      );
    }
    // Strictly inside: a key equal to a bound is already registered
    final keyHex = key.hex;
    if (gap.lo.hex.compareTo(keyHex) >= 0 ||
        keyHex.compareTo(gap.hi.hex) >= 0) {
      throw DotkTxError('$name does not fall strictly inside the gap');
    }
    final state = gap.state;
    if (!_sameScript(
      gap.utxo.utxoEntry.scriptPublicKey,
      registry.gapScriptPublicKey(state),
    )) {
      throw const DotkTxError('The UTXO does not pay to the gap derived here');
    }

    final claim = DotkState.claimOf(name, ownerType, owner);
    final sigScript = _entrySigScript(
      (s) => s
        ..addData(key)
        ..addData(claim)
        ..addData(registry.deedPrefix)
        ..addData(registry.deedSuffix),
      registry.splitTag,
      registry.gapRedeem(state),
    );

    final binding = _binding(registry);
    return DotkIntent(
      base: _emptyTx().copyWith(
        inputs: [
          RawInput(
            address: registry.gapAddress(state),
            previousOutpoint: gap.utxo.outpoint,
            signatureScript: sigScript,
            sequence: .zero,
            computeBudget: DotkComputeBudget.split,
            utxoEntry: gap.utxo.utxoEntry,
          ),
        ],
        outputs: [
          RawOutput(
            value: params.gapValue,
            scriptPublicKey: registry.gapScriptPublicKey(
              DotkState.gap(gap.lo, key),
            ),
            covenant: binding,
          ),
          RawOutput(
            value: params.gapValue,
            scriptPublicKey: registry.gapScriptPublicKey(
              DotkState.gap(key, gap.hi),
            ),
            covenant: binding,
          ),
          RawOutput(
            value: newbornValue,
            scriptPublicKey: registry.deedScriptPublicKey(
              DotkState.pendingDeed(key, claim),
            ),
            covenant: binding,
          ),
        ],
      ),
      requiredFunding:
          newbornValue + params.gapValue * .two - gap.utxo.utxoEntry.amount,
    );
  }

  /// The PENDING deed's output index in a split
  static const splitPendingIndex = 2;

  /// The reveal of a PENDING deed. Knowing the claim's preimage is its whole
  /// authorization, so nothing here is signed.
  static DotkIntent activate({
    required DotkRegistry registry,
    required Utxo pending,
    required String name,
    required int ownerType,
    required Uint8List owner,
  }) {
    if (!DotkName.isValid(name)) {
      throw DotkTxError('$name is not a valid name');
    }
    DotkOwner.validate(ownerType, owner, registry);
    final params = registry.params;
    final fee = params.feeForName(name);

    _requireRegistryUtxo(pending, registry, 'PENDING deed');
    if (pending.utxoEntry.amount != params.bond + params.deposit) {
      throw DotkTxError(
        'A PENDING deed holds exactly ${params.bond + params.deposit} sompi, '
        'this one holds ${pending.utxoEntry.amount}',
      );
    }
    final current = DotkState.pendingDeed(
      DotkState.keyOf(name),
      DotkState.claimOf(name, ownerType, owner),
    );
    if (!_sameScript(
      pending.utxoEntry.scriptPublicKey,
      registry.deedScriptPublicKey(current),
    )) {
      throw const DotkTxError(
        'The UTXO does not pay to the PENDING deed this name and owner claim',
      );
    }

    final sigScript = _entrySigScript(
      (s) => s
        ..addData(ascii.encode(name))
        ..addData([ownerType])
        ..addData(owner),
      registry.activateTag,
      registry.deedRedeem(current),
    );

    final outputs = params.bond + fee;
    final amount = pending.utxoEntry.amount;
    return DotkIntent(
      base: _emptyTx().copyWith(
        inputs: [
          RawInput(
            address: registry.deedAddress(current),
            previousOutpoint: pending.outpoint,
            signatureScript: sigScript,
            sequence: .zero,
            computeBudget: DotkComputeBudget.activate,
            utxoEntry: pending.utxoEntry,
          ),
        ],
        outputs: [
          RawOutput(
            value: params.bond,
            scriptPublicKey: registry.deedScriptPublicKey(
              DotkState.activeDeed(name, ownerType, owner),
            ),
            covenant: _binding(registry),
          ),
          RawOutput(
            value: fee,
            scriptPublicKey: ScriptPublicKey(
              scriptPublicKey: registry.devfundScriptPublicKey,
              version: 0,
            ),
          ),
        ],
      ),
      requiredFunding: outputs > amount ? outputs - amount : .zero,
    );
  }
}
