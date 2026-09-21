import 'package:retry/retry.dart';

import '../kaspa/api/json_client.dart';
import '../kaspa/types/address.dart';
import '../kaspa/types/address_prefix.dart';
import 'dotk_names.dart';
import 'dotk_subname.dart';
import 'dotk_types.dart';

/// Reads the public `.k` names indexer. Lookups happen while the user waits,
/// so an indexer that is slow or silent gives up early rather than holding
/// anything up.
class DotkService {
  static const kRetryOptions = RetryOptions(
    maxAttempts: 2,
    delayFactor: Duration(milliseconds: 300),
  );

  static const kTimeout = Duration(seconds: 10);

  final JsonClient _client;
  final Duration timeout;

  const DotkService(this._client, {this.timeout = kTimeout});

  DotkService.url(String baseUrl, {this.timeout = kTimeout})
    : _client = _clientForUrl(baseUrl);

  static JsonClient _clientForUrl(String baseUrl) {
    final url = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (url.isEmpty) {
      return VoidJsonClient();
    }
    return JsonClient(url, r: kRetryOptions);
  }

  String get baseUrl => _client.baseUrl;

  bool get isEnabled => _client is! VoidJsonClient;

  /// The address [target] resolves to, or null when it cannot be paid. A name
  /// answers with its owner's address, and a subname with the payee its
  /// parent's card names for the label. Either may be free, still registering,
  /// owned by a covenant or malformed.
  Future<DotkNameResolution?> resolveName(String target) async {
    final (parent, label) = DotkName.splitTarget(target);
    // The parent becomes a path segment below, so the charset rule holds here
    // whatever the caller already checked
    if (!DotkName.isValid(parent)) {
      return null;
    }
    if (label != null &&
        (parent == DotkName.suffixSegment || !DotkName.isValidLabel(label))) {
      return null;
    }

    final path = '/names/$parent';
    final Object? result;
    try {
      result = await _client.get(path).timeout(timeout);
    } on ApiException catch (e) {
      if (e.statusCode == 404 || e.statusCode == 400) {
        return null;
      }
      rethrow;
    }

    final json = _object(result, path);
    final address = json['address'];
    if (address == null) {
      // A covenant owns the name, so there is nothing to pay
      return null;
    }
    if (address is! String || address.isEmpty) {
      throw FormatException('Unexpected address for $path: $address');
    }
    if (label == null) {
      return DotkNameResolution.forName(parent, address: address);
    }

    return _payee(json, path, target: target, label: label, owner: address);
  }

  /// The payee one label names on the parent's live card. The address is
  /// rendered under the prefix the parent's own address carries
  DotkNameResolution? _payee(
    Map<String, Object?> json,
    String path, {
    required String target,
    required String label,
    required String owner,
  }) {
    final card = json['card'];
    if (card == null) {
      return null;
    }
    if (card is! Map<String, Object?>) {
      throw FormatException('Unexpected card for $path: $card');
    }
    if (card['live'] != true) {
      throw FormatException('Unexpected card for $path: it is not live');
    }
    final records = card['records'];
    if (records is! Map<String, Object?>?) {
      throw FormatException('Unexpected records for $path: $records');
    }
    if (records == null) {
      return null;
    }
    final prefix = Address.tryParse(owner, expectedPrefix: .unknown)?.prefix;
    if (prefix == null || prefix == AddressPrefix.unknown) {
      throw FormatException('Unexpected address for $path: $owner');
    }

    final payee = DotkSubname.payee(
      records[DotkSubname.recordKey(label)],
      prefix,
    );

    return payee == null
        ? null
        : DotkNameResolution.forName(target, address: payee);
  }

  /// The bare names [address] owns, primary name first
  Future<List<String>> namesForAddress(String address) async {
    final path = '/addresses/$address';
    final Object? result;
    try {
      result = await _client.get(path).timeout(timeout);
    } on ApiException catch (e) {
      if (e.statusCode == 400) {
        return const [];
      }
      rethrow;
    }

    final json = _object(result, path);
    final names = _names(json['names'], path);
    if (names.isEmpty) {
      return names;
    }

    names.sort(DotkName.displayOrder);

    final primary = _primaryName(json['cards'], path);
    if (primary != null && names.remove(primary)) {
      names.insert(0, primary);
    }

    return names;
  }

  Future<String?> displayNameForAddress(String address) async {
    final names = await namesForAddress(address);
    if (names.isEmpty) {
      return null;
    }

    return DotkName.display(names.first);
  }

  Map<String, Object?> _object(Object? value, String path) {
    if (value is! Map<String, Object?>) {
      throw FormatException('Unexpected response for $path: $value');
    }
    return value;
  }

  List<String> _names(Object? value, String path) {
    if (value == null) {
      return [];
    }
    if (value is! List) {
      throw FormatException('Unexpected names for $path: $value');
    }
    final names = <String>[];
    for (final name in value) {
      if (name is! String) {
        throw FormatException('Unexpected name for $path: $name');
      }
      names.add(name);
    }

    return names;
  }

  String? _primaryName(Object? value, String path) {
    if (value == null) {
      return null;
    }
    if (value is! List) {
      throw FormatException('Unexpected cards for $path: $value');
    }

    final primary = <String>[];
    for (final card in value) {
      if (card is! Map<String, Object?>) {
        throw FormatException('Unexpected card for $path: $card');
      }
      final records = card['records'];
      if (records is! Map<String, Object?>?) {
        throw FormatException('Unexpected records for $path: $records');
      }
      if (records?['primary'] != true) {
        continue;
      }
      final name = card['name'];
      if (name is! String) {
        throw FormatException('Unexpected card name for $path: $name');
      }
      primary.add(name);
    }

    if (primary.isEmpty) {
      return null;
    }
    primary.sort(DotkName.displayOrder);

    return primary.first;
  }
}
