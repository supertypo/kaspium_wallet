import '../kaspa/kaspa.dart';
import 'dotk_names.dart';
import 'dotk_proof.dart';
import 'dotk_record_edits.dart';
import 'dotk_registry.dart';
import 'dotk_service.dart';
import 'dotk_tx.dart';
import 'dotk_tx_assemble.dart';
import 'dotk_types.dart';

/// A watch-only wallet can see names but holds no key to move them
class DotkWatchOnlyError extends DotkTxError {
  const DotkWatchOnlyError()
    : super('A watch-only wallet cannot sign .k name transactions');
}

/// The most card outputs a transfer sweeps
const kMaxCardSweeps = 16;

/// What the indexer lists for a name: its owner's address and card, read
/// after the DAA score the indexer has reached
typedef DotkListing = ({
  String? address,
  DotkCard? card,
  BigInt? indexedDaaScore,
});

/// [dotk]'s listing of [name]. The score counts only for an indexer of
/// [registry] that knows the name.
Future<DotkListing> dotkListingOf(
  DotkService dotk,
  DotkRegistry registry,
  String name,
) async {
  // The score first, so the listing is no older than it
  final indexed = await dotk.indexed();
  final claim = await dotk.claimName(name, fresh: true);
  final trusted =
      claim != null &&
      indexed.registryCovenantId == registry.covenantId &&
      claim.registryCovenantId == registry.covenantId;
  return (
    address: claim?.address,
    card: claim?.card,
    indexedDaaScore: trusted ? indexed.daaScore : null,
  );
}

/// The name changed moments ago and its card may not be listed yet
class DotkSettlingError extends DotkTxError {
  const DotkSettlingError(super.message);
}

/// The node no longer holds what the plan was built on
class DotkStaleError extends DotkTxError {
  const DotkStaleError(super.message);
}

/// The network fee rose past what the user approved
class DotkFeeRoseError extends DotkTxError {
  const DotkFeeRoseError(super.message);
}

/// What changes to the name's card in a transfer
enum DotkCardChange {
  /// No card before and none after
  none,

  /// A new card is minted with the records, for an owner in this wallet
  kept,

  /// The records are cleared: the old card is retired and none is minted
  cleared,
}

/// A transfer, set primary or unset primary, measured against the node
class DotkTransferPlan {
  final String name;
  final Address from;
  final Address to;
  final DotkCardChange cardChange;

  /// The card the indexer listed, which the plan sweeps and, for an owner in
  /// this wallet, carries over
  final DotkCard? card;

  /// The blob a minted card carries
  final Uint8List? mintBlob;

  /// How many cards the wallet sweeps back
  final int swept;

  final DotkAssembled assembled;

  const DotkTransferPlan({
    required this.name,
    required this.from,
    required this.to,
    required this.cardChange,
    required this.card,
    required this.mintBlob,
    required this.swept,
    required this.assembled,
  });

  bool get isSameOwner => from.encoded == to.encoded;

  /// Whether a transfer drops records besides the primary flag, which the
  /// records list does not show
  bool get clearsRecords {
    final card = this.card;
    if (cardChange != .cleared || card == null) return false;
    try {
      return DotkRecordEdits.count(DotkRecordEdits.withoutPrimary(card.blob)) >
          0;
    } on FormatException {
      return true;
    }
  }

  BigInt get fee => assembled.fee;

  /// What a minted card holds beyond the cards it sweeps, which leaves the
  /// spendable balance until a later transfer sweeps the card. Negative where
  /// the sweep returns more than the mint holds.
  BigInt get cardHeld {
    final tx = assembled.tx;
    final minted = mintBlob == null ? BigInt.zero : tx.outputs[1].value;
    final swept = assembled.ownerSigInputs.keys
        .where((at) => at != 0)
        .fold<BigInt>(.zero, (t, at) => t + tx.inputs[at].utxoEntry.amount);
    return minted - swept;
  }

  Outpoint get deedOutpoint => assembled.tx.inputs.first.previousOutpoint;
}

/// A registration, measured against the node before anything is signed
class DotkRegistrationPlan {
  final String name;
  final Address owner;
  final Uint8List gapLo;
  final Uint8List gapHi;
  final DotkRegistrationBuild build;

  /// Bond plus one gap value, which come back if the name is released
  final BigInt locked;

  const DotkRegistrationPlan({
    required this.name,
    required this.owner,
    required this.gapLo,
    required this.gapHi,
    required this.build,
    required this.locked,
  });

  /// The registration fee paid to the devfund
  BigInt get tier => build.tier;

  BigInt get networkFee => build.networkFee;

  /// Everything that leaves the wallet's spendable balance
  BigInt get total => tier + locked + networkFee;
}

/// Both halves of a registration, signed before either is sent
class DotkSignedRegistration {
  final String name;
  final Address owner;
  final RawTransaction split;
  final RawTransaction activate;

  /// The split's change output, which the activation spends. Keep it out of
  /// the spendable UTXOs until the activation is mined.
  final Outpoint reservedOutpoint;

  /// Where the PENDING deed appears once the split is mined
  final Address pendingDeedAddress;

  const DotkSignedRegistration({
    required this.name,
    required this.owner,
    required this.split,
    required this.activate,
    required this.reservedOutpoint,
    required this.pendingDeedAddress,
  });

  String get splitTxId => transactionIdV1(split);
}

/// Builds, signs and sends .k name transactions for this wallet. Every UTXO
/// comes from the wallet's own node, and is read again right before signing.
class DotkTxService {
  /// The smallest fee rise that makes a plan stale. Fees are a few thousand
  /// sompi and move with every block template, so a quarter alone is noise.
  static final kFeeRiseMin = BigInt.from(1_000_000);

  static BigInt feeRiseLimit(BigInt planned) {
    final quarter = planned ~/ BigInt.from(4);
    return quarter > kFeeRiseMin ? quarter : kFeeRiseMin;
  }

  final RpcService rpc;
  final DotkRegistry registry;
  final SignerBase signer;
  final bool isViewOnly;

  /// The wallet's spendable UTXOs, without covenant or reserved outputs
  final List<Utxo> Function() spendableUtxos;
  final Future<Address> Function() changeAddress;

  /// The indexer's listing of a name, asked when no live card is known
  final Future<DotkListing> Function(String name) listing;

  const DotkTxService({
    required this.rpc,
    required this.registry,
    required this.signer,
    required this.isViewOnly,
    required this.spendableUtxos,
    required this.changeAddress,
    required this.listing,
  });

  /// Carries the records over only to an owner in this wallet. [card] is the
  /// indexer's listing; one the node does not hold at the deed is refused as
  /// settling.
  Future<DotkTransferPlan> planTransfer({
    required String name,
    required Address from,
    required Address to,
    DotkCard? card,
  }) async {
    if (to.encoded == from.encoded) {
      throw const DotkTxError('The new owner is the current owner');
    }
    final toWallet = await signer.canSignForAddress(to);
    return _planTransfer(
      name: name,
      from: from,
      to: to,
      card: card,
      mintBlob: (live) => toWallet ? live : null,
    );
  }

  /// A same-owner transfer that mints a card with `primary: true` added to
  /// the proven records, or holding only that entry
  ///
  /// [knownDeedTxId] names a deed the wallet knows carries no card, like the
  /// activation of a name it just registered
  Future<DotkTransferPlan> planSetPrimary({
    required String name,
    required Address owner,
    DotkCard? card,
    String? knownDeedTxId,
  }) => _planTransfer(
    name: name,
    from: owner,
    to: owner,
    card: card,
    knownDeedTxId: knownDeedTxId,
    mintBlob: (live) =>
        DotkRecordEdits.withPrimary(live ?? Uint8List.fromList([0xa0])),
  );

  /// A same-owner transfer that mints a card without the `primary` entry,
  /// keeping every other entry's bytes. A card left with no records is not
  /// minted.
  Future<DotkTransferPlan> planUnsetPrimary({
    required String name,
    required Address owner,
    required DotkCard card,
  }) => _planTransfer(
    name: name,
    from: owner,
    to: owner,
    card: card,
    // The card is live here: a listed card the node does not hold is refused
    mintBlob: (live) {
      final blob = DotkRecordEdits.withoutPrimary(live!);
      return DotkRecordEdits.count(blob) == 0 ? null : blob;
    },
  );

  /// Reads the deed and card from the node again, rebuilds the plan, signs
  /// it and submits it. Call after the user has authenticated.
  Future<String> sendTransfer(DotkTransferPlan plan) async {
    _requireSigner();
    final fresh = await _planTransfer(
      name: plan.name,
      from: plan.from,
      to: plan.to,
      card: plan.card,
      mintBlob: (_) => plan.mintBlob,
      plannedDeed: plan.deedOutpoint,
    );
    _checkFee(plan.fee, fresh.fee);
    return _signAndSubmit(fresh.assembled);
  }

  Future<DotkTransferPlan> _planTransfer({
    required String name,
    required Address from,
    required Address to,
    required DotkCard? card,
    required Uint8List? Function(Uint8List? liveBlob) mintBlob,
    String? knownDeedTxId,
    Outpoint? plannedDeed,
  }) async {
    final (ownerType, owner) = _ownerOf(from);
    if (ownerType != DotkOwnerType.schnorr) {
      throw const DotkTxError('The wallet signs for Schnorr owners only');
    }
    final (newOwnerType, newOwner) = _ownerOf(to);
    if (to.prefix != registry.prefix) {
      throw const DotkTxError('The new owner is on another network');
    }

    final deedState = DotkState.activeDeed(name, ownerType, owner);
    final deedAddress = registry.deedAddress(deedState).encoded;
    final cardState = card == null
        ? null
        : DotkCardState.forBlob(
            name,
            card.blob,
            spenderType: card.spenderType,
            spender: card.spender,
          );
    final cardAddress = cardState?.address(registry).encoded;

    final utxos = await rpc.getUtxosByAddresses([deedAddress, ?cardAddress]);
    final deeds = utxos
        .where(
          (u) =>
              u.address == deedAddress &&
              u.utxoEntry.covenantId?.hex == registry.covenantId,
        )
        .toList();
    if (deeds.length != 1) {
      throw DotkStaleError('The node holds no deed for $name at this owner');
    }
    final deedUtxo = deeds.single;
    // A plan being sent passed the card check against this very deed
    if (plannedDeed != null && deedUtxo.outpoint != plannedDeed) {
      throw const DotkStaleError('The deed moved since the plan was made');
    }

    // A card counts only as output 1 of the transaction that created the
    // deed's current UTXO
    final cardUtxos = cardAddress == null
        ? const <Utxo>[]
        : utxos.where((u) => u.address == cardAddress).toList();
    final live = cardUtxos.any(
      (u) =>
          u.outpoint.transactionId == deedUtxo.outpoint.transactionId &&
          u.outpoint.index == 1,
    );
    final liveBlob = live ? card!.blob : null;

    final sweep = <DotkCardSweep>[];
    if (cardState != null && cardState.spenderType == DotkOwnerType.schnorr) {
      final spender = cardState.spenderAddress(registry.prefix);
      if (await signer.canSignForAddress(spender)) {
        // The card address is public, so coins sent there to bloat the
        // transaction are left: the live card first, then the largest, and
        // no coinbase, which may not be mature
        bool isLive(Utxo u) =>
            u.outpoint.transactionId == deedUtxo.outpoint.transactionId &&
            u.outpoint.index == 1;
        final coins =
            cardUtxos
                .where(
                  (u) =>
                      u.utxoEntry.covenantId == null && !u.utxoEntry.isCoinbase,
                )
                .toList()
              ..sort(
                (a, b) => isLive(a) != isLive(b)
                    ? (isLive(a) ? -1 : 1)
                    : b.utxoEntry.amount.compareTo(a.utxoEntry.amount),
              );
        for (final utxo in coins.take(kMaxCardSweeps)) {
          sweep.add(DotkCardSweep(utxo: utxo, state: cardState));
        }
      }
    }

    // Every transfer keeps the live card for an owner in this wallet and
    // sweeps it for anyone else, so it must see that card. Without one live
    // at the deed, the indexer must have read past the deed and list none.
    if (!live &&
        plannedDeed == null &&
        deedUtxo.outpoint.transactionId != knownDeedTxId) {
      if (card != null) {
        throw const DotkSettlingError('The listed card is not the live one');
      }
      final listed = await listing(name);
      final indexed = listed.indexedDaaScore;
      if (listed.card != null ||
          listed.address != from.encoded ||
          indexed == null ||
          indexed < deedUtxo.utxoEntry.blockDaaScore) {
        throw const DotkSettlingError('The indexer has not read the deed');
      }
    }
    final blob = mintBlob(liveBlob);
    final mint = blob == null
        ? null
        : DotkCardMint(
            DotkCardState.forBlob(
              name,
              blob,
              spenderType: newOwnerType,
              spender: newOwner,
            ),
            blob,
          );

    final intent = DotkIntents.transfer(
      registry: registry,
      deed: DotkDeed(
        name: name,
        ownerType: ownerType,
        owner: owner,
        utxo: deedUtxo,
      ),
      ownerAddress: from,
      newOwnerType: newOwnerType,
      newOwner: newOwner,
      cards: DotkCardPlan(mint: mint, sweep: sweep, retires: live),
    );
    final change = await changeAddress();
    final (feerate, readyMass) = await _market();
    final assembled = DotkAssembler.assemble(
      intent,
      funding: _funding(),
      changeScript: payToAddressScript(change),
      feerate: feerate,
      readyMass: readyMass,
    );

    return DotkTransferPlan(
      name: name,
      from: from,
      to: to,
      cardChange: mint != null
          ? DotkCardChange.kept
          : live
          ? DotkCardChange.cleared
          : DotkCardChange.none,
      card: card,
      mintBlob: blob,
      swept: sweep.length,
      assembled: assembled,
    );
  }

  /// A registration of [name] for the wallet address [owner]. [gapLo] and
  /// [gapHi] are the covering bounds from `/names/{name}/key`. The gap's
  /// outpoint and value come from the node only.
  Future<DotkRegistrationPlan> planRegistration({
    required String name,
    required Address owner,
    required Uint8List gapLo,
    required Uint8List gapHi,
  }) async {
    if (!DotkName.isValid(name)) {
      throw DotkTxError('$name is not a valid name');
    }
    final (ownerType, ownerKey) = _ownerOf(owner);
    final gap = await _gapOf(gapLo, gapHi);
    final (feerate, readyMass) = await _market();
    final build = DotkRegistration.build(
      registry: registry,
      gap: gap,
      name: name,
      ownerType: ownerType,
      owner: ownerKey,
      funding: _funding(),
      changeAddress: await changeAddress(),
      feerate: feerate,
      readyMass: readyMass,
    );

    return DotkRegistrationPlan(
      name: name,
      owner: owner,
      gapLo: gapLo,
      gapHi: gapHi,
      build: build,
      locked: registry.params.bond + registry.params.gapValue,
    );
  }

  /// Reads the gap again, rebuilds both halves and signs both. Nothing is
  /// sent. Persist the result before [submitTransaction].
  Future<DotkSignedRegistration> signRegistration(
    DotkRegistrationPlan plan,
  ) async {
    _requireSigner();
    final fresh = await planRegistration(
      name: plan.name,
      owner: plan.owner,
      gapLo: plan.gapLo,
      gapHi: plan.gapHi,
    );
    final build = fresh.build;
    if (build.split.tx.inputs.first.previousOutpoint !=
        plan.build.split.tx.inputs.first.previousOutpoint) {
      throw const DotkStaleError('The gap moved since the plan was made');
    }
    _checkFee(plan.networkFee, build.networkFee);

    final split = await DotkSigner.sign(build.split, signer.sign);
    final activate = await DotkSigner.sign(build.activate, signer.sign);
    return DotkSignedRegistration(
      name: plan.name,
      owner: plan.owner,
      split: split,
      activate: activate,
      reservedOutpoint: build.splitChange.outpoint,
      pendingDeedAddress: Address.decodeAddress(build.pending.address),
    );
  }

  /// Sends a signed transaction as it is. A registration sends its
  /// activation only once the node shows the PENDING deed, see
  /// [pendingDeed].
  Future<String> submitTransaction(RawTransaction tx) =>
      rpc.submitTransaction(tx);

  /// Where the PENDING deed of a registration appears
  String pendingDeedAddress({required String name, required Address owner}) {
    final (ownerType, ownerKey) = _ownerOf(owner);
    return registry
        .deedAddress(
          DotkState.pendingDeed(
            DotkState.keyOf(name),
            DotkState.claimOf(name, ownerType, ownerKey),
          ),
        )
        .encoded;
  }

  /// The PENDING deed of a registration, if the node holds it
  Future<Utxo?> pendingDeed({required String name, required Address owner}) =>
      _registryUtxoAt(pendingDeedAddress(name: name, owner: owner));

  /// The ACTIVE deed of a name under an owner, if the node holds it
  Future<Utxo?> activeDeed({
    required String name,
    required Address owner,
  }) {
    final (ownerType, ownerKey) = _ownerOf(owner);
    return _registryUtxoAt(
      registry
          .deedAddress(DotkState.activeDeed(name, ownerType, ownerKey))
          .encoded,
    );
  }

  /// A new activation for a PENDING deed the node holds, funded from
  /// [preferred] first. [priority] pays enough for the node to take it as a
  /// replacement of an activation it holds. Refuses a fee over [maxFee].
  Future<RawTransaction> signActivation({
    required String name,
    required Address owner,
    List<Utxo> preferred = const [],
    bool priority = false,
    BigInt? maxFee,
  }) async {
    _requireSigner();
    final pending = await pendingDeed(name: name, owner: owner);
    if (pending == null) {
      throw DotkStaleError('The node holds no PENDING deed for $name');
    }
    final (ownerType, ownerKey) = _ownerOf(owner);
    final change = await changeAddress();
    final (feerate, readyMass) = await _market(priority: priority);
    DotkAssembled assemble(List<Utxo> funding) => DotkRegistration.activate(
      registry: registry,
      pending: pending,
      name: name,
      ownerType: ownerType,
      owner: ownerKey,
      funding: funding,
      changeAddress: change,
      feerate: feerate,
      readyMass: readyMass,
      floors: priority ? 2 : 1,
    );
    DotkAssembled? assembled;
    if (preferred.isNotEmpty) {
      try {
        assembled = assemble(preferred);
      } on DotkInsufficientFundsError {
        assembled = null;
      }
    }
    assembled ??= assemble([...preferred, ..._funding()]);
    if (maxFee != null && assembled.fee > maxFee) {
      throw DotkTxError(
        'The activation fee ${assembled.fee} is over the $maxFee sompi limit',
      );
    }
    return DotkSigner.sign(assembled, signer.sign);
  }

  /// Sends [tx] in place of the transaction in the node's mempool that
  /// spends the same inputs, which must pay a lower feerate
  Future<String> submitReplacement(RawTransaction tx) async =>
      (await rpc.submitTransactionReplacement(tx)).$1;

  /// The outputs of [tx] that the node holds as UTXOs. Only outputs that pay
  /// to a public key or a script hash are looked up.
  Future<List<Utxo>> unspentOutputs(RawTransaction tx) async {
    final txId = transactionIdV1(tx);
    final addresses = {
      for (final output in tx.outputs)
        ?addressOf(output.scriptPublicKey)?.encoded,
    };
    if (addresses.isEmpty) {
      return [];
    }
    final utxos = await rpc.getUtxosByAddresses(addresses);
    return [
      for (final utxo in utxos)
        if (utxo.outpoint.transactionId == txId &&
            utxo.outpoint.index < tx.outputs.length)
          utxo,
    ];
  }

  /// The address a script pays to, where it pays to a Schnorr or ECDSA
  /// public key or to a script hash
  Address? addressOf(ScriptPublicKey spk) {
    final script = spk.scriptPublicKey;
    final prefix = registry.prefix;
    if (script.length == 34 && script[0] == 0x20 && script[33] == 0xac) {
      return Address.publicKey(
        prefix: prefix,
        publicKey: script.sublist(1, 33),
      );
    }
    if (script.length == 35 && script[0] == 0x21 && script[34] == 0xab) {
      return Address.pubKeyECDSA(
        prefix: prefix,
        publicKey: script.sublist(1, 34),
      );
    }
    if (script.length == 35 &&
        script[0] == 0xaa &&
        script[1] == 0x20 &&
        script[34] == 0x87) {
      return Address.scriptHash(prefix: prefix, hash: script.sublist(2, 34));
    }
    return null;
  }

  /// Whether the node's mempool holds [txId], found through the
  /// transactions that spend from or pay to [addresses]
  Future<bool> inMempool(String txId, Iterable<String> addresses) async {
    final entries = await rpc.getMempoolEntriesByAddresses(
      addresses,
      includeOrphanPool: true,
    );
    return entries.any(
      (entry) => entry.sending
          .followedBy(entry.receiving)
          .any((mempool) => mempool.transaction.transactionId == txId),
    );
  }

  /// The outpoints of [inputs] that the node still holds as UTXOs
  Future<Set<Outpoint>> unspent(Iterable<RawInput> inputs) async {
    final wanted = {for (final input in inputs) input.previousOutpoint};
    if (wanted.isEmpty) {
      return {};
    }
    final utxos = await rpc.getUtxosByAddresses({
      for (final input in inputs) input.address.encoded,
    });
    return {
      for (final utxo in utxos)
        if (wanted.contains(utxo.outpoint)) utxo.outpoint,
    };
  }

  void _checkFee(BigInt planned, BigInt fresh) {
    if (fresh > planned + feeRiseLimit(planned)) {
      throw const DotkFeeRoseError(
        'The network fee rose since the plan was made',
      );
    }
  }

  void _requireSigner() {
    if (isViewOnly) {
      throw const DotkWatchOnlyError();
    }
  }

  Future<String> _signAndSubmit(DotkAssembled assembled) async {
    final signed = await DotkSigner.sign(assembled, signer.sign);
    return rpc.submitTransaction(signed);
  }

  (int, Uint8List) _ownerOf(Address address) {
    final pair = DotkProver.ownerOf(address);
    if (pair == null) {
      throw DotkTxError('$address cannot own a name');
    }
    return pair;
  }

  List<Utxo> _funding() => spendableUtxos()
      .where((utxo) => utxo.utxoEntry.covenantId == null)
      .toList();

  /// The feerate, and the node's ready mempool mass where the node reports
  /// it through an experimental call. A priority activation pays twice the
  /// relay minimum at least, which is what a replacement needs.
  Future<(double, BigInt?)> _market({bool priority = false}) async {
    FeeEstimate? estimate;
    BigInt? readyMass;
    try {
      (estimate, readyMass) = await rpc.getFeeEstimateExperimental();
    } on Exception {
      readyMass = null;
    }
    if (estimate == null || readyMass == null) {
      estimate = await rpc.getFeeEstimate();
    }
    final normal =
        (estimate.normalBuckets.firstOrNull ?? estimate.priorityBucket).feerate;
    if (!priority) {
      return (normal, readyMass);
    }
    final rate = [
      estimate.priorityBucket.feerate,
      2 * normal,
    ].reduce((a, b) => a > b ? a : b);
    return (rate, readyMass);
  }

  Future<Utxo?> _registryUtxoAt(String address) async {
    final utxos = await rpc.getUtxosByAddresses([address]);
    final found = utxos.where(
      (u) =>
          u.address == address &&
          u.utxoEntry.covenantId?.hex == registry.covenantId,
    );
    return found.length == 1 ? found.single : null;
  }

  Future<DotkGap> _gapOf(Uint8List lo, Uint8List hi) async {
    final state = DotkState.gap(lo, hi);
    final utxo = await _registryUtxoAt(registry.gapAddress(state).encoded);
    if (utxo == null) {
      throw const DotkStaleError('The node holds no gap at those bounds');
    }
    return DotkGap(lo: lo, hi: hi, utxo: utxo);
  }
}
