import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kaspium_wallet/dotk/dotk_record_edits.dart';
import 'package:kaspium_wallet/dotk/dotk_script.dart';
import 'package:kaspium_wallet/dotk/dotk_service.dart';
import 'package:kaspium_wallet/dotk/dotk_tx.dart';
import 'package:kaspium_wallet/dotk/dotk_tx_assemble.dart';
import 'package:kaspium_wallet/dotk/dotk_tx_codec.dart';
import 'package:kaspium_wallet/dotk/dotk_tx_service.dart';
import 'package:kaspium_wallet/dotk/dotk_types.dart';
import 'package:kaspium_wallet/kaspa/api/json_client.dart';
import 'package:kaspium_wallet/kaspa/kaspa.dart';
import 'package:kaspium_wallet/utxos/utxos_providers.dart';
import 'package:retry/retry.dart';

import 'dotk_fake_node.dart';
import 'dotk_fake_tx.dart';

final _registry = testRegistry;

final _alice = TestKey('11' * 32);
final _bob = TestKey('12' * 32);
final _outsider = TestKey('13' * 32);

void main() {
  late FakeTxNode node;
  late DotkTxService service;
  final deedTxId = 'dd' * 32;
  final deedState = DotkState.activeDeed(
    'kaspa',
    DotkOwnerType.schnorr,
    _alice.publicKey,
  );
  final card = DotkCard(
    spenderType: DotkOwnerType.schnorr,
    spender: _alice.publicKey,
    blob: primaryBlob,
  );
  final cardState = DotkCardState.forBlob(
    'kaspa',
    primaryBlob,
    spenderType: DotkOwnerType.schnorr,
    spender: _alice.publicKey,
  );

  late DotkListing listed;

  DotkTxService serviceFor({bool viewOnly = false}) => DotkTxService(
    rpc: node,
    registry: _registry,
    signer: FakeSigner([_alice, _bob]),
    isViewOnly: viewOnly,
    spendableUtxos: () => spendableUtxosOf(
      node.utxos.where(
        (u) => u.address == _alice.address.encoded,
      ),
      virtualDaaScore: .from(10000),
    ),
    changeAddress: () async => _alice.address,
    listing: (_) async => listed,
  );

  setUp(() {
    // The indexer has read past every deed here and lists no card
    listed = (
      address: _alice.address.encoded,
      card: null,
      indexedDaaScore: BigInt.from(1000),
    );
    node = FakeTxNode();
    node.utxos.addAll([
      registryUtxo(
        _registry.deedAddress(deedState).encoded,
        Outpoint(transactionId: deedTxId, index: 0),
        _registry.params.bond,
        _registry.deedScriptPublicKey(deedState),
        covenant: true,
      ),
      registryUtxo(
        cardState.address(_registry).encoded,
        Outpoint(transactionId: deedTxId, index: 1),
        _registry.params.cardValue,
        cardState.scriptPublicKey(_registry.cardMagic),
      ),
      registryUtxo(
        _alice.address.encoded,
        Outpoint(transactionId: 'bb' * 32, index: 0),
        kSompiPerKaspa * .from(100),
        payToAddressScript(_alice.address),
      ),
    ]);
    service = serviceFor();
  });

  void expectSignedBy(RawTransaction tx, int input, TestKey key) {
    final hash = getSchnorrSignatureHash(
      tx: tx,
      inputIndex: input,
      hashType: .sigHashAll,
      reusedValues: SigHashReusedValues(),
    );
    final script = tx.inputs[input].signatureScript;
    final (at, length) = DotkScript.pushesOf(script).firstWhere(
      (push) => push.$2 == DotkScript.sigLength,
    );
    expect(length, DotkScript.sigLength);
    expect(script[at + 64], kSigHashAll);
    expect(
      verifySchnorr(
        publicKey: key.publicKey.hex,
        hash: hash.hex,
        signature: script.sublist(at, at + 64).hex,
      ),
      isTrue,
    );
  }

  group('DotkTxService transfer', () {
    test('to an outside owner sweeps the card and mints none', () async {
      final plan = await service.planTransfer(
        name: 'kaspa',
        from: _alice.address,
        to: _outsider.address,
        card: card,
      );
      expect(plan.cardChange, DotkCardChange.cleared);
      expect(plan.clearsRecords, isTrue);
      expect(plan.swept, 1);

      final txId = await service.sendTransfer(plan);
      final tx = node.submitted.single;
      expect(transactionIdV1(tx), txId);
      expect(tx.version, 1);
      expect(tx.payload, isNull);
      expect(tx.inputs.map((i) => i.computeBudget), [100, 20, 20]);
      expect(tx.outputs.length, 2);
      expect(tx.outputs[0].value, _registry.params.bond);
      expect(tx.outputs[0].covenant?.authorizingInput, 0);
      expect(tx.outputs[0].covenant?.covenantId.hex, _registry.covenantId);
      final next = DotkState.activeDeed(
        'kaspa',
        DotkOwnerType.schnorr,
        _outsider.publicKey,
      );
      expect(
        tx.outputs[0].scriptPublicKey.scriptPublicKey.hex,
        _registry.deedScriptPublicKey(next).scriptPublicKey.hex,
      );
      expectSignedBy(tx, 0, _alice);
      expectSignedBy(tx, 1, _alice);
      expectSignedBy(tx, 2, _alice);
      expect(tx.inputs[2].signatureScript.length, 66);
    });

    test('sweeps the live card first, and no covenant coin', () async {
      final cardAddress = cardState.address(_registry).encoded;
      final cardSpk = cardState.scriptPublicKey(_registry.cardMagic);
      final live = node.utxos[1].outpoint;
      final covenantCoin = Outpoint(transactionId: 'c0' * 32, index: 0);
      final coinbaseCoin = Outpoint(transactionId: 'c0' * 32, index: 1);
      Outpoint coin(int i) => Outpoint(transactionId: 'c1' * 32, index: i);
      node.utxos.addAll([
        for (var i = 0; i < kMaxCardSweeps + 1; i++)
          registryUtxo(
            cardAddress,
            coin(i),
            kSompiPerKaspa * .from(i + 1),
            cardSpk,
          ),
        registryUtxo(
          cardAddress,
          covenantCoin,
          kSompiPerKaspa * .from(100),
          cardSpk,
          covenant: true,
        ),
        registryUtxo(
          cardAddress,
          coinbaseCoin,
          kSompiPerKaspa * .from(100),
          cardSpk,
          coinbase: true,
        ),
      ]);
      final plan = await service.planTransfer(
        name: 'kaspa',
        from: _alice.address,
        to: _outsider.address,
        card: card,
      );
      expect(plan.swept, kMaxCardSweeps);
      await service.sendTransfer(plan);
      final spent = node.submitted.single.inputs
          .map((i) => i.previousOutpoint)
          .toList();
      expect(spent, contains(live));
      expect(spent, isNot(contains(coin(0))));
      expect(spent, isNot(contains(covenantCoin)));
      expect(spent, isNot(contains(coinbaseCoin)));
    });

    test(
      'inside the wallet mints the same records for the new owner',
      () async {
        final plan = await service.planTransfer(
          name: 'kaspa',
          from: _alice.address,
          to: _bob.address,
          card: card,
        );
        expect(plan.cardChange, DotkCardChange.kept);
        expect(plan.mintBlob, primaryBlob);
        expect(plan.swept, 1);

        await service.sendTransfer(plan);
        final tx = node.submitted.single;
        final minted = DotkCardState.forBlob(
          'kaspa',
          primaryBlob,
          spenderType: DotkOwnerType.schnorr,
          spender: _bob.publicKey,
        );
        expect(tx.outputs[1].value, _registry.params.cardValue);
        expect(tx.outputs[1].covenant, isNull);
        expect(
          tx.outputs[1].scriptPublicKey.scriptPublicKey.hex,
          minted.scriptPublicKey(_registry.cardMagic).scriptPublicKey.hex,
        );
        expect(
          tx.payload?.hex,
          DotkCardMint(minted, primaryBlob).payload(_registry.cardMagic).hex,
        );

        // A listed card the node does not hold is waited for, not dropped
        node.utxos.removeAt(1);
        for (final to in [_bob, _outsider]) {
          await expectLater(
            service.planTransfer(
              name: 'kaspa',
              from: _alice.address,
              to: to.address,
              card: card,
            ),
            throwsA(isA<DotkSettlingError>()),
          );
        }
      },
    );

    test('primary plans change only the primary entry', () async {
      final plan = await service.planUnsetPrimary(
        name: 'kaspa',
        owner: _alice.address,
        card: card,
      );
      expect(plan.isSameOwner, isTrue);
      expect(plan.mintBlob, DotkRecordEdits.withoutPrimary(primaryBlob));
      expect(plan.swept, 1);
      expect(plan.cardHeld, BigInt.zero);

      // A card that held only the flag is swept and not minted again
      final flagOnly = encodeRecords({'primary': true});
      final flagCard = DotkCard(
        spenderType: DotkOwnerType.schnorr,
        spender: _alice.publicKey,
        blob: flagOnly,
      );
      final flagState = DotkCardState.forBlob(
        'kaspa',
        flagOnly,
        spenderType: DotkOwnerType.schnorr,
        spender: _alice.publicKey,
      );
      node.utxos[1] = registryUtxo(
        flagState.address(_registry).encoded,
        Outpoint(transactionId: deedTxId, index: 1),
        _registry.params.cardValue,
        flagState.scriptPublicKey(_registry.cardMagic),
      );
      final cleared = await service.planUnsetPrimary(
        name: 'kaspa',
        owner: _alice.address,
        card: flagCard,
      );
      expect(cleared.mintBlob, isNull);
      expect(cleared.cardChange, DotkCardChange.cleared);
      expect(cleared.swept, 1);
      expect(cleared.cardHeld, -_registry.params.cardValue);
      // Only the flag leaves, which the records list does not show
      final flagOut = await service.planTransfer(
        name: 'kaspa',
        from: _alice.address,
        to: _outsider.address,
        card: flagCard,
      );
      expect(flagOut.clearsRecords, isFalse);

      // Without a card, only the flag is minted
      node.utxos.removeAt(1);
      final set = await service.planSetPrimary(
        name: 'kaspa',
        owner: _alice.address,
      );
      expect(set.mintBlob?.hex, 'a1677072696d617279f5');
      expect(set.cardHeld, _registry.params.cardValue);

      // An indexer behind the deed, or one that lists a card the caller did
      // not pass, or one that lists another owner, may hide a card that
      // neither a new card nor a transfer may drop
      final alice = _alice.address.encoded;
      for (final behind in <DotkListing>[
        (
          address: alice,
          card: null,
          indexedDaaScore: BigInt.from(kDeedDaaScore - 1),
        ),
        (address: alice, card: card, indexedDaaScore: BigInt.from(1000)),
        (
          address: _outsider.address.encoded,
          card: null,
          indexedDaaScore: BigInt.from(1000),
        ),
      ]) {
        listed = behind;
        await expectLater(
          service.planSetPrimary(name: 'kaspa', owner: _alice.address),
          throwsA(isA<DotkSettlingError>()),
        );
        await expectLater(
          service.planTransfer(
            name: 'kaspa',
            from: _alice.address,
            to: _outsider.address,
          ),
          throwsA(isA<DotkSettlingError>()),
        );
      }
      // An indexer that read up to the deed itself has seen it
      listed = (
        address: alice,
        card: null,
        indexedDaaScore: BigInt.from(kDeedDaaScore),
      );
      await service.planSetPrimary(name: 'kaspa', owner: _alice.address);

      // The deed of the activation this wallet sent carries no card
      final registered = await service.planSetPrimary(
        name: 'kaspa',
        owner: _alice.address,
        knownDeedTxId: deedTxId,
      );
      await service.sendTransfer(registered);
      expect(node.submitted, hasLength(1));
    });

    test('a plan is stale once the fee rises past the limit or the deed '
        'moves', () async {
      expect(DotkTxService.feeRiseLimit(.from(4000)), BigInt.from(1000000));
      expect(DotkTxService.feeRiseLimit(.from(8000000)), BigInt.from(2000000));
      final plan = await service.planTransfer(
        name: 'kaspa',
        from: _alice.address,
        to: _outsider.address,
        card: card,
      );
      node.feerate = 10000;
      await expectLater(
        service.sendTransfer(plan),
        throwsA(isA<DotkFeeRoseError>()),
      );
      expect(node.submitted, isEmpty);

      // A small rise is within the limit
      node.feerate = 1.5;
      await service.sendTransfer(plan);
      expect(node.submitted, hasLength(1));

      node.utxos[0] = node.utxos[0].copyWith(
        outpoint: Outpoint(transactionId: 'ee' * 32, index: 0),
      );
      await expectLater(
        service.sendTransfer(plan),
        throwsA(isA<DotkStaleError>()),
      );
    });

    test('prices in the node ready mass, and on fee mass without it', () async {
      Future<DotkTransferPlan> plan() => service.planTransfer(
        name: 'kaspa',
        from: _alice.address,
        to: _outsider.address,
        card: card,
      );
      BigInt feeMass(DotkTransferPlan p) => DotkFees.massesOf(
        DotkFees.measuredClone(p.assembled.tx, p.assembled.fundingInputs),
      ).fee;
      node.feerate = 700;
      node.readyMass = BigInt.from(500000);
      final roomy = await plan();
      expect(roomy.fee, DotkFees.relayMinimumFee(feeMass(roomy)));
      node.readyMass = null;
      final unknown = await plan();
      expect(
        unknown.fee,
        BigInt.from((feeMass(unknown).toDouble() * 700).ceil()),
      );
    });

    test('a watch-only wallet cannot sign', () async {
      final watchOnly = serviceFor(viewOnly: true);
      final plan = await watchOnly.planTransfer(
        name: 'kaspa',
        from: _alice.address,
        to: _outsider.address,
      );
      await expectLater(
        watchOnly.sendTransfer(plan),
        throwsA(isA<DotkWatchOnlyError>()),
      );
      node.utxos.add(
        registryUtxo(
          _registry.gapAddress(DotkState.gap(gapLo, gapHi)).encoded,
          Outpoint(transactionId: 'aa' * 32, index: 0),
          _registry.params.gapValue,
          _registry.gapScriptPublicKey(DotkState.gap(gapLo, gapHi)),
          covenant: true,
        ),
      );
      final registration = await watchOnly.planRegistration(
        name: 'alice',
        owner: _alice.address,
        gapLo: gapLo,
        gapHi: gapHi,
      );
      await expectLater(
        watchOnly.signRegistration(registration),
        throwsA(isA<DotkWatchOnlyError>()),
      );
      expect(node.submitted, isEmpty);
    });

    test('refuses a bad owner or a name outside the gap', () async {
      await expectLater(
        service.planTransfer(
          name: 'kaspa',
          from: _alice.address,
          to: _alice.address,
        ),
        throwsA(isA<DotkTxError>()),
      );
      await expectLater(
        service.planTransfer(
          name: 'kaspa',
          from: _alice.address,
          to: Address.scriptHash(
            prefix: _registry.prefix,
            hash: hexToBytes('22' * 32),
          ),
        ),
        throwsA(isA<DotkTxError>()),
      );
      await expectLater(
        service.planRegistration(
          name: 'alice',
          owner: _alice.address,
          gapLo: hexToBytes('ff' * 31 + 'fe'),
          gapHi: gapHi,
        ),
        throwsA(isA<DotkTxError>()),
      );
    });
  });

  group('DotkTxService registration', () {
    setUp(() {
      final gap = DotkState.gap(gapLo, gapHi);
      node.utxos.add(
        registryUtxo(
          _registry.gapAddress(gap).encoded,
          Outpoint(transactionId: 'aa' * 32, index: 0),
          _registry.params.gapValue,
          _registry.gapScriptPublicKey(gap),
          covenant: true,
        ),
      );
    });

    test(
      'plans, signs both halves and chains activation on the change',
      () async {
        final plan = await service.planRegistration(
          name: 'alice',
          owner: _alice.address,
          gapLo: gapLo,
          gapHi: gapHi,
        );
        expect(plan.tier, _registry.params.fee5plus);
        expect(plan.locked, kSompiPerKaspa * .two);
        expect(plan.total, plan.tier + plan.locked + plan.networkFee);

        final signed = await service.signRegistration(plan);
        final split = signed.split;
        final activate = signed.activate;
        expect(split.inputs.first.computeBudget, 150);
        expect(
          split.inputs.first.signatureScript,
          plan.build.split.tx.inputs.first.signatureScript,
        );
        expectSignedBy(split, 1, _alice);
        expect(
          activate.inputs[0].previousOutpoint,
          Outpoint(transactionId: signed.splitTxId, index: 2),
        );
        expect(activate.inputs[1].previousOutpoint, signed.reservedOutpoint);
        expect(signed.reservedOutpoint.transactionId, signed.splitTxId);
        expectSignedBy(activate, 1, _alice);
        expect(activate.outputs[1].value, _registry.params.fee5plus);
        expect(
          activate.outputs[1].scriptPublicKey.scriptPublicKey,
          _registry.devfundScriptPublicKey,
        );

        // The wallet pays the price and both network fees, and nothing else
        expect(
          kSompiPerKaspa * .from(100) - activate.outputs.last.value,
          plan.total,
        );

        expect(await service.submitTransaction(signed.split), signed.splitTxId);
        final stored = DotkTxCodec.fromJson(
          jsonDecode(jsonEncode(DotkTxCodec.toJson(activate))),
        );
        expect(transactionIdV1(stored), transactionIdV1(signed.activate));
        expect(
          await service.submitTransaction(stored),
          transactionIdV1(signed.activate),
        );
        expect(
          node.submitted.last.inputs[0].signatureScript,
          activate.inputs[0].signatureScript,
        );
      },
    );

    test('finds the PENDING deed and rebuilds activation from it', () async {
      final plan = await service.planRegistration(
        name: 'alice',
        owner: _alice.address,
        gapLo: gapLo,
        gapHi: gapHi,
      );
      expect(
        await service.pendingDeed(name: 'alice', owner: _alice.address),
        isNull,
      );
      node.utxos.add(plan.build.pending);
      final pending = await service.pendingDeed(
        name: 'alice',
        owner: _alice.address,
      );
      expect(pending?.outpoint, plan.build.pending.outpoint);

      final activation = await service.signActivation(
        name: 'alice',
        owner: _alice.address,
      );
      expect(activation.inputs.first.previousOutpoint, pending?.outpoint);
      expectSignedBy(activation, 1, _alice);

      await expectLater(
        service.signActivation(
          name: 'alice',
          owner: _alice.address,
          maxFee: activation.fee - BigInt.one,
        ),
        throwsA(isA<DotkTxError>()),
      );

      // A replacement must outrank the activation it replaces
      BigInt floor(RawTransaction tx) =>
          DotkFees.relayMinimumFee(DotkFees.massesOf(tx).fee);
      Future<RawTransaction> sign({required bool priority}) =>
          service.signActivation(
            name: 'alice',
            owner: _alice.address,
            priority: priority,
          );
      node.feerate = 700;
      node.priorityFeerate = 900;
      node.readyMass = BigInt.from(500000);
      final idle = await sign(priority: false);
      expect(idle.fee, floor(idle));
      final idleBump = await sign(priority: true);
      expect(idleBump.fee, floor(idleBump) * BigInt.two);

      node.readyMass = BigInt.from(500001);
      final fullBump = await sign(priority: true);
      final mass = DotkFees.frontierMass(fullBump)!;
      expect(fullBump.fee, BigInt.from((mass.toDouble() * 1400).ceil()));

      node.readyMass = null;
      final unknownBump = await sign(priority: true);
      final feeMass = DotkFees.massesOf(unknownBump).fee;
      expect(unknownBump.fee, BigInt.from((feeMass.toDouble() * 1400).ceil()));
    });
  });

  test('the indexer listing counts only from a sound indexer of this '
      'registry that knows the name', () async {
    final requests = <http.BaseRequest>[];
    Future<DotkListing> listingFrom({
      required Object? health,
      required Object? name,
    }) => dotkListingOf(
      DotkService(
        JsonClient(
          'https://api',
          r: const RetryOptions(maxAttempts: 1),
          minRequestGap: .zero,
          client: MockClient((request) async {
            requests.add(request);
            return http.Response(
              jsonEncode(request.url.path == '/health' ? health : name),
              name == null && request.url.path != '/health' ? 404 : 200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      ),
      _registry,
      'kaspa',
    );
    final health = {
      'lastBlock': {'daaScore': 42},
      'registryCovenantId': _registry.covenantId,
    };
    final name = {
      'address': _alice.address.encoded,
      'registryCovenantId': _registry.covenantId,
    };

    final sound = await listingFrom(health: health, name: name);
    expect(sound.indexedDaaScore, BigInt.from(42));
    expect(sound.address, _alice.address.encoded);
    expect(requests.map((r) => r.url.path), ['/health', '/names/kaspa']);
    expect(
      requests.map((r) => r.headers['Cache-Control']),
      everyElement('no-cache'),
    );

    final unknown = await listingFrom(health: health, name: null);
    expect(unknown.indexedDaaScore, isNull);
    final other = await listingFrom(
      health: {...health, 'registryCovenantId': 'aa' * 32},
      name: name,
    );
    expect(other.indexedDaaScore, isNull);
    final otherName = await listingFrom(
      health: health,
      name: {...name, 'registryCovenantId': 'aa' * 32},
    );
    expect(otherName.indexedDaaScore, isNull);
  });
}
