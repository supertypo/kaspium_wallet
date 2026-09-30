import 'dart:typed_data';

import 'package:retry/retry.dart';

import '../kaspa/api/json_client.dart';
import '../kaspa/utils.dart';
import 'dotk_names.dart';
import 'dotk_record_edits.dart';
import 'dotk_records.dart';
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

  /// A cache in front of the indexer must not answer a read that proves what
  /// the indexer has seen
  static const _fresh = {'Cache-Control': 'no-cache'};

  /// The DAA score of the last block the indexer has read, and the registry
  /// it reads. A 503 still carries both while the indexer is only behind, but
  /// an indexer that failed its self-test is not answering.
  Future<({BigInt? daaScore, String? registryCovenantId})> indexed() async {
    const path = '/health';
    final json = _object(
      await _client
          .get(path, headers: _fresh, accept: const {503})
          .timeout(timeout),
      path,
    );
    if (json['selfTest'] case {'proven': false}) {
      throw Exception('The indexer failed its self-test');
    }
    final daaScore = switch (json['lastBlock']) {
      {'daaScore': final int daaScore} => BigInt.from(daaScore),
      _ => null,
    };
    final registry = json['registryCovenantId'];
    return (
      daaScore: daaScore,
      registryCovenantId: registry is String ? registry : null,
    );
  }

  /// The indexer's answer for [target], or null when it names nobody to pay.
  /// [fresh] asks past any cache.
  Future<DotkNameClaim?> claimName(String target, {bool fresh = false}) async {
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
      result = await _client
          .get(path, headers: fresh ? _fresh : const {})
          .timeout(timeout);
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
    final card = _card(json['card'], path);
    if (label != null && card == null) {
      return null;
    }

    return DotkNameClaim(
      target: target,
      address: address,
      registryCovenantId: _registryCovenantId(json, path),
      card: card,
    );
  }

  Future<DotkAddressClaim?> claimAddress(String address) async {
    final path = '/addresses/$address';
    final Object? result;
    try {
      result = await _client.get(path).timeout(timeout);
    } on ApiException catch (e) {
      if (e.statusCode == 400) {
        return null;
      }
      rethrow;
    }

    final json = _object(result, path);
    final names = _names(json['names'], path);
    if (names.isEmpty) {
      return null;
    }

    names.sort(DotkName.displayOrder);

    final (cards, primaryHints) = _cards(json['cards'], path);

    return DotkAddressClaim(
      names: names,
      cards: cards,
      primaryHints: primaryHints,
      registryCovenantId: _registryCovenantId(json, path),
    );
  }

  /// Whether [name] is free, and the gap that covers its key if it is. Null
  /// for a name the registry cannot hold
  Future<DotkKeyInfo?> keyInfo(String name) async {
    if (!DotkName.isValid(name)) {
      return null;
    }
    final path = '/names/$name/key';
    final Object? result;
    try {
      result = await _client.get(path).timeout(timeout);
    } on ApiException catch (e) {
      if (e.statusCode == 400) {
        return null;
      }
      rethrow;
    }

    final json = _object(result, path);
    final kind = json['kind'];
    if (kind is! String) {
      throw FormatException('Unexpected kind for $path: $kind');
    }
    if (kind != 'free') {
      return DotkKeyInfo(
        free: false,
        registryCovenantId: _registryCovenantId(json, path),
      );
    }
    final covering = json['covering'];
    if (covering is! Map<String, Object?>) {
      throw FormatException('Unexpected covering gap for $path: $covering');
    }

    return DotkKeyInfo(
      free: true,
      gapLo: _bytes(covering['lo'], path, length: 32),
      gapHi: _bytes(covering['hi'], path, length: 32),
      registryCovenantId: _registryCovenantId(json, path),
    );
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

  /// The live cards of an address and the names the indexer read as setting
  /// primary. A malformed card is dropped on its own, so its name shows
  /// without records and the address's other names still show
  (Map<String, DotkCard>, Set<String>) _cards(Object? value, String path) {
    if (value == null) {
      return (const {}, const {});
    }
    if (value is! List) {
      throw FormatException('Unexpected cards for $path: $value');
    }

    final cards = <String, DotkCard>{};
    final primaryHints = <String>{};
    for (final card in value) {
      if (card is! Map<String, Object?>) {
        continue;
      }
      final records = card['records'];
      final name = card['name'];
      if (records is! Map<String, Object?>? || name is! String) {
        continue;
      }
      final DotkCard parsed;
      try {
        parsed = _card(card, path)!;
      } on FormatException {
        continue;
      }
      cards[name] = parsed;
      if (records?[DotkRecordEdits.primaryKey] == true) {
        primaryHints.add(name);
      }
    }

    return (cards, primaryHints);
  }

  DotkCard? _card(Object? value, String path) {
    if (value == null) {
      return null;
    }
    if (value is! Map<String, Object?>) {
      throw FormatException('Unexpected card for $path: $value');
    }
    if (value['live'] != true) {
      throw FormatException('Unexpected card for $path: it is not live');
    }
    final spenderType = value['spenderType'];
    if (spenderType != DotkOwnerType.schnorr &&
        spenderType != DotkOwnerType.ecdsaOddY &&
        spenderType != DotkOwnerType.ecdsaEvenY) {
      throw FormatException('Unexpected card spender for $path: $spenderType');
    }
    final blob = value['blob'];
    if (blob is! String || blob.length > 2 * DotkRecords.blobMaxLength) {
      throw FormatException('Unexpected card blob for $path');
    }

    return DotkCard(
      spenderType: spenderType as int,
      spender: _bytes(value['spender'], path, length: 32),
      blob: _bytes(blob, path),
    );
  }

  String _registryCovenantId(Map<String, Object?> json, String path) {
    final id = json['registryCovenantId'];
    if (id is! String) {
      throw FormatException('Unexpected registry covenant id for $path: $id');
    }
    return id;
  }

  Uint8List _bytes(Object? value, String path, {int? length}) {
    Uint8List? bytes;
    try {
      if (value is String && value.length.isEven) {
        bytes = hexToBytes(value);
      }
    } on FormatException catch (_) {}
    if (bytes == null || (length != null && bytes.length != length)) {
      throw FormatException('Unexpected bytes for $path: $value');
    }
    return bytes;
  }
}
