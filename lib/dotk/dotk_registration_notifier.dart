import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../kaspa/kaspa.dart';
import 'dotk_reject.dart';
import 'dotk_service.dart';
import 'dotk_tx.dart';
import 'dotk_tx_codec.dart';
import 'dotk_tx_service.dart';

/// Where a registration stands. done: the node holds the active deed.
enum DotkRegistrationStage { reserving, waiting, activating, done, failed }

/// notConfirmed: the reservation was not mined within the wait, and may
/// still be. dropped: it can never be mined, as its funding is spent
/// elsewhere, and nothing was spent on it. raced: another reservation spent
/// the same gap first, and nothing was spent. evicted: the reservation
/// expired and was evicted, so the deposit is lost. taken: the node holds
/// neither deed of this registration nor its reservation, and the indexer
/// lists the name as registered.
enum DotkRegistrationFailure {
  notConfirmed,
  dropped,
  raced,
  evicted,
  taken,
  error,
}

/// One registration the wallet started. It is saved before the reservation is
/// sent, so a restart can finish it.
class DotkRegistrationEntry {
  final String name;
  final String owner;
  final String splitTxId;

  /// The signed reservation, kept until it is mined so it can be sent again
  final Map<String, Object?>? split;

  /// The signed activation, which spends the reservation's change
  final Map<String, Object?>? activate;

  /// The activation fee the user agreed to, in sompi, which caps a raise
  final int? approvedFee;
  final int startedAt;
  final int? pendingSeenAt;
  final int? pendingDaaScore;
  final DotkRegistrationStage stage;
  final DotkRegistrationFailure? failure;

  const DotkRegistrationEntry({
    required this.name,
    required this.owner,
    required this.splitTxId,
    required this.startedAt,
    this.split,
    this.activate,
    this.approvedFee,
    this.pendingSeenAt,
    this.pendingDaaScore,
    this.stage = .reserving,
    this.failure,
  });

  RawTransaction? get splitTx =>
      split == null ? null : DotkTxCodec.fromJson(split!);

  RawTransaction? get activateTx =>
      activate == null ? null : DotkTxCodec.fromJson(activate!);

  /// The wallet's own outpoints this registration spends, which a normal send
  /// must not spend: the activation's funding, the reservation's funding
  /// until it is mined, and the reservation's change
  Set<Outpoint> get reservedOutpoints {
    Iterable<Outpoint> fundingOf(RawTransaction? tx) =>
        (tx?.inputs ?? const <RawInput>[])
            .where((input) => input.utxoEntry.covenantId == null)
            .map((input) => input.previousOutpoint);
    final split = splitTx;
    return {
      ...fundingOf(activateTx),
      if (pendingSeenAt == null) ...fundingOf(split),
      // The change, which funds the activation and shows the reservation
      // mined after an eviction
      if (split != null)
        for (final (index, output) in split.outputs.indexed)
          if (output.covenant == null)
            Outpoint(transactionId: splitTxId, index: index),
    };
  }

  /// [clearTransactions] and [clearActivate] also release the outpoints the
  /// dropped transactions reserve.
  DotkRegistrationEntry copyWith({
    DotkRegistrationStage? stage,
    DotkRegistrationFailure? failure,
    int? pendingSeenAt,
    int? pendingDaaScore,
    Map<String, Object?>? activate,
    int? approvedFee,
    bool clearFailure = false,
    bool clearActivate = false,
    bool clearTransactions = false,
  }) => DotkRegistrationEntry(
    name: name,
    owner: owner,
    splitTxId: splitTxId,
    startedAt: startedAt,
    split: clearTransactions ? null : split,
    activate: clearTransactions || clearActivate
        ? null
        : activate ?? this.activate,
    approvedFee: approvedFee ?? this.approvedFee,
    pendingSeenAt: pendingSeenAt ?? this.pendingSeenAt,
    pendingDaaScore: pendingDaaScore ?? this.pendingDaaScore,
    stage: stage ?? this.stage,
    failure: clearFailure ? null : failure ?? this.failure,
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'owner': owner,
    'splitTxId': splitTxId,
    'split': split,
    'activate': activate,
    'approvedFee': approvedFee,
    'startedAt': startedAt,
    'pendingSeenAt': pendingSeenAt,
    'pendingDaaScore': pendingDaaScore,
    'stage': stage.name,
    'failure': failure?.name,
  };

  factory DotkRegistrationEntry.fromJson(Map<String, dynamic> json) =>
      DotkRegistrationEntry(
        name: json['name'] as String,
        owner: json['owner'] as String,
        splitTxId: json['splitTxId'] as String,
        split: (json['split'] as Map?)?.cast<String, Object?>(),
        activate: (json['activate'] as Map?)?.cast<String, Object?>(),
        approvedFee: json['approvedFee'] as int?,
        startedAt: json['startedAt'] as int,
        pendingSeenAt: json['pendingSeenAt'] as int?,
        pendingDaaScore: json['pendingDaaScore'] as int?,
        stage: DotkRegistrationStage.values.byName(json['stage'] as String),
        failure: switch (json['failure']) {
          final String failure => DotkRegistrationFailure.values.byName(
            failure,
          ),
          _ => null,
        },
      );
}

/// What [DotkRegistrationNotifier.resume] needs from the UI
enum DotkResumeNeed {
  /// Nothing
  none,

  /// The node or the indexer did not answer, or not for this registry, so
  /// Resume can be tried again
  unanswered,

  /// The activation must be signed again, after the user authenticates
  auth,

  /// A new reservation is needed
  newReservation,

  /// Someone else holds the name now. The entry stays, failed as taken,
  /// until the user dismisses it.
  taken,
}

enum _ActivationSend {
  /// The node holds it, or took it as a replacement
  accepted,

  /// Not taken, but the same activation can go through later
  retry,

  /// The node refused it without a mempool verdict
  unknown,

  refused,
}

/// What the node shows of a reservation that is not mined
enum _SplitFate {
  alive,

  /// It is gone from the mempool, and every input it spends is unspent
  resendable,

  /// Its gap is spent by another transaction
  gapGone,

  /// Its gap is unspent, but some of its funding is spent elsewhere
  fundingGone,

  /// The entry does not hold the reservation, so only the mempool can tell
  unknown,
}

/// Runs the registrations this wallet started on this network: sends the
/// reservation, waits until the node shows it mined, then sends the
/// activation. Only the activation reveals the name, so it is never sent
/// before the reservation is mined.
///
/// Waits count only while the app is in the foreground, see [onBackground].
class DotkRegistrationNotifier extends ChangeNotifier {
  static const kPollInterval = Duration(seconds: 2);
  static const kWaitFor = Duration(minutes: 2);

  /// How soon a reservation or activation the node refused goes out again.
  /// For an activation it is short, since the eviction window is about five
  /// minutes and a refusal cannot wait out [kWaitFor].
  static const kRetryAfter = Duration(seconds: 10);

  /// The eviction window of a reserved deed, in DAA, where the registry is
  /// not known
  static const kEvictAfterDaa = 3000;

  static const kDaaPerSecond = 10;

  /// Node refusals in a row that are not a mempool verdict, after which the
  /// reservation or the activation fails. At [kRetryAfter] apart that is
  /// about twenty seconds, on purpose: the user sees it while the eviction
  /// window has time left.
  static const kMaxUnknownRefusals = 3;

  final DotkTxService? Function() service;
  final DotkService Function() dotk;
  final List<DotkRegistrationEntry> Function() load;
  final Future<void> Function(List<DotkRegistrationEntry>) save;
  final void Function(Set<Outpoint> reserved) onReserved;

  /// Whether a failed registration keeps its funds from normal sends. With
  /// .k names off nothing offers to resume it, so its funds are released.
  final bool Function() holdFailed;

  final BigInt? Function()? virtualDaaScore;

  /// The registry's eviction window, `tEvict`, in DAA
  final int evictAfterDaa;
  final Logger? log;
  final Duration pollInterval;
  final Duration waitFor;
  final Duration retryAfter;

  final _entries = <String, DotkRegistrationEntry>{};
  final _running = <String>{};

  /// Node refusals of a reservation in a row that no verdict explains, and
  /// when the last came
  final _splitUnknowns = <String, ({int count, Duration at})>{};

  /// The funding of an activation being sent before it is saved
  final _sending = <String, Set<Outpoint>>{};

  final _newFailures = <String>{};
  final _onScreen = <String, int>{};
  final _newlyDone = <DotkRegistrationEntry>[];

  /// Runs only while the app is in the foreground, so a wait does not end
  /// while the app cannot reach its node
  final _clock = Stopwatch()..start();
  Completer<void>? _foreground;
  bool _disposed = false;

  DotkRegistrationNotifier({
    required this.service,
    required this.dotk,
    required this.load,
    required this.save,
    required this.onReserved,
    this.holdFailed = _always,
    this.virtualDaaScore,
    this.evictAfterDaa = kEvictAfterDaa,
    this.log,
    this.pollInterval = kPollInterval,
    this.waitFor = kWaitFor,
    this.retryAfter = kRetryAfter,
  }) {
    for (final entry in load()) {
      _entries[entry.name] = entry;
    }
    _publishReserved();
  }

  List<DotkRegistrationEntry> get entries =>
      _entries.values.where((entry) => entry.stage != .done).toList();

  DotkRegistrationEntry? entry(String name) => _entries[name];

  /// The names whose registration stopped since the last call, apart from
  /// those on screen. A stopped registration may need the user before its
  /// reservation is evicted.
  List<String> takeNewFailures() {
    final names = _newFailures.difference(_onScreen.keys.toSet()).toList();
    _newFailures.clear();
    return names;
  }

  /// Marks [name]'s registration as shown to the user, until the returned
  /// callback is called
  void Function() onScreen(String name) {
    _onScreen.update(name, (count) => count + 1, ifAbsent: () => 1);
    return () {
      if (_onScreen.update(name, (count) => count - 1) == 0) {
        _onScreen.remove(name);
      }
    };
  }

  /// The registrations that finished since the last call
  List<DotkRegistrationEntry> takeNewlyDone() {
    final done = _newlyDone.toList();
    _newlyDone.clear();
    return done;
  }

  bool isRunning(String name) => _running.contains(name);

  bool get _inBackground => _foreground != null;

  /// Stops every wait and every node call until [onForeground]. The node
  /// connection closes in the background.
  void onBackground() {
    if (_foreground != null) {
      return;
    }
    _clock.stop();
    _foreground = Completer<void>();
  }

  /// Goes on with the waits [onBackground] stopped
  void onForeground() {
    final foreground = _foreground;
    if (foreground == null) {
      return;
    }
    _foreground = null;
    _clock.start();
    foreground.complete();
    unawaited(resumeAll());
  }

  /// Picks up every saved registration that can go on without the user. A
  /// failed one goes on only where the node holds its PENDING deed and the
  /// entry holds an activation, or is classified again where it still holds
  /// its reservation.
  Future<void> resumeAll() async {
    for (final entry in entries.toList()) {
      if (_disposed || _inBackground) return;
      if (_running.contains(entry.name)) continue;
      if (entry.stage != .failed) {
        unawaited(_run(entry.name));
        continue;
      }
      // A failed entry without its transactions has nothing left to finish
      if (entry.split != null) {
        // Classifies an eviction or a race, which releases the reserved
        // change
        unawaited(resume(entry.name));
      }
    }
  }

  /// Saves [signed], reserves its outpoints and sends the reservation. The
  /// rest runs in the background.
  Future<void> start(DotkSignedRegistration signed) async {
    final service = this.service();
    if (service == null) {
      throw const DotkTxError('This network has no registry');
    }
    final name = signed.name;
    final existing = _entries[name];
    if (existing != null && existing.stage != .done) {
      throw DotkTxError('A registration of $name is already under way');
    }
    _splitUnknowns.remove(name);
    final entry = DotkRegistrationEntry(
      name: name,
      owner: signed.owner.encoded,
      splitTxId: signed.splitTxId,
      split: DotkTxCodec.toJson(signed.split),
      activate: DotkTxCodec.toJson(signed.activate),
      approvedFee: signed.activate.fee.toInt(),
      startedAt: DateTime.now().millisecondsSinceEpoch,
    );
    // Nothing is sent unless the entry is saved, so a restart can finish it
    try {
      await _put(entry);
    } catch (_) {
      _entries.remove(name);
      _publishReserved();
      _notify();
      rethrow;
    }

    _running.add(name);
    DotkRegistrationEntry? sent;
    try {
      sent = await _sendSplit(service, entry);
    } catch (e) {
      // Not a refusal, so the node may hold it. The runner sends it again.
      log?.w('Reservation of $name not sent', error: e);
      sent = entry;
    } finally {
      _running.remove(name);
    }
    if (sent != null && sent.stage != .failed) {
      unawaited(_run(name));
    }
  }

  /// Goes on with a registration that stopped. Says what the UI must do
  /// first when the wallet cannot go on by itself, and throws the
  /// [DotkTxError] that stopped a new activation.
  Future<DotkResumeNeed> resume(String name, {bool signed = false}) async {
    final entry = _entries[name];
    final service = this.service();
    if (entry == null ||
        service == null ||
        _disposed ||
        entry.stage == .done ||
        !_running.add(name)) {
      return .none;
    }
    // The name stays held until the entry is written, so a runner that
    // starts meanwhile cannot change it
    var run = false;
    try {
      final DotkResumeNeed need;
      (need, run) = await _resume(service, name, signed: signed);
      return need;
    } on DotkTxError {
      rethrow;
    } catch (e, st) {
      // The node or the indexer did not answer, which proves nothing
      log?.w('Failed to resume $name', error: e, stackTrace: st);
      return .unanswered;
    } finally {
      _running.remove(name);
      if (run) {
        unawaited(_run(name));
      }
    }
  }

  /// What [resume] answers, and whether a runner goes on with the entry
  Future<(DotkResumeNeed, bool)> _resume(
    DotkTxService service,
    String name, {
    required bool signed,
  }) async {
    const nothing = (DotkResumeNeed.none, false);
    final owner = Address.decodeAddress(_entries[name]!.owner);

    Future<(DotkResumeNeed, bool)> active() async {
      final entry = _entries[name];
      if (entry != null) {
        await _update(entry.copyWith(stage: .done, clearFailure: true));
      }
      return nothing;
    }

    if (await service.activeDeed(name: name, owner: owner) != null) {
      return active();
    }
    final pending = await service.pendingDeed(name: name, owner: owner);
    var entry = _entries[name];
    if (entry == null || _disposed) {
      return nothing;
    }

    if (pending != null) {
      entry = _seen(entry, pending);
      if (entry.activate == null) {
        if (!signed) {
          await _update(entry);
          return (DotkResumeNeed.auth, false);
        }
        final RawTransaction activate;
        try {
          activate = await service.signActivation(
            name: name,
            owner: owner,
            preferred: await _splitChange(service, entry),
          );
        } on DotkStaleError {
          rethrow;
        } on DotkTxError catch (e) {
          log?.w('Activation of $name not signed again', error: e);
          await _update(entry.copyWith(stage: .failed, failure: .error));
          rethrow;
        }
        entry = entry.copyWith(
          activate: DotkTxCodec.toJson(activate),
          approvedFee: activate.fee.toInt(),
        );
      }
      final stage = entry.stage == .activating
          ? DotkRegistrationStage.activating
          : DotkRegistrationStage.waiting;
      final updated = await _update(
        entry.copyWith(stage: stage, clearFailure: true),
      );
      return (DotkResumeNeed.none, updated);
    }

    // Neither deed on the node. An activation mined between the two reads
    // shows now.
    if (await service.activeDeed(name: name, owner: owner) != null) {
      return active();
    }

    if (await _mined(service, entry)) {
      // Read once more, so a gap in the node's index is not an eviction
      if (await service.pendingDeed(name: name, owner: owner) != null) {
        return _resume(service, name, signed: signed);
      }
      await _update(
        entry.copyWith(
          stage: .failed,
          failure: .evicted,
          clearTransactions: true,
        ),
      );
      final key = await dotk().keyInfo(name);
      if (key != null &&
          key.registryCovenantId != service.registry.covenantId) {
        return (DotkResumeNeed.unanswered, false);
      }
      return (
        key != null && key.free
            ? DotkResumeNeed.newReservation
            : DotkResumeNeed.taken,
        false,
      );
    }

    switch (await _splitFate(service, entry)) {
      case .alive:
        final updated = await _update(
          entry.copyWith(stage: .waiting, clearFailure: true),
        );
        return (DotkResumeNeed.none, updated);
      case .resendable:
        final updated = await _update(
          entry.copyWith(stage: .reserving, clearFailure: true),
        );
        return (DotkResumeNeed.none, updated);
      case .fundingGone:
        await _update(
          entry.copyWith(
            stage: .failed,
            failure: .dropped,
            clearTransactions: true,
          ),
        );
        return (DotkResumeNeed.newReservation, false);
      case .gapGone:
        // The reservation may have been mined since the first read
        if (await service.pendingDeed(name: name, owner: owner) != null) {
          return _resume(service, name, signed: signed);
        }
      case .unknown:
        if ((entry.stage == .reserving || entry.stage == .waiting) &&
            _sinceStart(entry) < waitFor) {
          return (DotkResumeNeed.none, true);
        }
    }

    // The node proves the reservation is gone and was never mined, so what
    // the indexer serves decides between a new reservation and a taken name
    final key = await dotk().keyInfo(name);
    if (key != null && key.registryCovenantId != service.registry.covenantId) {
      log?.w('The indexer serves another registry for $name');
      return (DotkResumeNeed.unanswered, false);
    }
    entry = _entries[name];
    if (entry == null) {
      return nothing;
    }
    if (key == null || !key.free) {
      // The indexer may list this registration's own active deed
      if (await service.activeDeed(name: name, owner: owner) != null) {
        return active();
      }
      await _update(
        entry.copyWith(
          stage: .failed,
          failure: .taken,
          clearTransactions: true,
        ),
      );
      return (DotkResumeNeed.taken, false);
    }
    await _update(
      entry.copyWith(stage: .failed, failure: .raced, clearTransactions: true),
    );
    return (DotkResumeNeed.newReservation, false);
  }

  /// Whether dropping the registration loses nothing: false while the node
  /// holds its PENDING deed or its reservation is in the mempool, and when
  /// the node does not answer
  Future<bool> isDismissSafe(String name) async {
    final entry = _entries[name];
    if (entry == null || entry.stage == .done) {
      return true;
    }
    final service = this.service();
    if (service == null) {
      return true;
    }
    try {
      final owner = Address.decodeAddress(entry.owner);
      if (await service.pendingDeed(name: name, owner: owner) != null) {
        return false;
      }
      return await _splitFate(service, entry) != .alive;
    } catch (e) {
      log?.w('Node query failed while checking $name', error: e);
      return false;
    }
  }

  /// Drops a registration from the list. The outpoints it reserved are
  /// released. See [isDismissSafe] first.
  Future<void> dismiss(String name) async {
    _splitUnknowns.remove(name);
    if (_entries.remove(name) != null) {
      await _persist();
    }
  }

  /// The time left before an unfinished reservation can be evicted, or null
  /// before the node shows it
  Duration? timeLeft(String name) {
    final entry = _entries[name];
    final seen = entry?.pendingSeenAt;
    if (entry == null || seen == null) {
      return null;
    }
    final window = _window;
    final mined = entry.pendingDaaScore;
    final virtual = virtualDaaScore?.call();
    final Duration left;
    if (mined != null && virtual != null && virtual > BigInt.zero) {
      final daaLeft = BigInt.from(mined + evictAfterDaa) - virtual;
      left = Duration(
        milliseconds:
            (daaLeft * BigInt.from(1000) ~/ BigInt.from(kDaaPerSecond)).toInt(),
      );
    } else {
      left = DateTime.fromMillisecondsSinceEpoch(
        seen,
      ).add(window).difference(DateTime.now());
    }
    if (left.isNegative) return Duration.zero;
    return left > window ? window : left;
  }

  /// [timeLeft] in whole minutes, rounded up so it never reads 0 while time
  /// is left
  int? minutesLeft(String name) {
    final left = timeLeft(name);
    return left == null ? null : (left.inSeconds + 59) ~/ 60;
  }

  Future<void> _run(String name) async {
    if (_disposed || !_running.add(name)) {
      return;
    }
    _notify();
    try {
      await _follow(name);
    } finally {
      _running.remove(name);
      _notify();
    }
  }

  Future<void> _follow(String name) async {
    final initial = _entries[name];
    if (initial == null || initial.stage == .done || initial.stage == .failed) {
      return;
    }
    var entry = initial;
    final owner = Address.decodeAddress(entry.owner);
    var until = _deadline();
    // Polls in a row that found the reservation mined and its deed gone. Two
    // are needed, so a gap in the node's index is not read as an eviction.
    var absences = 0;
    var first = true;

    Future<void> fail(
      DotkRegistrationFailure failure, {
      Object? error,
      bool clearActivate = false,
      bool clearTransactions = false,
    }) {
      if (error != null) {
        log?.w('Registration of $name stopped', error: error);
      }
      return _update(
        entry.copyWith(
          stage: .failed,
          failure: failure,
          clearActivate: clearActivate,
          clearTransactions: clearTransactions,
        ),
      );
    }

    while (entry.stage == .reserving || entry.stage == .waiting) {
      if (!await _awake(name)) return;
      final service = this.service();
      if (service == null) return;
      try {
        if (entry.stage == .reserving) {
          final sent = await _sendSplit(service, entry);
          if (sent == null || sent.stage == .failed) return;
          entry = sent;
        }
        final pending = await service.pendingDeed(name: name, owner: owner);
        if (_gone(name)) return;
        if (pending != null) {
          entry = _seen(entry, pending);
          if (!await _update(entry)) return;
          break;
        }
        if (await service.activeDeed(name: name, owner: owner) != null) {
          await _update(entry.copyWith(stage: .done, clearFailure: true));
          return;
        }
        final expired = _clock.elapsed > until;
        // The first poll looks too, for an eviction while the app was closed
        if (entry.pendingSeenAt != null || expired || first) {
          if (await _mined(service, entry)) {
            if (++absences >= 2) {
              await fail(.evicted, clearTransactions: true);
              return;
            }
          } else if (expired) {
            absences = 0;
            switch (await _splitFate(service, entry)) {
              case .alive:
                until = _deadline();
              case .resendable:
                entry = entry.copyWith(stage: .reserving);
                if (!await _update(entry)) return;
                until = _deadline();
              case .gapGone:
                // The reservation may have been mined since the first read
                if (await service.pendingDeed(name: name, owner: owner) ==
                    null) {
                  await fail(.raced, clearTransactions: true);
                  return;
                }
              case .fundingGone:
                await fail(.dropped, clearTransactions: true);
                return;
              case .unknown:
                await fail(.notConfirmed);
                return;
            }
          }
        }
      } catch (e) {
        log?.w('Node query failed while registering $name', error: e);
      }
      first = false;
      if (_gone(name)) return;
      await Future<void>.delayed(pollInterval);
    }

    // Send the activation, which reveals the name, and wait for the active
    // deed. While the PENDING deed stands there is no time limit: the
    // activation goes out again after each wait, and past half of the
    // eviction window it is signed again at a higher fee.
    var sent = false;
    var bumped = false;
    var bumpAt = Duration.zero;
    var unknowns = 0;
    until = _deadline();
    absences = 0;
    while (true) {
      if (!await _awake(name)) return;
      final service = this.service();
      if (service == null) return;
      try {
        if (await service.activeDeed(name: name, owner: owner) != null) {
          await _update(entry.copyWith(stage: .done, clearFailure: true));
          return;
        }
        if (await service.pendingDeed(name: name, owner: owner) == null) {
          // An activation mined between the reads shows now
          if (await service.activeDeed(name: name, owner: owner) != null) {
            await _update(entry.copyWith(stage: .done, clearFailure: true));
            return;
          }
          if (!await _mined(service, entry)) {
            // The reservation is not mined any more, after a
            // reorganization, so wait for it again
            entry = entry.copyWith(stage: .waiting);
            if (!await _update(entry)) return;
            return _follow(name);
          }
          if (++absences >= 2) {
            await fail(.evicted, clearTransactions: true);
            return;
          }
        } else {
          absences = 0;
          if (_gone(name)) return;
          final activate = entry.activateTx;
          if (activate == null) {
            // A new activation needs the key, see resume
            await fail(.error, error: 'The activation must be signed again');
            return;
          }
          if (!bumped && _clock.elapsed >= bumpAt && _lateInWindow(name)) {
            bumpAt = _clock.elapsed + waitFor;
            final next = await _bump(service, entry, activate);
            if (next != null) {
              entry = next;
              bumped = true;
              sent = true;
              unknowns = 0;
              until = _deadline();
            }
          }
          if (_clock.elapsed > until) {
            // Not mined yet. The node may have dropped it, so send it again.
            sent = false;
          }
          if (!sent) {
            // Also where the send throws, so it is not repeated every poll
            sent = true;
            until = _clock.elapsed + retryAfter;
            final (result, error) = await _submitActivation(
              service,
              name,
              activate,
            );
            if (_gone(name)) return;
            if (result == .accepted) until = _deadline();
            switch (result) {
              case .accepted:
                unknowns = 0;
                entry = entry.copyWith(stage: .activating);
                if (!await _update(entry)) return;
              case .retry:
                unknowns = 0;
              case .unknown:
                if (++unknowns >= kMaxUnknownRefusals) {
                  await fail(.error, error: error);
                  return;
                }
              case .refused:
                // It may have been mined while the refusal came back
                if (await service.activeDeed(name: name, owner: owner) !=
                    null) {
                  await _update(
                    entry.copyWith(stage: .done, clearFailure: true),
                  );
                  return;
                }
                await fail(.error, error: error, clearActivate: true);
                return;
            }
          }
        }
      } catch (e) {
        log?.w('Node query failed while activating $name', error: e);
      }
      if (_gone(name)) return;
      await Future<void>.delayed(pollInterval);
    }
  }

  int _countSplitRefusal(String name) {
    final count = (_splitUnknowns[name]?.count ?? 0) + 1;
    _splitUnknowns[name] = (count: count, at: _clock.elapsed);
    return count;
  }

  /// Sends the reservation. Answers the entry as it stands after, or null
  /// once it is gone. Throws what is not the node's refusal.
  Future<DotkRegistrationEntry?> _sendSplit(
    DotkTxService service,
    DotkRegistrationEntry entry,
  ) async {
    final split = entry.splitTx;
    // A refusal without a verdict is sent again only [retryAfter] later
    final refused = _splitUnknowns[entry.name]?.at;
    if (refused != null && _clock.elapsed - refused < retryAfter) {
      return entry;
    }
    if (split != null) {
      try {
        await service.submitTransaction(split);
        _splitUnknowns.remove(entry.name);
      } catch (e) {
        if (!DotkReject.isDuplicate(e)) {
          final verdict = DotkReject.classify(e);
          // A node refusal without a verdict is tried a few times only
          final unknowns = verdict == .unknown && e is RpcException
              ? _countSplitRefusal(entry.name)
              : 0;
          if ((verdict == .transient || verdict == .unknown) &&
              unknowns < kMaxUnknownRefusals) {
            log?.w('Reservation of ${entry.name} not taken yet', error: e);
            return entry;
          }
          _splitUnknowns.remove(entry.name);
          log?.w('Reservation of ${entry.name} refused', error: e);
          final raced =
              verdict == .stale &&
              DotkReject.spends(e, split.inputs.first.previousOutpoint);
          final failed = entry.copyWith(
            stage: .failed,
            failure: raced ? .raced : .error,
            clearTransactions: true,
          );
          return await _update(failed) ? failed : null;
        }
      }
    }
    final waiting = entry.copyWith(stage: .waiting);
    return await _update(waiting) ? waiting : null;
  }

  /// Sends [activate], and answers the refusal where there is one. Throws
  /// only where the funding cannot be read after a refusal.
  Future<(_ActivationSend, Object?)> _submitActivation(
    DotkTxService service,
    String name,
    RawTransaction activate,
  ) async {
    try {
      await service.submitTransaction(activate);
      return (_ActivationSend.accepted, null);
    } catch (e) {
      if (DotkReject.isDuplicate(e)) {
        return (_ActivationSend.accepted, null);
      }
      log?.w('Activation of $name refused', error: e);
      final verdict = DotkReject.classify(e);
      final pending = activate.inputs.first.previousOutpoint;
      if (verdict == .stale && DotkReject.spends(e, pending)) {
        // The mempool holds another spend of the PENDING deed: an
        // activation sent before, or an eviction. This one replaces it
        // where it pays more, and otherwise the wait goes on.
        try {
          await service.submitReplacement(activate);
          return (_ActivationSend.accepted, null);
        } catch (e) {
          log?.w('Activation of $name not replaced', error: e);
          return (_ActivationSend.retry, e);
        }
      }
      if (verdict == .transient || verdict == .unknown) {
        // A funding input spent elsewhere never comes back
        final funding = activate.inputs
            .where((input) => input.utxoEntry.covenantId == null)
            .toList();
        final unspent = await service.unspent(funding);
        if (unspent.length == funding.length) {
          // A transport error says nothing about the activation
          final refused = verdict == .unknown && e is RpcException;
          return (
            refused ? _ActivationSend.unknown : _ActivationSend.retry,
            e,
          );
        }
      }
      return (_ActivationSend.refused, e);
    }
  }

  /// Signs the activation again at the priority feerate and sends it. The
  /// entry keeps [previous] until the node takes the new one. Answers the
  /// entry with the new one, or null where it stays as it was.
  Future<DotkRegistrationEntry?> _bump(
    DotkTxService service,
    DotkRegistrationEntry entry,
    RawTransaction previous,
  ) async {
    final name = entry.name;
    // The user agreed to a fee, so the wallet pays at most a little more
    // without asking, however often it raises
    final fee = switch (entry.approvedFee) {
      final approved? => BigInt.from(approved),
      null => previous.fee,
    };
    final doubled = fee * BigInt.two;
    final raised = fee + DotkTxService.feeRiseLimit(fee);
    try {
      final activate = await service.signActivation(
        name: name,
        owner: Address.decodeAddress(entry.owner),
        preferred: await _splitChange(service, entry),
        priority: true,
        maxFee: doubled > raised ? doubled : raised,
      );
      _sending[name] = {
        for (final input in activate.inputs)
          if (input.utxoEntry.covenantId == null) input.previousOutpoint,
      };
      _publishReserved();
      final (result, _) = await _submitActivation(service, name, activate);
      if (result != .accepted) {
        return null;
      }
      final next = entry.copyWith(
        stage: .activating,
        activate: DotkTxCodec.toJson(activate),
      );
      return await _update(next) ? next : null;
    } catch (e) {
      log?.w('Activation of $name not signed again', error: e);
      return null;
    } finally {
      if (_sending.remove(name) != null) {
        _publishReserved();
      }
    }
  }

  /// Whether the node shows the reservation mined: one of its outputs is
  /// unspent. The change stays reserved, so it stays unspent until the
  /// activation spends it. Without the reservation, whether the wallet saw
  /// its PENDING deed.
  Future<bool> _mined(
    DotkTxService service,
    DotkRegistrationEntry entry,
  ) async {
    final split = entry.splitTx;
    if (split == null) {
      return entry.pendingSeenAt != null;
    }
    return (await service.unspentOutputs(split)).isNotEmpty;
  }

  /// The reservation's change, where the node still holds it, which funds a
  /// new activation before any other coin
  Future<List<Utxo>> _splitChange(
    DotkTxService service,
    DotkRegistrationEntry entry,
  ) async {
    final split = entry.splitTx;
    if (split == null) {
      return const [];
    }
    return [
      for (final utxo in await service.unspentOutputs(split))
        if (utxo.utxoEntry.covenantId == null) utxo,
    ];
  }

  bool _lateInWindow(String name) {
    final left = timeLeft(name);
    return left != null && left * 2 <= _window;
  }

  Duration get _window =>
      Duration(milliseconds: evictAfterDaa * 1000 ~/ kDaaPerSecond);

  Future<_SplitFate> _splitFate(
    DotkTxService service,
    DotkRegistrationEntry entry,
  ) async {
    final split = entry.splitTx;
    final owner = Address.decodeAddress(entry.owner);
    final addresses = {
      service.pendingDeedAddress(name: entry.name, owner: owner),
      if (split != null) split.inputs.first.address.encoded,
    };
    if (await service.inMempool(entry.splitTxId, addresses)) {
      return .alive;
    }
    if (split == null) {
      return .unknown;
    }
    final unspent = await service.unspent(split.inputs);
    if (!unspent.contains(split.inputs.first.previousOutpoint)) {
      return .gapGone;
    }
    return unspent.length == split.inputs.length ? .resendable : .fundingGone;
  }

  /// A reservation the node shows is past the reserve step, however its
  /// sending ended
  DotkRegistrationEntry _seen(DotkRegistrationEntry entry, Utxo pending) =>
      entry.copyWith(
        stage: entry.stage == .reserving ? .waiting : null,
        pendingSeenAt:
            entry.pendingSeenAt ?? DateTime.now().millisecondsSinceEpoch,
        pendingDaaScore: pending.utxoEntry.blockDaaScore.toInt(),
      );

  Duration _deadline() => _clock.elapsed + waitFor;

  /// Waits while the app is in the background. False once [name] is
  /// dismissed or the notifier is disposed.
  Future<bool> _awake(String name) async {
    while (_foreground != null && !_disposed) {
      await _foreground!.future;
    }
    return !_gone(name);
  }

  bool _gone(String name) => _disposed || !_entries.containsKey(name);

  Duration _sinceStart(DotkRegistrationEntry entry) => DateTime.now()
      .difference(DateTime.fromMillisecondsSinceEpoch(entry.startedAt));

  /// Writes [entry] only while its registration is still listed, so a step
  /// that ends after a dismiss does not bring it back. False where nothing
  /// was written.
  Future<bool> _update(DotkRegistrationEntry entry) async {
    if (_gone(entry.name)) {
      return false;
    }
    await _put(entry);
    return true;
  }

  Future<void> _put(DotkRegistrationEntry entry) async {
    if (_disposed) return;
    final before = _entries[entry.name]?.stage;
    if (entry.stage == .failed && before != .failed) {
      _newFailures.add(entry.name);
    }
    if (entry.stage == .done && before != .done) {
      _newlyDone.add(entry);
    }
    _entries[entry.name] = entry;
    await _persist();
  }

  Future<void> _persist() async {
    if (_disposed) return;
    _publishReserved();
    _notify();
    await save(entries);
  }

  static bool _always() => true;

  void publishReserved() => _publishReserved();

  void _publishReserved() {
    if (_disposed) return;
    final holdFailed = this.holdFailed();
    onReserved({
      for (final entry in _entries.values)
        if (entry.stage != .done && (holdFailed || entry.stage != .failed))
          ...entry.reservedOutpoints,
      for (final funding in _sending.values) ...funding,
    });
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final foreground = _foreground;
    _foreground = null;
    foreground?.complete();
    super.dispose();
  }
}
