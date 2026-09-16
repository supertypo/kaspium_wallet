import 'dart:async';

import 'package:logger/logger.dart';

import '../kaspa/types/address.dart';
import '../kaspa/types/address_prefix.dart';
import 'dotk_names.dart';
import 'dotk_service.dart';
import 'dotk_types.dart';

/// Resolves the `.k` name a text field holds while the user types. The last
/// result is forgotten as soon as the field no longer holds that name, and
/// nothing here throws: every outcome arrives as a [DotkLookup].
class DotkNameResolver {
  static const kDebounce = Duration(milliseconds: 400);

  static const kTimeout = Duration(seconds: 10);

  final DotkService Function() service;
  final AddressPrefix Function() addressPrefix;
  final void Function(String name, DotkLookup? lookup) onLookup;
  final Duration timeout;
  final Logger? log;

  final _lookups = <String, Future<DotkLookup>>{};

  Timer? _debounce;
  String? _name;
  int _generation = 0;
  DotkNameResolution? _resolved;
  bool _disposed = false;

  DotkNameResolver({
    required this.service,
    required this.addressPrefix,
    required this.onLookup,
    this.timeout = kTimeout,
    this.log,
  });

  DotkNameResolution? get resolved => _resolved;

  void textChanged(String text) {
    final name = DotkName.tryNormalize(text);
    if (name != _name) {
      _name = name;
      _resolved = null;
      _generation += 1;
    }

    _debounce?.cancel();
    if (name == null || _disposed) {
      return;
    }

    _debounce = Timer(kDebounce, () => resolve(text));
  }

  /// Resolves [text] now, reusing a lookup already made for the same name
  /// unless [refresh] asks the indexer again. Every caller gets its answer,
  /// but only the newest lookup is reported through [onLookup].
  Future<DotkLookup?> resolve(String text, {bool refresh = false}) async {
    final name = DotkName.tryNormalize(text);
    if (name == null || _disposed) {
      return null;
    }

    _debounce?.cancel();
    if (name != _name) {
      _name = name;
      _resolved = null;
    }
    final generation = ++_generation;

    if (refresh) {
      _lookups.remove(name);
    }
    var lookup = _lookups[name];
    if (lookup == null) {
      onLookup(name, null);
      lookup = _lookup(name);
      _lookups[name] = lookup;
    }

    final result = await lookup;

    // A failure says nothing about the name, so it is not kept: the next
    // attempt, at send time, asks again
    if (result.status == .failed || result.status == .unavailable) {
      _lookups.remove(name);
    }

    if (_disposed) {
      return null;
    }
    if (generation == _generation) {
      _resolved = result.resolution;
      onLookup(name, result);
    }

    return result;
  }

  Future<DotkLookup> _lookup(String name) async {
    final dotk = service();
    if (!dotk.isEnabled) {
      return const DotkLookup.unavailable();
    }

    try {
      final resolution = await dotk.resolveName(name).timeout(timeout);
      if (resolution == null) {
        return const DotkLookup.notRegistered();
      }

      final prefix = addressPrefix();
      if (Address.tryParse(resolution.address, expectedPrefix: prefix) ==
          null) {
        // The indexer answered for another network, so the name cannot be
        // paid from this wallet
        return const DotkLookup.notRegistered();
      }

      return DotkLookup.resolved(resolution);
    } catch (e, st) {
      log?.w(
        'Failed to resolve ${DotkName.display(name)}',
        error: e,
        stackTrace: st,
      );
      return const DotkLookup.failed();
    }
  }

  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _debounce = null;
    _generation += 1;
    _lookups.clear();
  }
}
