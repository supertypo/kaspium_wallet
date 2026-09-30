import 'dart:async';
import 'dart:convert';

import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspium_wallet/dotk/dotk_registration_notifier.dart';
import 'package:kaspium_wallet/dotk/dotk_service.dart';
import 'package:kaspium_wallet/dotk/dotk_tx.dart';
import 'package:kaspium_wallet/dotk/dotk_tx_assemble.dart';
import 'package:kaspium_wallet/dotk/dotk_tx_service.dart';
import 'package:kaspium_wallet/dotk/dotk_types.dart';
import 'package:kaspium_wallet/kaspa/kaspa.dart';
import 'package:kaspium_wallet/utxos/utxos_providers.dart';

import 'dotk_fake_node.dart';
import 'dotk_fake_tx.dart';

final _registry = testRegistry;
const _name = 'alice';
final _key = TestKey('11' * 32);
final _publicKey = _key.publicKey;
final _alice = _key.address;

class _FakeDotk implements DotkService {
  DotkKeyInfo? key = DotkKeyInfo(
    free: true,
    registryCovenantId: _registry.covenantId,
  );

  @override
  Future<DotkKeyInfo?> keyInfo(String name) async => key;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Waits for the notifier to ask the node [count] more times, which is how
/// long a check that nothing changes has to watch
Future<void> _polls(FakeTxNode node, [int count = 5]) {
  final target = node.calls + count;
  return until(() => node.calls >= target, reason: '$count node calls');
}

void main() {
  late FakeTxNode node;
  late _FakeDotk dotk;
  late DotkTxService service;
  late List<List<DotkRegistrationEntry>> saves;
  late Set<Outpoint> reserved;
  late BigInt? virtualDaaScore;
  late Utxo gap;
  late Utxo funding;
  final notifiers = <DotkRegistrationNotifier>[];

  DotkRegistrationNotifier notifierFor({
    List<DotkRegistrationEntry> saved = const [],
    Future<void> Function(List<DotkRegistrationEntry>)? save,
    Duration waitFor = const Duration(seconds: 5),
    bool Function()? holdFailed,
  }) {
    final notifier = DotkRegistrationNotifier(
      service: () => service,
      dotk: () => dotk,
      load: () => saved,
      save:
          save ??
          (entries) async => saves.add([
            for (final entry in entries)
              DotkRegistrationEntry.fromJson(
                jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>,
              ),
          ]),
      onReserved: (outpoints) => reserved = outpoints,
      holdFailed: holdFailed ?? () => true,
      virtualDaaScore: () => virtualDaaScore,
      evictAfterDaa: _registry.params.tEvict,
      pollInterval: Duration.zero,
      waitFor: waitFor,
      retryAfter: const Duration(milliseconds: 10),
    );
    notifiers.add(notifier);
    return notifier;
  }

  Future<(DotkRegistrationPlan, DotkSignedRegistration)> signed() async {
    final plan = await service.planRegistration(
      name: _name,
      owner: _alice,
      gapLo: gapLo,
      gapHi: gapHi,
    );
    return (plan, await service.signRegistration(plan));
  }

  /// The node mines the reservation: its inputs are spent, and the PENDING
  /// deed and the change appear
  void mineSplit(DotkRegistrationPlan plan, DotkSignedRegistration signed) {
    final spent = signed.split.inputs.map((input) => input.previousOutpoint);
    node.utxos.removeWhere((u) => spent.contains(u.outpoint));
    node.mempool.remove(signed.splitTxId);
    final pending = plan.build.pending;
    node.utxos.add(
      pending.copyWith(
        utxoEntry: pending.utxoEntry.copyWith(blockDaaScore: .from(1000)),
      ),
    );
    node.utxos.add(plan.build.splitChange);
  }

  /// The node mines an activation: the PENDING deed and its funding are
  /// spent, and the ACTIVE deed appears
  void mineActivation(RawTransaction activate) {
    final spent = activate.inputs.map((input) => input.previousOutpoint);
    node.utxos.removeWhere((u) => spent.contains(u.outpoint));
    final id = transactionIdV1(activate);
    node.mempool.remove(id);
    final state = DotkState.activeDeed(
      _name,
      DotkOwnerType.schnorr,
      _publicKey,
    );
    node.utxos.add(
      registryUtxo(
        _registry.deedAddress(state).encoded,
        Outpoint(transactionId: id, index: 0),
        _registry.params.bond,
        _registry.deedScriptPublicKey(state),
        covenant: true,
      ),
    );
  }

  setUp(() {
    node = FakeTxNode();
    dotk = _FakeDotk();
    saves = [];
    reserved = {};
    virtualDaaScore = null;
    final gapState = DotkState.gap(gapLo, gapHi);
    gap = registryUtxo(
      _registry.gapAddress(gapState).encoded,
      Outpoint(transactionId: 'aa' * 32, index: 0),
      _registry.params.gapValue,
      _registry.gapScriptPublicKey(gapState),
      covenant: true,
    );
    funding = registryUtxo(
      _alice.encoded,
      Outpoint(transactionId: 'bb' * 32, index: 0),
      kSompiPerKaspa * .from(100),
      payToAddressScript(_alice),
    );
    node.utxos.addAll([gap, funding]);
    service = DotkTxService(
      rpc: node,
      registry: _registry,
      signer: FakeSigner([_key]),
      isViewOnly: false,
      spendableUtxos: () => spendableUtxosOf(
        node.utxos.where((u) => u.address == _alice.encoded),
        virtualDaaScore: .from(10000),
        reserved: ISet(reserved),
      ),
      changeAddress: () async => _alice,
      // A registration never plans a transfer
      listing: (_) => throw UnimplementedError(),
    );
  });

  tearDown(() {
    for (final notifier in notifiers) {
      notifier.dispose();
    }
    notifiers.clear();
  });

  group('start', () {
    test('a failed save removes the entry and sends nothing', () async {
      final notifier = notifierFor(
        save: (_) async => throw Exception('disk full'),
      );
      final (_, registration) = await signed();
      await expectLater(notifier.start(registration), throwsException);
      expect(notifier.entry(_name), isNull);
      expect(reserved, isEmpty);
      expect(node.submitted, isEmpty);
    });

    test('a double spend of the gap is a lost race', () async {
      final notifier = notifierFor();
      final (_, registration) = await signed();
      node.refuse = (_) => refusal(
        'output 0 of transaction ${'aa' * 32} is already spent by '
        'transaction ab12',
      );
      await notifier.start(registration);
      final entry = notifier.entry(_name)!;
      expect(entry.stage, DotkRegistrationStage.failed);
      expect(entry.failure, DotkRegistrationFailure.raced);
      expect(entry.split, isNull);
      expect(entry.activate, isNull);
      expect(reserved, isEmpty);
    });

    test('a refusal that may pass later sends it again', () async {
      for (final refusal in [
        Exception('connection reset by peer'),
        refusal('transaction 6f0a is an orphan where orphan is disallowed'),
      ]) {
        node.submitted.clear();
        final notifier = notifierFor();
        final (_, registration) = await signed();
        var refusals = 1;
        node.refuse = (_) => refusals-- > 0 ? refusal : null;
        await notifier.start(registration);
        expect(notifier.entry(_name)?.stage, DotkRegistrationStage.reserving);
        await until(
          () => notifier.entry(_name)?.stage == DotkRegistrationStage.waiting,
        );
        expect(node.submitted.length, 2);
        expect(notifier.entry(_name)?.failure, isNull);
        await notifier.dismiss(_name);
      }
    });

    test('a reservation refused without a verdict fails in the end', () async {
      final notifier = notifierFor();
      final (_, registration) = await signed();
      final clock = Stopwatch()..start();
      final refusedAt = <Duration>[];
      node.refuse = (_) {
        refusedAt.add(clock.elapsed);
        return refusal('a rule this wallet does not know');
      };
      await notifier.start(registration);
      await until(
        () => notifier.entry(_name)?.stage == DotkRegistrationStage.failed,
      );
      expect(notifier.entry(_name)?.failure, DotkRegistrationFailure.error);
      expect(
        node.submitted,
        hasLength(DotkRegistrationNotifier.kMaxUnknownRefusals),
      );
      expect(
        refusedAt.last - refusedAt.first,
        greaterThanOrEqualTo(const Duration(milliseconds: 20)),
      );
      expect(reserved, isEmpty);
    });

    test('sends the activation only once the reservation is mined', () async {
      final notifier = notifierFor();
      final (plan, registration) = await signed();
      final stages = <DotkRegistrationStage>[];
      notifier.addListener(() {
        final stage = notifier.entry(_name)?.stage;
        if (stage != null && stages.lastOrNull != stage) stages.add(stage);
      });

      await notifier.start(registration);
      await expectLater(
        notifier.start(registration),
        throwsA(isA<DotkTxError>()),
      );
      await until(
        () => notifier.entry(_name)?.stage == DotkRegistrationStage.waiting,
      );
      expect(node.submitted.single, registration.split);

      // The node already holds the activation, which counts as sent
      node.refuse = (tx) =>
          transactionIdV1(tx) == transactionIdV1(registration.activate)
          ? refusal('transaction 6f0a is already in the mempool')
          : null;
      mineSplit(plan, registration);
      await until(
        () => notifier.entry(_name)?.stage == DotkRegistrationStage.activating,
      );
      expect(notifier.entry(_name)?.pendingDaaScore, 1000);
      expect(
        transactionIdV1(node.submitted.last),
        transactionIdV1(registration.activate),
      );
      // The mined reservation's funding is spent, and only the change stays
      expect(reserved, {registration.reservedOutpoint});

      mineActivation(registration.activate);
      await until(
        () => notifier.entry(_name)?.stage == DotkRegistrationStage.done,
      );
      expect(stages, [
        DotkRegistrationStage.reserving,
        DotkRegistrationStage.waiting,
        DotkRegistrationStage.activating,
        DotkRegistrationStage.done,
      ]);
      expect(saves.last, isEmpty);
      await until(() => reserved.isEmpty);
    });
  });

  group('follow', () {
    test('no node call in the background', () async {
      final notifier = notifierFor(
        waitFor: const Duration(milliseconds: 200),
      );
      final (plan, registration) = await signed();
      await notifier.start(registration);
      // The activation does not get through, so the wait runs
      node.refuse = (tx) =>
          transactionIdV1(tx) == transactionIdV1(registration.activate)
          ? refusal('transaction 6f0a is lacking a matching UTXO entry')
          : null;
      mineSplit(plan, registration);
      await until(() => notifier.entry(_name)?.pendingSeenAt != null);

      notifier.onBackground();
      // Let a poll that was under way finish: the count settles
      var calls = -1;
      var stable = 0;
      while (stable < 3) {
        stable = calls == node.calls ? stable + 1 : 0;
        calls = node.calls;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      // With no poll delay, a running loop would call many times in this
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(node.calls, calls, reason: 'no node call in the background');

      notifier.onForeground();
      await until(() => node.calls > calls);
      expect(notifier.entry(_name)?.failure, isNull);

      node.refuse = null;
      await until(
        () => notifier.entry(_name)?.stage == DotkRegistrationStage.activating,
      );
    });

    test('the activation has no time limit while its deed stands', () async {
      final notifier = notifierFor(waitFor: const Duration(milliseconds: 20));
      final (plan, registration) = await signed();
      await notifier.start(registration);
      virtualDaaScore = .from(1000);
      node.refuse = (tx) =>
          transactionIdV1(tx) == transactionIdV1(registration.activate)
          ? refusal('transaction 6f0a is lacking a matching UTXO entry')
          : null;
      mineSplit(plan, registration);
      await until(() => notifier.entry(_name)?.pendingSeenAt != null);
      // Each retry sends again, and none gives up
      await until(
        () =>
            node.submitted
                .where(
                  (tx) =>
                      transactionIdV1(tx) ==
                      transactionIdV1(registration.activate),
                )
                .length >
            3,
      );
      expect(notifier.entry(_name)?.failure, isNull);
      expect(notifier.isRunning(_name), isTrue);

      // Past half of the eviction window it is signed again at a higher fee,
      // from the reservation's change
      virtualDaaScore = .from(1000 + _registry.params.tEvict ~/ 2);
      await until(
        () => notifier.entry(_name)?.stage == DotkRegistrationStage.activating,
      );
      final bumped = notifier.entry(_name)!.activateTx!;
      expect(
        transactionIdV1(bumped),
        isNot(transactionIdV1(registration.activate)),
      );
      expect(bumped.fee, greaterThan(registration.activate.fee));
      expect(
        bumped.inputs[1].previousOutpoint,
        registration.reservedOutpoint,
      );
      mineActivation(bumped);
      await until(
        () => notifier.entry(_name)?.stage == DotkRegistrationStage.done,
      );
    });

    test(
      'a new activation over the fee cap or refused keeps the old one',
      () async {
        final notifier = notifierFor(
          waitFor: const Duration(milliseconds: 20),
        );
        final (plan, registration) = await signed();
        await notifier.start(registration);
        final original = transactionIdV1(registration.activate);
        node.refuse = (tx) => transactionIdV1(tx) == original
            ? refusal('transaction 6f0a is lacking a matching UTXO entry')
            : null;
        mineSplit(plan, registration);
        await until(() => notifier.entry(_name)?.pendingSeenAt != null);
        Iterable<String> others() => node.submitted
            .map(transactionIdV1)
            .where((id) => id != original && id != registration.splitTxId);

        // Over the fee the user agreed to, nothing is signed
        node.feerate = 2000;
        virtualDaaScore = .from(1000 + _registry.params.tEvict ~/ 2);
        await _polls(node);
        expect(others(), isEmpty);
        expect(transactionIdV1(notifier.entry(_name)!.activateTx!), original);

        // Refused for good, and the old one stays
        node.feerate = 1;
        node.refuse = (tx) => switch (transactionIdV1(tx)) {
          final id when id == original => refusal(
            'transaction 6f0a is lacking a matching UTXO entry',
          ),
          final id when id == registration.splitTxId => null,
          _ => refusal('transaction 6f0a is not standard: x'),
        };
        await until(() => others().isNotEmpty);
        await _polls(node);
        final entry = notifier.entry(_name)!;
        expect(transactionIdV1(entry.activateTx!), original);
        expect(entry.failure, isNull);
        expect(notifier.isRunning(_name), isTrue);

        node.refuse = null;
        await until(
          () => transactionIdV1(notifier.entry(_name)!.activateTx!) != original,
        );
      },
    );

    test('only node refusals without a verdict fail the activation', () async {
      final notifier = notifierFor(waitFor: const Duration(milliseconds: 20));
      final (plan, registration) = await signed();
      await notifier.start(registration);
      Object? error = Exception('connection reset by peer');
      node.refuse = (tx) =>
          transactionIdV1(tx) == transactionIdV1(registration.activate)
          ? error
          : null;
      mineSplit(plan, registration);
      // More transport errors than refusals it takes to fail
      await until(
        () =>
            node.submitted
                .where(
                  (tx) =>
                      transactionIdV1(tx) ==
                      transactionIdV1(registration.activate),
                )
                .length >
            DotkRegistrationNotifier.kMaxUnknownRefusals,
      );
      expect(notifier.entry(_name)?.failure, isNull);

      node.submitted.clear();
      error = refusal('transaction 6f0a rejected for a reason unknown');
      await until(
        () => notifier.entry(_name)?.stage == DotkRegistrationStage.failed,
      );
      final entry = notifier.entry(_name)!;
      expect(entry.failure, DotkRegistrationFailure.error);
      expect(entry.activate, isNotNull);
      expect(
        node.submitted.where(
          (tx) => transactionIdV1(tx) == transactionIdV1(registration.activate),
        ),
        hasLength(DotkRegistrationNotifier.kMaxUnknownRefusals),
      );
    });

    test(
      'an activation that meets another spend of its deed replaces it',
      () async {
        final notifier = notifierFor();
        final (plan, registration) = await signed();
        await notifier.start(registration);
        final pending = plan.build.pending.outpoint;
        node.refuse = (tx) =>
            transactionIdV1(tx) == transactionIdV1(registration.activate)
            ? refusal(
                'output (${pending.transactionId}, ${pending.index}) already '
                'spent by transaction ab12 in the mempool',
              )
            : null;
        mineSplit(plan, registration);
        await until(
          () =>
              notifier.entry(_name)?.stage == DotkRegistrationStage.activating,
        );
        expect(
          transactionIdV1(node.replaced.single),
          transactionIdV1(registration.activate),
        );
        expect(notifier.entry(_name)?.activate, isNotNull);
      },
    );

    test('a double spend of its funding fails the activation', () async {
      final notifier = notifierFor();
      final (plan, registration) = await signed();
      await notifier.start(registration);
      final change = registration.reservedOutpoint;
      node.refuse = (tx) =>
          transactionIdV1(tx) == transactionIdV1(registration.activate)
          ? refusal(
              'output (${change.transactionId}, ${change.index}) already '
              'spent by transaction ab12 in the mempool',
            )
          : null;
      mineSplit(plan, registration);
      await until(
        () => notifier.entry(_name)?.stage == DotkRegistrationStage.failed,
      );
      expect(notifier.entry(_name)?.failure, DotkRegistrationFailure.error);
      expect(notifier.entry(_name)?.activate, isNull);
      expect(node.replaced, isEmpty);
    });

    test('a refused activation that was mined meanwhile is done', () async {
      final notifier = notifierFor();
      final (plan, registration) = await signed();
      await notifier.start(registration);
      node.refuse = (tx) {
        if (transactionIdV1(tx) != transactionIdV1(registration.activate)) {
          return null;
        }
        // The submission times out while the activation is mined
        mineActivation(tx);
        return TimeoutException('submit');
      };
      mineSplit(plan, registration);
      await until(
        () => notifier.entry(_name)?.stage == DotkRegistrationStage.done,
      );
      expect(notifier.entry(_name)?.failure, isNull);
    });

    test('an eviction takes two reads without the deed', () async {
      final notifier = notifierFor();
      final (plan, registration) = await signed();
      await notifier.start(registration);
      node.refuse = (_) =>
          refusal('transaction 6f0a is lacking a matching UTXO entry');
      mineSplit(plan, registration);
      await until(() => notifier.entry(_name)?.pendingSeenAt != null);
      final pending = node.utxos.firstWhere(
        (u) => u.outpoint == plan.build.pending.outpoint,
      );
      // The node's index misses the deed on one read only
      var misses = 1;
      node.beforeUtxos = (addresses) {
        if (addresses.contains(pending.address)) {
          if (misses-- > 0) {
            node.utxos.remove(pending);
          } else if (!node.utxos.contains(pending)) {
            node.utxos.add(pending);
          }
        }
      };
      await _polls(node);
      expect(notifier.entry(_name)?.failure, isNull);
      expect(notifier.isRunning(_name), isTrue);

      node.beforeUtxos = null;
      node.utxos.remove(pending);
      await until(
        () => notifier.entry(_name)?.failure == DotkRegistrationFailure.evicted,
      );
      expect(notifier.entry(_name)?.split, isNull);
    });
  });

  /// A registration whose reservation is sent, stopped as not confirmed
  Future<(DotkRegistrationPlan, DotkSignedRegistration, DotkRegistrationEntry)>
  stopped() async {
    final (plan, registration) = await signed();
    final notifier = notifierFor();
    await notifier.start(registration);
    notifier.dispose();
    notifiers.remove(notifier);
    final saved = saves.last.single.copyWith(
      stage: .failed,
      failure: .notConfirmed,
    );
    return (plan, registration, saved);
  }

  group('resume', () {
    test('asks for authentication, then signs a new activation', () async {
      final (plan, registration, saved) = await stopped();
      mineSplit(plan, registration);
      // The activation's funding is spent elsewhere
      node.utxos.removeWhere(
        (u) => u.outpoint == plan.build.splitChange.outpoint,
      );
      final newFunding = Outpoint(transactionId: 'cc' * 32, index: 0);
      node.utxos.add(
        registryUtxo(
          _alice.encoded,
          newFunding,
          kSompiPerKaspa * .from(50),
          payToAddressScript(_alice),
        ),
      );
      node.refuse = (tx) =>
          transactionIdV1(tx) == transactionIdV1(registration.activate)
          ? refusal('transaction 6f0a is lacking a matching UTXO entry')
          : null;

      final resumed = notifierFor(saved: [saved]);
      expect(await resumed.resume(_name), DotkResumeNeed.none);
      await until(
        () => resumed.entry(_name)?.stage == DotkRegistrationStage.failed,
      );
      expect(resumed.entry(_name)?.activate, isNull);
      expect(resumed.entry(_name)?.failure, DotkRegistrationFailure.error);

      expect(await resumed.resume(_name), DotkResumeNeed.auth);
      // Without funds it cannot be signed, which the sheet shows
      final funds = node.utxos.firstWhere((u) => u.outpoint == newFunding);
      node.utxos.remove(funds);
      await expectLater(
        resumed.resume(_name, signed: true),
        throwsA(isA<DotkInsufficientFundsError>()),
      );
      expect(resumed.entry(_name)?.failure, DotkRegistrationFailure.error);
      node.utxos.add(funds);

      expect(await resumed.resume(_name, signed: true), DotkResumeNeed.none);
      final activate = resumed.entry(_name)!.activateTx!;
      expect(
        activate.inputs.first.previousOutpoint,
        plan.build.pending.outpoint,
      );
      expect(activate.inputs[1].previousOutpoint, newFunding);
      expect(reserved, contains(newFunding));
      await until(
        () => resumed.entry(_name)?.stage == DotkRegistrationStage.activating,
      );
    });

    test('our own PENDING deed is never taken, nor safe to dismiss', () async {
      final (plan, registration, saved) = await stopped();
      node.mempool.clear();
      dotk.key = DotkKeyInfo(
        free: false,
        registryCovenantId: _registry.covenantId,
      );
      mineSplit(plan, registration);
      final resumed = notifierFor(saved: [saved]);
      expect(await resumed.isDismissSafe(_name), isFalse);
      expect(await resumed.resume(_name), DotkResumeNeed.none);
      expect(resumed.entry(_name)?.failure, isNull);
      expect(resumed.isRunning(_name), isTrue);
    });

    test(
      'a reservation that is gone is classified by node and indexer',
      () async {
        final (plan, _, saved) = await stopped();
        node.mempool.clear();

        // Its funding is spent elsewhere, and the gap stands
        node.utxos.remove(funding);
        final spent = notifierFor(saved: [saved]);
        expect(await spent.resume(_name), DotkResumeNeed.newReservation);
        expect(spent.entry(_name)?.failure, DotkRegistrationFailure.dropped);
        expect(spent.entry(_name)?.split, isNull);
        expect(reserved, isEmpty);
        node.utxos.add(funding);

        // The gap is spent: a lost race where the indexer lists the key free,
        // taken where it lists the name, and nothing from another registry
        node.utxos.remove(gap);
        final raced = notifierFor(saved: [saved]);
        expect(await raced.resume(_name), DotkResumeNeed.newReservation);
        expect(raced.entry(_name)?.failure, DotkRegistrationFailure.raced);

        dotk.key = const DotkKeyInfo(free: false, registryCovenantId: '00');
        final other = notifierFor(saved: [saved]);
        expect(await other.resume(_name), DotkResumeNeed.unanswered);
        expect(
          other.entry(_name)?.failure,
          DotkRegistrationFailure.notConfirmed,
        );

        dotk.key = DotkKeyInfo(
          free: false,
          registryCovenantId: _registry.covenantId,
        );
        final taken = notifierFor(saved: [saved]);
        expect(await taken.resume(_name), DotkResumeNeed.taken);
        expect(taken.entry(_name)?.failure, DotkRegistrationFailure.taken);
        expect(taken.entry(_name)?.split, isNull);

        // Mined once, and its change still stands, seen by the wallet or not
        dotk.key = DotkKeyInfo(
          free: true,
          registryCovenantId: _registry.covenantId,
        );
        node.utxos.add(plan.build.splitChange);
        for (final evicted in [
          saved,
          saved.copyWith(pendingSeenAt: 1, pendingDaaScore: 1000),
        ]) {
          final notifier = notifierFor(saved: [evicted]);
          expect(await notifier.resume(_name), DotkResumeNeed.newReservation);
          expect(
            notifier.entry(_name)?.failure,
            DotkRegistrationFailure.evicted,
          );
        }
        dotk.key = const DotkKeyInfo(free: true, registryCovenantId: '00');
        final elsewhere = notifierFor(saved: [saved]);
        expect(await elsewhere.resume(_name), DotkResumeNeed.unanswered);
        expect(
          elsewhere.entry(_name)?.failure,
          DotkRegistrationFailure.evicted,
        );
      },
    );

    test('a reservation in the mempool waits, and a dropped one is sent '
        'again', () async {
      final (_, registration, saved) = await stopped();
      expect(node.mempool, contains(registration.splitTxId));
      final alive = notifierFor(saved: [saved]);
      expect(await alive.isDismissSafe(_name), isFalse);
      expect(await alive.resume(_name), DotkResumeNeed.none);
      expect(alive.entry(_name)?.stage, DotkRegistrationStage.waiting);
      expect(alive.entry(_name)?.failure, isNull);
      alive.dispose();
      notifiers.remove(alive);

      node.mempool.clear();
      final dropped = notifierFor(saved: [saved]);
      expect(await dropped.isDismissSafe(_name), isTrue);
      expect(await dropped.resume(_name), DotkResumeNeed.none);
      await until(() => node.mempool.contains(registration.splitTxId));
      expect(node.submitted.last, registration.split);
    });

    test('an activation mined between the reads is not taken', () async {
      final (plan, registration, saved) = await stopped();
      mineSplit(plan, registration);
      dotk.key = DotkKeyInfo(
        free: false,
        registryCovenantId: _registry.covenantId,
      );
      final pendingAddress = plan.build.pending.address;
      node.beforeUtxos = (addresses) {
        if (addresses.contains(pendingAddress) &&
            node.utxos.any((u) => u.outpoint == plan.build.pending.outpoint)) {
          mineActivation(registration.activate);
        }
      };
      final resumed = notifierFor(saved: [saved]);
      expect(await resumed.resume(_name), DotkResumeNeed.none);
      expect(resumed.entry(_name)?.stage, DotkRegistrationStage.done);
    });

    test('a node error changes nothing', () async {
      final (plan, registration, saved) = await stopped();
      node.offline = true;
      final resumed = notifierFor(saved: [saved]);
      final writes = saves.length;
      expect(await resumed.resume(_name), DotkResumeNeed.unanswered);
      expect(resumed.entry(_name)?.failure, saved.failure);
      expect(saves.length, writes);
      expect(await resumed.isDismissSafe(_name), isFalse);

      // While following, it is retried
      final notifier = notifierFor(
        saved: [saved.copyWith(stage: .waiting, clearFailure: true)],
      );
      await notifier.resumeAll();
      await _polls(node);
      expect(notifier.entry(_name)?.failure, isNull);
      node.offline = false;
      mineSplit(plan, registration);
      await until(
        () => notifier.entry(_name)?.stage == DotkRegistrationStage.activating,
      );
    });

    test('resumeAll goes on with a failed entry, or releases it', () async {
      final (plan, registration, saved) = await stopped();
      mineSplit(plan, registration);
      final resumed = notifierFor(saved: [saved]);
      await resumed.resumeAll();
      await until(
        () => resumed.entry(_name)?.stage == DotkRegistrationStage.activating,
      );
      resumed.dispose();
      notifiers.remove(resumed);

      // Evicted while it stood failed: the reserved change is released
      node.utxos.removeWhere((u) => u.outpoint == plan.build.pending.outpoint);
      final failed = saved.copyWith(
        pendingSeenAt: 1,
        pendingDaaScore: 1000,
        failure: .error,
        clearActivate: true,
      );
      final evicted = notifierFor(saved: [failed]);
      expect(reserved, contains(registration.reservedOutpoint));
      await evicted.resumeAll();
      await until(
        () => evicted.entry(_name)?.failure == DotkRegistrationFailure.evicted,
      );
      expect(reserved, isEmpty);
    });
  });

  test('reserved coins are kept until dismissed, and not spent by a second '
      'registration', () async {
    final second = registryUtxo(
      _alice.encoded,
      Outpoint(transactionId: 'dd' * 32, index: 0),
      kSompiPerKaspa * .from(60),
      payToAddressScript(_alice),
    );
    final (_, registration) = await signed();
    final notifier = notifierFor();
    await notifier.start(registration);
    final both = {funding.outpoint, registration.reservedOutpoint};
    expect(reserved, both);

    // A second plan does not select the reserved funding
    Future<DotkSignedRegistration> other() async => service.signRegistration(
      await service.planRegistration(
        name: 'bobby',
        owner: _alice,
        gapLo: gapLo,
        gapHi: gapHi,
      ),
    );
    await expectLater(other(), throwsA(isA<DotkTxError>()));
    node.utxos.add(second);
    expect(
      {
        for (final input in (await other()).split.inputs.skip(1))
          input.previousOutpoint,
      },
      {second.outpoint},
    );
    notifier.dispose();
    notifiers.remove(notifier);

    // Read back failed, from what was saved
    final saved = saves.last.single.copyWith(
      stage: .failed,
      failure: .notConfirmed,
    );
    reserved = {};
    var hold = true;
    final failed = notifierFor(saved: [saved], holdFailed: () => hold);
    expect(reserved, both);

    // With .k names off nothing offers to resume it, so the coins go back
    hold = false;
    failed.publishReserved();
    expect(reserved, isEmpty);
    hold = true;
    failed.publishReserved();
    expect(reserved, both);

    await failed.dismiss(_name);
    expect(reserved, isEmpty);
  });

  test('a stop is reported once, unless its sheet is on screen', () async {
    final (_, registration) = await signed();
    node.refuse = (_) => refusal('transaction 6f0a is not standard: x');

    final notifier = notifierFor();
    // The confirm sheet and the progress sheet hold it at once
    final confirm = notifier.onScreen(_name);
    final progress = notifier.onScreen(_name);
    await notifier.start(registration);
    expect(notifier.entry(_name)?.stage, DotkRegistrationStage.failed);
    confirm();
    expect(notifier.takeNewFailures(), isEmpty);
    progress();

    await notifier.dismiss(_name);
    await notifier.start(registration);
    expect(notifier.takeNewFailures(), [_name]);
    expect(notifier.takeNewFailures(), isEmpty);
  });

  test('time left counts DAA from the PENDING deed', () {
    final entry = DotkRegistrationEntry(
      name: _name,
      owner: _alice.encoded,
      splitTxId: '00' * 32,
      startedAt: 0,
      pendingSeenAt: DateTime.now().millisecondsSinceEpoch,
      pendingDaaScore: 1000,
      stage: .waiting,
    );
    final notifier = notifierFor(saved: [entry]);
    virtualDaaScore = .from(2000);
    // 2,000 DAA left at ten a second
    expect(notifier.timeLeft(_name), const Duration(seconds: 200));
    expect(notifier.minutesLeft(_name), 4);
    virtualDaaScore = .from(4001);
    expect(notifier.timeLeft(_name), Duration.zero);
    expect(notifier.minutesLeft(_name), 0);
    // Without a DAA score, from when the deed was seen
    virtualDaaScore = null;
    expect(notifier.minutesLeft(_name), 5);
  });
}
