import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import 'dotk_names.dart';
import 'dotk_owned_name.dart';
import 'dotk_proof.dart';
import 'dotk_service.dart';
import 'dotk_types.dart';

/// A name the wallet sent a transaction for, shown until the node sees it
class DotkNameInFlight {
  final DotkOwnedName name;

  /// What the row says instead of the owner, like the new owner's name
  final String target;

  const DotkNameInFlight(this.name, this.target);
}

/// Every name the wallet's addresses own, as the wallet's node proves them.
/// Addresses are checked a few at a time, so rows appear as answers land.
class DotkWalletNamesNotifier extends ChangeNotifier {
  static const kMaxAge = Duration(minutes: 10);
  static const kConcurrency = 4;
  static const kFollowInterval = Duration(seconds: 3);
  static const kFollowFor = Duration(minutes: 3);

  final DotkService service;
  final DotkProver? Function() prover;
  final Iterable<String> Function() addresses;
  final Logger? log;
  final Duration maxAge;
  final Duration followInterval;

  final _owned = <String, List<DotkOwnedName>>{};
  final _failed = <String>{};
  final _inFlight = <String, DotkNameInFlight>{};
  final _awaiting = <String>{};
  final _following = <String, int>{};
  final _awaitLoops = <String>{};

  /// The latest check per address; an older answer never replaces a newer one
  final _generation = <String, int>{};

  List<DotkOwnedName>? _names;
  var _checked = 0;
  var _total = 0;
  var _walletTotal = 0;
  var _scanning = false;
  DateTime? _scannedAt;
  bool _disposed = false;

  DotkWalletNamesNotifier(
    this.service, {
    required this.prover,
    required this.addresses,
    this.log,
    this.maxAge = kMaxAge,
    this.followInterval = kFollowInterval,
  });

  bool get isScanning => _scanning;
  bool get hasScanned => _scannedAt != null;
  int get checked => _checked;
  int get total => _total;

  /// The addresses the last full scan checked, which a retry does not change
  int get walletTotal => _walletTotal;

  /// Addresses the last check got no answer for
  Set<String> get failed => Set.unmodifiable(_failed);

  List<DotkOwnedName> get names => _names ??= List.unmodifiable(
    _owned.values.expand((names) => names).toList()..sort((a, b) {
      final aFirst = a.primary == .winner;
      final bFirst = b.primary == .winner;
      if (aFirst != bFirst) {
        return aFirst ? -1 : 1;
      }
      return DotkName.displayOrder(a.name, b.name);
    }),
  );

  int get addressCount => _owned.length;

  /// Transfers the node does not show yet, by bare name
  Map<String, DotkNameInFlight> get inFlight => Map.unmodifiable(_inFlight);

  /// Whether a change the wallet sent for [name] is still being followed,
  /// so the change is not offered again meanwhile
  bool isFollowing(String name) => _following.containsKey(name);

  /// Whether a change is followed for any name [address] owns
  bool isFollowingAt(String address) =>
      _following.keys.any((name) => ownedName(name)?.address == address);

  /// Names the wallet waits for the indexer to list with settled records,
  /// like one just registered
  Set<String> get awaiting => Set.unmodifiable(_awaiting);

  /// Whether [name] is still polled for, which ends after [kFollowFor]
  bool isPolling(String name) => _awaitLoops.contains(name);

  /// Checks [name]'s owner and [to] until the owner answers without the deed,
  /// then drops the row. A failed check leaves the row in place.
  ///
  /// [mintBlob] is the card the change minted, which is followed until the
  /// indexer lists it: a listing without it is from before the change.
  Future<void> follow(
    DotkOwnedName name, {
    String? to,
    String target = '',
    bool inFlight = true,
    Uint8List? mintBlob,
  }) async {
    // A change that keeps the owner, like a new primary, keeps its row
    final row = inFlight ? DotkNameInFlight(name, target) : null;
    if (row != null) {
      _inFlight[name.name] = row;
    }
    _following.update(name.name, (count) => count + 1, ifAbsent: () => 1);
    _notify();
    try {
      await _follow(name, to: to, mintBlob: mintBlob);
    } finally {
      if (_following.update(name.name, (count) => count - 1) == 0) {
        _following.remove(name.name);
      }
      // A later transfer of the same name has its own row
      if (row != null && identical(_inFlight[name.name], row)) {
        _inFlight.remove(name.name);
      }
      _notify();
    }
  }

  Future<void> _follow(
    DotkOwnedName name, {
    String? to,
    Uint8List? mintBlob,
  }) async {
    // An own address that receives the name is followed until it lists it
    final arriving = to != null && to != name.address && _isOwn(to) ? to : null;
    final until = DateTime.now().add(kFollowFor);
    while (!_disposed && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(followInterval);
      if (_disposed) {
        return;
      }
      final answered = await _rescanNow([name.address, ?to]);
      if (_disposed) {
        return;
      }
      // The node shows the new deed before the indexer serves its card,
      // which reads as unproven until then
      final settling = (_owned[name.address] ?? const []).any(
        (owned) =>
            owned.name == name.name &&
            (owned.deed.outpoint == name.deed.outpoint ||
                owned.recordsState == .unproven ||
                !_hasMint(owned, mintBlob)),
      );
      final holder = arriving ?? name.address;
      if (answered.contains(name.address) &&
          !settling &&
          (arriving == null || _lists(arriving, name.name)) &&
          (_owned[holder] ?? const []).every(
            (owned) => owned.name != name.name || _hasMint(owned, mintBlob),
          )) {
        return;
      }
    }
  }

  static bool _hasMint(DotkOwnedName owned, Uint8List? mintBlob) =>
      mintBlob == null || listEquals(owned.listedCard?.blob, mintBlob);

  /// Checks [address] until it lists [name] with its records settled, as the
  /// indexer does a little after the node shows a new deed
  Future<void> awaitName(String name, String address) async {
    _awaiting.add(name);
    _notify();
    // One loop per name at a time
    if (!_awaitLoops.add(name)) return;
    try {
      await _awaitName(name, address);
    } finally {
      _awaitLoops.remove(name);
      _notify();
    }
  }

  Future<void> _awaitName(String name, String address) async {
    // A slow indexer outlasts the wait, and then the next scan that lists
    // the name ends it
    final until = DateTime.now().add(kFollowFor);
    while (!_disposed && DateTime.now().isBefore(until)) {
      await _rescanNow([address]);
      if (_disposed || !_awaiting.contains(name)) {
        return;
      }
      await Future<void>.delayed(followInterval);
    }
  }

  bool _isOwn(String address) => addresses().contains(address);

  bool _lists(String address, String name) => (_owned[address] ?? const []).any(
    (owned) => owned.name == name && owned.recordsState != .unproven,
  );

  DotkOwnedName? ownedName(String name) =>
      names.where((owned) => owned.name == name).firstOrNull;

  Future<void> refreshIfStale() async {
    final scannedAt = _scannedAt;
    // A name still awaited, and no longer polled, was not listed when its
    // wait ended
    if (_scanning ||
        (_awaiting.difference(_awaitLoops).isEmpty &&
            scannedAt != null &&
            DateTime.now().difference(scannedAt) < maxAge)) {
      return;
    }
    await scan();
  }

  Future<void> scan({bool onlyFailed = false}) async {
    if (_scanning || !service.isEnabled) {
      return;
    }
    final targets = onlyFailed ? _failed.toList() : addresses().toList();
    await _scan(targets, forget: !onlyFailed);
  }

  /// Checks the wallet's addresses among [targets], and returns those whose
  /// check answered. It runs during a scan too, and its answers are not
  /// replaced by the scan's older ones.
  Future<Set<String>> _rescanNow(Iterable<String> targets) async {
    final own = addresses().toSet();
    final answered = <String>{};
    for (final address in targets.where(own.contains).toSet()) {
      if (_disposed) {
        break;
      }
      if (await _check(address)) {
        answered.add(address);
      }
    }
    _notify();
    return answered;
  }

  Future<void> _scan(List<String> targets, {required bool forget}) async {
    _scanning = true;
    _checked = 0;
    _total = targets.length;
    if (forget) {
      _walletTotal = targets.length;
    }
    // Rows from the last scan stay until their address is checked again, so a
    // refresh does not empty the list first
    if (forget) {
      final wanted = targets.toSet();
      _failed.clear();
      _owned.removeWhere((address, _) => !wanted.contains(address));
      _names = null;
    }
    _notify();

    final queue = targets.toList();
    Future<void> worker() async {
      while (queue.isNotEmpty && !_disposed) {
        // In wallet order, so the addresses in use come first
        final address = queue.removeAt(0);
        await _check(address);
        _checked += 1;
        _notify();
      }
    }

    await Future.wait([for (var i = 0; i < kConcurrency; i++) worker()]);

    _scanning = false;
    _scannedAt = DateTime.now();
    _notify();
  }

  /// Asks about [address] and proves its names. True when the answer landed:
  /// false when the lookup failed, a newer check of the address started
  /// meanwhile or the notifier was disposed. A failed lookup keeps the rows
  /// the address had.
  Future<bool> _check(String address) async {
    final generation = (_generation[address] ?? 0) + 1;
    _generation[address] = generation;
    bool current() => !_disposed && _generation[address] == generation;

    try {
      final claim = await service.claimAddress(address);
      if (!current()) {
        return false;
      }
      final owned = claim == null
          ? const <DotkOwnedName>[]
          : await _prove(address, claim);
      if (!current()) {
        return false;
      }
      _failed.remove(address);
      if (owned.isEmpty) {
        _owned.remove(address);
      } else {
        _owned[address] = owned;
      }
      _awaiting.removeWhere((name) => _lists(address, name));
      _names = null;
      return true;
    } catch (e, st) {
      if (!current()) {
        return false;
      }
      log?.w('Failed to look up names for $address', error: e, stackTrace: st);
      _failed.add(address);
      return false;
    }
  }

  Future<List<DotkOwnedName>> _prove(
    String address,
    DotkAddressClaim claim,
  ) async {
    final prover = this.prover();
    if (prover == null) {
      return const [];
    }
    return prover.proveOwned({address: claim}).timeout(DotkService.kTimeout);
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
