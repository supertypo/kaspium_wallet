import '../kaspa/transaction.dart';
import '../kaspa/types.dart';
import '../kaspa/utils.dart';
import 'dotk_registry.dart';
import 'dotk_script.dart';
import 'dotk_tx.dart';

// Funding, change, fee and signatures on top of the protocol seats, as
// @dotk/sdk-tx assembles them. Funding and change always follow the seats.

class DotkInsufficientFundsError extends DotkTxError {
  final BigInt available;
  final BigInt needed;

  DotkInsufficientFundsError(this.available, this.needed)
    : super('Insufficient funds: $available sompi of $needed');
}

/// Change too small to pay for its own storage mass at the feerate, which
/// another coin remedies
class DotkChangeTooSmallError extends DotkInsufficientFundsError {
  DotkChangeTooSmallError() : super(.zero, .one);

  @override
  String get message =>
      'At this feerate the change cannot pay for its own storage mass';
}

class DotkFeeCeilingError extends DotkTxError {
  final BigInt fee;

  DotkFeeCeilingError(this.fee)
    : super('The fee $fee is over the ${DotkFees.maxFee} sompi ceiling');
}

class DotkMassError extends DotkTxError {
  const DotkMassError(super.message);
}

/// Signs a sighash with the key of a wallet address: 64 bytes of Schnorr
typedef DotkSign = Future<Uint8List> Function(Uint8List hash, Address address);

abstract class DotkFees {
  /// The most any registry transaction is built to pay, 5 KAS
  static final maxFee = BigInt.from(500_000_000);

  /// Change below this goes to the fee rather than into its own output
  static final dust = BigInt.from(2_000_000);

  /// The most change the storage fold turns into fee
  static final foldCeiling = dust * .two;

  static final minimumRelayFeePerKg = BigInt.from(100_000);

  static final computeLimit = BigInt.from(500_000);
  static final storageLimit = BigInt.from(500_000);
  static final transientLimit = BigInt.from(1_000_000);

  /// A funding signature script: one push of a 65-byte signature
  static const fundingSigScriptLength = 66;

  /// The most a transaction pays above its own requirement: change folded
  /// into the fee, with the price of the change output it removed
  static final overpayCeiling = foldCeiling * .two;

  static const _feePasses = 64;

  static final _massCalculator = MassCalculator.defaultCalculator;

  static TxMassesV1 massesOf(RawTransaction tx) =>
      _massCalculator.calcTxMassesV1(tx);

  /// KIP-9 storage mass, or null where the formula cannot price a side
  static BigInt? storageMassOf(RawTransaction tx) {
    if (tx.outputs.any((o) => o.value <= .zero) ||
        tx.inputs.any((i) => i.utxoEntry.amount <= .zero)) {
      return null;
    }
    return _massCalculator.calcTxStorageMass(tx: tx);
  }

  /// The relay minimum for a mass. The per-kilogram rate stands in where the
  /// division rounds the fee away entirely.
  static BigInt relayMinimumFee(BigInt feeMass) {
    final fee = feeMass * minimumRelayFeePerKg ~/ .from(1000);
    return fee == .zero ? minimumRelayFeePerKg : fee;
  }

  /// Headroom a registration takes beyond its buffer while blocks are full,
  /// so the split's change still pays for the activation
  static BigInt fullBlockHeadroom(double feerate, BigInt? readyMass) {
    if (readyMass == null || readyMass <= computeLimit) {
      return .zero;
    }
    if (!feerate.isFinite || feerate <= 0) {
      return .zero;
    }
    final headroom = BigInt.from((feerate * 150000).ceil());
    return headroom < maxFee ? headroom : maxFee;
  }

  /// The mass the mempool ranks a transaction by, storage mass included
  static BigInt? frontierMass(RawTransaction tx) {
    final storage = storageMassOf(tx);
    if (storage == null) {
      return null;
    }
    final fee = massesOf(tx).fee;
    return storage > fee ? storage : fee;
  }

  /// What a transaction must pay: [floors] times the relay minimum, or
  /// [feerate] on a mass where that is more. Within one block of
  /// [readyMass] the node takes every transaction, so the floor is the fee.
  /// Past one block the mass is the [frontierMass], and without a
  /// [readyMass] it is the fee mass.
  static BigInt requiredFee(
    RawTransaction tx,
    double feerate, {
    BigInt? readyMass,
    int floors = 1,
  }) {
    final feeMass = massesOf(tx).fee;
    final floor = relayMinimumFee(feeMass) * BigInt.from(floors);
    final rate = feerate.isFinite && feerate > 0 ? feerate : 0.0;
    if (rate == 0 || (readyMass != null && readyMass <= computeLimit)) {
      return floor;
    }
    final mass = readyMass == null ? feeMass : frontierMass(tx) ?? feeMass;
    final product = mass.toDouble() * rate;
    // An absurd feerate prices past any ceiling rather than failing to round
    final over = maxFee * .two;
    final market = product.isFinite && product < over.toDouble()
        ? BigInt.from(product.ceil())
        : over;
    return market > floor ? market : floor;
  }

  /// Which limit the transaction exceeds, if any
  static String? massOverrun(RawTransaction tx) {
    final storage = storageMassOf(tx);
    if (storage == null) {
      return 'storage';
    }
    final masses = massesOf(tx);
    if (masses.compute > computeLimit) {
      return 'compute';
    }
    if (masses.transient > transientLimit) {
      return 'transient';
    }
    if (storage > storageLimit) {
      return 'storage';
    }
    return null;
  }

  /// The transaction as it will be once signed: each unsigned funding input
  /// carries a placeholder of its signature's final length
  static RawTransaction measuredClone(
    RawTransaction tx,
    List<int> fundingInputs,
  ) {
    final funding = fundingInputs.toSet();
    return tx.copyWith(
      inputs: [
        for (final (at, input) in tx.inputs.indexed)
          funding.contains(at)
              ? input.copyWith(
                  signatureScript: Uint8List(fundingSigScriptLength),
                )
              : input,
      ],
    );
  }
}

class DotkAssembled {
  final RawTransaction tx;

  /// What the miner keeps, which is what leaves the wallet beyond outputs
  final BigInt fee;

  /// The masses the fee was measured on, with funding signatures in place
  final TxMassesV1 masses;
  final List<int> fundingInputs;

  /// The inputs signed under the protocol's own scripts
  final Map<int, Address> ownerSigInputs;

  /// The change output's index, or -1 when the remainder went to the fee
  final int changeIndex;

  const DotkAssembled({
    required this.tx,
    required this.fee,
    required this.masses,
    required this.fundingInputs,
    required this.ownerSigInputs,
    required this.changeIndex,
  });

  BigInt? get change => changeIndex < 0 ? null : tx.outputs[changeIndex].value;

  /// The transaction id, which signatures do not change
  String get id => transactionIdV1(tx);
}

RawInput _fundingInput(Utxo utxo) => RawInput(
  address: Address.decodeAddress(utxo.address),
  previousOutpoint: utxo.outpoint,
  signatureScript: Uint8List(0),
  sequence: .zero,
  computeBudget: DotkComputeBudget.funding,
  utxoEntry: utxo.utxoEntry,
);

abstract class DotkAssembler {
  /// Largest first until the picks cover the target
  static List<Utxo> selectFunding(List<Utxo> utxos, BigInt needed) {
    final sorted = utxos.indexed.toList()
      ..sort((a, b) {
        final byAmount = b.$2.utxoEntry.amount.compareTo(a.$2.utxoEntry.amount);
        return byAmount != 0 ? byAmount : a.$1.compareTo(b.$1);
      });
    final picked = <Utxo>[];
    BigInt total = .zero;
    for (final (_, utxo) in sorted) {
      if (total >= needed) {
        break;
      }
      picked.add(utxo);
      total += utxo.utxoEntry.amount;
    }
    if (total < needed) {
      throw DotkInsufficientFundsError(total, needed);
    }
    return picked;
  }

  static DotkAssembled build(
    DotkIntent intent,
    List<Utxo> picked, {
    required ScriptPublicKey changeScript,
    required BigInt fee,
  }) {
    if (fee > DotkFees.maxFee) {
      throw DotkFeeCeilingError(fee);
    }
    final base = intent.base;
    final fundingInputs = [
      for (var i = 0; i < picked.length; i++) base.inputs.length + i,
    ];
    var tx = base.copyWith(
      inputs: [...base.inputs, ...picked.map(_fundingInput)],
    );

    final totalIn = tx.inputs.fold<BigInt>(
      .zero,
      (t, i) => t + i.utxoEntry.amount,
    );
    final totalOut = tx.outputs.fold<BigInt>(.zero, (t, o) => t + o.value);
    if (totalIn < totalOut + fee) {
      throw DotkInsufficientFundsError(totalIn, totalOut + fee);
    }

    final change = totalIn - totalOut - fee;
    var paid = change < DotkFees.dust ? totalIn - totalOut : fee;
    var changeIndex = -1;
    if (change >= DotkFees.dust) {
      final withChange = tx.copyWith(
        outputs: [
          ...tx.outputs,
          RawOutput(value: change, scriptPublicKey: changeScript),
        ],
      );
      tx = withChange;
      changeIndex = tx.outputs.length - 1;
      // Change that overruns the storage cap beside small outputs goes to the
      // fee too, up to the fold ceiling
      final overrun = DotkFees.massOverrun(
        DotkFees.measuredClone(tx, fundingInputs),
      );
      if (overrun == 'storage' && change <= DotkFees.foldCeiling) {
        final without = tx.copyWith(
          outputs: tx.outputs.sublist(0, tx.outputs.length - 1),
        );
        final stillOver = DotkFees.massOverrun(
          DotkFees.measuredClone(without, fundingInputs),
        );
        if (stillOver != 'storage') {
          tx = without;
          changeIndex = -1;
          paid = totalIn - totalOut;
        }
      }
    }
    if (paid > DotkFees.maxFee) {
      throw DotkFeeCeilingError(paid);
    }

    // Signature scripts are outside the sighash, so a change output no input
    // signs could be rewritten by anyone
    if (changeIndex >= 0 &&
        fundingInputs.isEmpty &&
        intent.cardInputs.isEmpty) {
      throw const DotkTxError('Refusing a change output that no input signs');
    }

    return DotkAssembled(
      tx: tx,
      fee: paid,
      masses: DotkFees.massesOf(DotkFees.measuredClone(tx, fundingInputs)),
      fundingInputs: fundingInputs,
      ownerSigInputs: intent.ownerSigInputs,
      changeIndex: changeIndex,
    );
  }

  /// Assembles at [feerate] sompi per gram. Iterates because fee, change and
  /// mass decide each other, and keeps the cheapest pass that pays what its
  /// own shape requires.
  static DotkAssembled assemble(
    DotkIntent intent, {
    required List<Utxo> funding,
    required ScriptPublicKey changeScript,
    required double feerate,
    BigInt? readyMass,
    int floors = 1,
    BigInt? requiredFunding,
  }) {
    final base = intent.base;
    final protocolIn = base.inputs.fold<BigInt>(
      .zero,
      (t, i) => t + i.utxoEntry.amount,
    );
    final protocolOut = base.outputs.fold<BigInt>(.zero, (t, o) => t + o.value);
    final shortfall = protocolOut > protocolIn
        ? protocolOut - protocolIn
        : BigInt.zero;
    final required = requiredFunding ?? intent.requiredFunding;
    final target = shortfall > required ? shortfall : required;

    for (final at in intent.cardInputs) {
      if (!DotkScript.hasPlaceholder(base.inputs[at].signatureScript)) {
        throw DotkTxError('Input $at carries no signature placeholder');
      }
    }

    // What this shape costs with one funding input, which selection cannot
    // go below
    final stand =
        funding.firstOrNull ??
        Utxo(
          address: '',
          outpoint: Outpoint(transactionId: '00' * 32, index: 0),
          utxoEntry: UtxoEntry(
            amount: .zero,
            scriptPublicKey: changeScript,
            blockDaaScore: .zero,
            isCoinbase: false,
          ),
        );
    final probe = base.copyWith(
      inputs: [
        ...base.inputs,
        RawInput(
          address: Address.publicKey(prefix: .kaspa, publicKey: Uint8List(32)),
          previousOutpoint: stand.outpoint,
          signatureScript: Uint8List(0),
          sequence: .zero,
          computeBudget: DotkComputeBudget.funding,
          utxoEntry: stand.utxoEntry,
        ),
      ],
    );
    final seed = DotkFees.requiredFee(
      DotkFees.measuredClone(probe, [base.inputs.length]),
      feerate,
      readyMass: readyMass,
      floors: floors,
    );
    if (seed > DotkFees.maxFee) {
      throw DotkFeeCeilingError(seed);
    }

    // The value the seats free beyond what they post pays before the wallet
    // does. Where the wallet owes nothing, one coin still signs the change.
    final surplus = protocolIn > protocolOut
        ? protocolIn - protocolOut
        : BigInt.zero;
    Utxo? largest;
    for (final utxo in funding) {
      if (largest == null || utxo.utxoEntry.amount > largest.utxoEntry.amount) {
        largest = utxo;
      }
    }
    List<Utxo> select(BigInt fee) {
      final owed = target + fee - surplus;
      if (owed > .zero) {
        return selectFunding(funding, owed);
      }
      if (largest != null) {
        return [largest];
      }
      if (intent.cardInputs.isNotEmpty) {
        return const [];
      }
      throw DotkInsufficientFundsError(.zero, .one);
    }

    var fee = BigInt.zero;
    var selection = select(seed);
    DotkAssembled? cheapest;
    BigInt? remainder;
    var folded = false;
    DotkTxError? failure;
    var failedAt = BigInt.zero;
    BigInt? leastNext;
    // Selection follows the highest fee a built pass asked for, so a coin
    // that joined stays while the fee settles on the larger set
    var highest = BigInt.zero;
    final tried = <BigInt>{};
    for (var pass = 0; pass < DotkFees._feePasses && tried.add(fee); pass++) {
      final DotkAssembled assembled;
      try {
        if (pass > 0) {
          selection = select(fee > highest ? fee : highest);
        }
        assembled = build(
          intent,
          selection,
          changeScript: changeScript,
          fee: fee,
        );
      } on DotkTxError catch (e) {
        if (e is! DotkInsufficientFundsError && e is! DotkFeeCeilingError) {
          rethrow;
        }
        failure = e;
        failedAt = fee;
        // The one pass that can still cover: all of the change in the fee
        final all = remainder;
        if (all != null && !folded && all < fee) {
          folded = true;
          fee = all;
          continue;
        }
        break;
      }
      if (fee > highest) {
        highest = fee;
      }
      remainder = assembled.fee + (assembled.change ?? BigInt.zero);
      final next = DotkFees.requiredFee(
        DotkFees.measuredClone(assembled.tx, assembled.fundingInputs),
        feerate,
        readyMass: readyMass,
        floors: floors,
      );
      if (leastNext == null || next < leastNext) {
        leastNext = next;
      }
      if (assembled.fee >= next &&
          assembled.fee - next <= DotkFees.overpayCeiling &&
          (cheapest == null || assembled.fee < cheapest.fee)) {
        cheapest = assembled;
      }
      if (fee == next) {
        break;
      }
      fee = next;
    }
    if (cheapest == null) {
      // Where every built pass needs more than the ceiling, no funds and no fold
      // can help
      if (leastNext != null && leastNext > DotkFees.maxFee) {
        throw DotkFeeCeilingError(leastNext);
      }
      // A climb past every requirement a built pass had means the change failed
      final runaway =
          leastNext != null && failedAt > leastNext + DotkFees.overpayCeiling;
      if (failure != null && !runaway) {
        throw failure;
      }
      throw DotkChangeTooSmallError();
    }
    final overrun = DotkFees.massOverrun(
      DotkFees.measuredClone(cheapest.tx, cheapest.fundingInputs),
    );
    if (overrun != null) {
      throw DotkMassError('The transaction is over the $overrun mass cap');
    }
    return cheapest;
  }
}

abstract class DotkSigner {
  /// Signs every owner seat over its placeholder and every funding input as
  /// a single push, both with SIGHASH_ALL
  static Future<RawTransaction> sign(
    DotkAssembled assembled,
    DotkSign sign,
  ) async {
    final tx = assembled.tx;
    final reusedValues = SigHashReusedValues();
    final funding = assembled.fundingInputs.toSet();

    final inputs = <RawInput>[];
    for (final (at, input) in tx.inputs.indexed) {
      final signer = assembled.ownerSigInputs[at];
      if (signer == null && !funding.contains(at)) {
        inputs.add(input);
        continue;
      }

      final hash = getSchnorrSignatureHash(
        tx: tx,
        inputIndex: at,
        hashType: .sigHashAll,
        reusedValues: reusedValues,
      );
      final address = signer ?? input.address;
      final key = address.maybeWhen(
        publicKey: (_, key) => key,
        orElse: () => null,
      );
      if (key == null) {
        throw DotkTxError('Input $at is not signed by a Schnorr key');
      }
      final signature = await sign(hash, address);
      if (signature.length != 64) {
        throw DotkTxError('The wallet returned a ${signature.length}-byte sig');
      }
      final valid = verifySchnorr(
        publicKey: key.hex,
        hash: hash.hex,
        signature: signature.hex,
      );
      if (!valid) {
        throw DotkTxError('The signature for input $at does not verify');
      }
      final withType = Uint8List.fromList([...signature, kSigHashAll]);

      inputs.add(
        input.copyWith(
          signatureScript: signer != null
              ? DotkScript.patchSignature(input.signatureScript, withType)
              : Uint8List.fromList([withType.length, ...withType]),
        ),
      );
    }

    return tx.copyWith(inputs: inputs);
  }
}

/// Both halves of a registration, the activation standing on the split's
/// change output
class DotkRegistrationBuild {
  final DotkAssembled split;
  final DotkAssembled activate;

  /// The registration fee the activation pays the devfund
  final BigInt tier;

  /// The split's change output, which the activation spends
  final Utxo splitChange;

  /// The PENDING deed the split writes
  final Utxo pending;

  const DotkRegistrationBuild({
    required this.split,
    required this.activate,
    required this.tier,
    required this.splitChange,
    required this.pending,
  });

  BigInt get networkFee => split.fee + activate.fee;
}

abstract class DotkRegistration {
  /// Headroom over the exact posting, so the split's change clears the
  /// activation's own floor
  static final defaultBuffer = BigInt.from(20_000_000);

  /// Builds and measures both halves before either is signed. A funding
  /// amount can leave the split relayable and the activation over a mass
  /// limit, which shows only once the second stands on the first's change.
  static DotkRegistrationBuild build({
    required DotkRegistry registry,
    required DotkGap gap,
    required String name,
    required int ownerType,
    required Uint8List owner,
    required List<Utxo> funding,
    required Address changeAddress,
    required double feerate,
    BigInt? readyMass,
    BigInt? buffer,
  }) {
    final split = DotkIntents.split(
      registry: registry,
      gap: gap,
      name: name,
      ownerType: ownerType,
      owner: owner,
    );
    final params = registry.params;
    final tier = params.feeForName(name);
    final target =
        split.requiredFunding +
        (tier > params.deposit ? tier - params.deposit : BigInt.zero) +
        (buffer ?? defaultBuffer) +
        DotkFees.fullBlockHeadroom(feerate, readyMass);
    final changeScript = payToAddressScript(changeAddress);
    final commit = DotkAssembler.assemble(
      split,
      funding: funding,
      changeScript: changeScript,
      feerate: feerate,
      readyMass: readyMass,
      requiredFunding: target,
    );
    if (commit.changeIndex < 0) {
      throw const DotkTxError('The split leaves no change to fund activation');
    }

    final txId = commit.id;
    final pendingOutput = commit.tx.outputs[DotkIntents.splitPendingIndex];
    final pending = Utxo(
      address: registry
          .deedAddress(
            DotkState.pendingDeed(
              DotkState.keyOf(name),
              DotkState.claimOf(name, ownerType, owner),
            ),
          )
          .encoded,
      outpoint: Outpoint(
        transactionId: txId,
        index: DotkIntents.splitPendingIndex,
      ),
      utxoEntry: UtxoEntry(
        amount: pendingOutput.value,
        scriptPublicKey: pendingOutput.scriptPublicKey,
        blockDaaScore: .zero,
        isCoinbase: false,
        covenantId: registry.covenantIdBytes,
      ),
    );
    final splitChange = Utxo(
      address: changeAddress.encoded,
      outpoint: Outpoint(transactionId: txId, index: commit.changeIndex),
      utxoEntry: UtxoEntry(
        amount: commit.tx.outputs[commit.changeIndex].value,
        scriptPublicKey: changeScript,
        blockDaaScore: .zero,
        isCoinbase: false,
      ),
    );

    final DotkAssembled reveal;
    try {
      reveal = activate(
        registry: registry,
        pending: pending,
        name: name,
        ownerType: ownerType,
        owner: owner,
        funding: [splitChange],
        changeAddress: changeAddress,
        feerate: feerate,
        readyMass: readyMass,
      );
    } on DotkInsufficientFundsError {
      // The split's change is fixed by its target, so more wallet funds do
      // not help
      throw const DotkTxError('The split change cannot fund the activation');
    }

    return DotkRegistrationBuild(
      split: commit,
      activate: reveal,
      tier: tier,
      splitChange: splitChange,
      pending: pending,
    );
  }

  /// The activation alone, for a PENDING deed the node holds. [floors] is
  /// the multiple of the relay minimum it pays at least.
  static DotkAssembled activate({
    required DotkRegistry registry,
    required Utxo pending,
    required String name,
    required int ownerType,
    required Uint8List owner,
    required List<Utxo> funding,
    required Address changeAddress,
    required double feerate,
    BigInt? readyMass,
    int floors = 1,
  }) => DotkAssembler.assemble(
    DotkIntents.activate(
      registry: registry,
      pending: pending,
      name: name,
      ownerType: ownerType,
      owner: owner,
    ),
    funding: funding,
    changeScript: payToAddressScript(changeAddress),
    feerate: feerate,
    readyMass: readyMass,
    floors: floors,
  );
}
