import 'package:collection/collection.dart';

import '../kaspa/rpc/rpc_service.dart';
import '../kaspa/types.dart';
import '../kaspa/utils.dart';
import 'dotk_names.dart';
import 'dotk_owned_name.dart';
import 'dotk_record_edits.dart';
import 'dotk_records.dart';
import 'dotk_registry.dart';
import 'dotk_subname.dart';
import 'dotk_tx.dart';
import 'dotk_types.dart';

/// Proves the indexer's answers against the node, never what it leaves out
class DotkProver {
  /// Cards [displayName] proves at most for one address. Each costs two
  /// addresses in the node query
  static const maxPrimariesProven = 10;

  /// Addresses per node query when proving a whole wallet's names
  static const ownedChunk = 400;

  final RpcService rpc;
  final DotkRegistry registry;
  final AddressPrefix prefix;

  const DotkProver(this.rpc, {required this.registry, required this.prefix});

  Future<DotkLookup> prove(DotkNameClaim claim) async {
    final owner = Address.tryParse(claim.address, expectedPrefix: prefix);
    if (owner == null) {
      return const DotkLookup.notRegistered();
    }
    final pair = ownerOf(owner);
    if (pair == null || claim.registryCovenantId != registry.covenantId) {
      return const DotkLookup.unconfirmed();
    }

    final (parent, label) = DotkName.splitTarget(claim.target);
    final deedAddress = this.deedAddress(parent, pair.$1, pair.$2);
    final card = label == null ? null : claim.card;
    final cardAddress = card == null ? null : _cardAddressOf(parent, card);

    final utxos = await rpc.getUtxosByAddresses([
      deedAddress,
      ?cardAddress,
    ]);
    final deed = _deed(utxos, deedAddress);
    if (deed == null) {
      return const DotkLookup.unconfirmed();
    }
    if (label == null) {
      return DotkLookup.resolved(
        DotkNameResolution.forName(parent, address: owner.encoded),
      );
    }
    if (card == null ||
        cardAddress == null ||
        !_isCard(utxos, cardAddress, deed)) {
      return const DotkLookup.unconfirmed();
    }

    final records = _records(card);
    final payee = DotkSubname.payee(
      records?[DotkSubname.recordKey(label)],
      prefix,
    );
    if (payee == null) {
      return const DotkLookup.notRegistered();
    }

    return DotkLookup.resolved(
      DotkNameResolution.forName(claim.target, address: payee),
    );
  }

  /// The name to show for [address]: the proven card that set primary most
  /// recently, else the first name when the node proves it. Only
  /// [maxPrimariesProven] cards are proven, so with more than that the name
  /// can differ from the winner [proveOwned] marks.
  Future<String?> displayName(String address, DotkAddressClaim claim) async {
    final owner = Address.tryParse(address, expectedPrefix: prefix);
    final pair = owner == null ? null : ownerOf(owner);
    if (pair == null || claim.registryCovenantId != registry.covenantId) {
      return null;
    }

    final listed = claim.names.where(DotkName.isValid).toSet();
    final hints = claim.primaryHints;
    final primaryCards =
        [
              ...claim.cards.entries.where(
                (entry) => hints.contains(entry.key),
              ),
              ...claim.cards.entries.where(
                (entry) => !hints.contains(entry.key),
              ),
            ]
            .where(
              (entry) =>
                  listed.contains(entry.key) &&
                  _records(entry.value)?[DotkRecordEdits.primaryKey] == true,
            )
            .take(maxPrimariesProven)
            .toList();
    final first = claim.names.firstWhereOrNull(DotkName.isValid);
    final deeds = {
      for (final name in [...primaryCards.map((entry) => entry.key), ?first])
        name: deedAddress(name, pair.$1, pair.$2),
    };
    final cards = {
      for (final MapEntry(key: name, value: card) in primaryCards)
        name: ?_cardAddressOf(name, card),
    };

    final utxos = await rpc.getUtxosByAddresses([
      ...deeds.values,
      ...cards.values,
    ]);

    String? primary;
    Utxo? primaryDeed;
    for (final MapEntry(key: name, value: cardAddress) in cards.entries) {
      final deed = _deed(utxos, deeds[name]!);
      if (deed == null || !_isCard(utxos, cardAddress, deed)) {
        continue;
      }
      if (primaryDeed == null || _isNewer(deed, primaryDeed)) {
        primary = name;
        primaryDeed = deed;
      }
    }
    if (primary != null) {
      return primary;
    }

    return first != null && _deed(utxos, deeds[first]!) != null ? first : null;
  }

  /// Every name in [claims] the node backs, one claim per owner address. A
  /// card counts only when the node holds it as output 1 of the deed's
  /// transaction.
  Future<List<DotkOwnedName>> proveOwned(
    Map<String, DotkAddressClaim> claims,
  ) async {
    final deeds = <(String, String), String>{};
    final cards = <(String, String), String>{};
    for (final MapEntry(key: address, value: claim) in claims.entries) {
      final owner = Address.tryParse(address, expectedPrefix: prefix);
      final pair = owner == null ? null : ownerOf(owner);
      if (pair == null || claim.registryCovenantId != registry.covenantId) {
        continue;
      }
      for (final name in claim.names.where(DotkName.isValid)) {
        deeds[(address, name)] = deedAddress(name, pair.$1, pair.$2);
        final card = claim.cards[name];
        final cardAddress = card == null ? null : _cardAddressOf(name, card);
        if (cardAddress != null) {
          cards[(address, name)] = cardAddress;
        }
      }
    }

    final wanted = {...deeds.values, ...cards.values}.toList();
    final utxos = <Utxo>[];
    for (var i = 0; i < wanted.length; i += ownedChunk) {
      final end = i + ownedChunk < wanted.length
          ? i + ownedChunk
          : wanted.length;
      utxos.addAll(await rpc.getUtxosByAddresses(wanted.sublist(i, end)));
    }

    final owned = <DotkOwnedName>[];
    final primaries = <String, (int, Utxo)>{};
    for (final MapEntry(key: (address, name), value: deedAddress)
        in deeds.entries) {
      final deed = _deed(utxos, deedAddress);
      if (deed == null) {
        continue;
      }
      final card = claims[address]!.cards[name];
      final cardAddress = cards[(address, name)];
      final cardUtxo = cardAddress == null
          ? null
          : _cardUtxo(utxos, cardAddress, deed);
      final records = cardUtxo == null ? null : _records(card!);
      final recordsState = card == null
          ? DotkRecordsState.none
          : cardUtxo == null
          ? DotkRecordsState.unproven
          : records == null
          ? DotkRecordsState.unreadable
          : DotkRecordsState.proven;
      final setsPrimary = records?[DotkRecordEdits.primaryKey] == true;

      if (setsPrimary) {
        final best = primaries[address];
        if (best == null || _isNewer(deed, best.$2)) {
          primaries[address] = (owned.length, deed);
        }
      }
      owned.add(
        DotkOwnedName(
          name: name,
          address: address,
          deed: deed,
          card: cardUtxo == null ? null : card,
          listedCard: card,
          cardUtxo: cardUtxo,
          records: records ?? const {},
          recordsState: recordsState,
          primary: setsPrimary ? .older : .none,
        ),
      );
    }

    for (final (index, _) in primaries.values) {
      final name = owned[index];
      owned[index] = DotkOwnedName(
        name: name.name,
        address: name.address,
        deed: name.deed,
        card: name.card,
        listedCard: name.listedCard,
        cardUtxo: name.cardUtxo,
        records: name.records,
        recordsState: name.recordsState,
        primary: .winner,
      );
    }

    return owned;
  }

  static (int, Uint8List)? ownerOf(Address address) => address.when(
    publicKey: (_, key) =>
        key.length == kPublicKeyLength ? (DotkOwnerType.schnorr, key) : null,
    pubKeyECDSA: (_, key) =>
        key.length == kPublicKeySizeECDSA && (key[0] == 0x02 || key[0] == 0x03)
        ? (
            key[0] == 0x02 ? DotkOwnerType.ecdsaEvenY : DotkOwnerType.ecdsaOddY,
            Uint8List.sublistView(key, 1),
          )
        : null,
    scriptHash: (_, hash) =>
        hash.length == 32 ? (DotkOwnerType.scriptHash, hash) : null,
  );

  String deedAddress(String name, int ownerType, Uint8List owner) => registry
      .deedAddress(DotkState.activeDeed(name, ownerType, owner))
      .encoded;

  String cardAddress(String name, DotkCard card) => DotkCardState.forBlob(
    name,
    card.blob,
    spenderType: card.spenderType,
    spender: card.spender,
  ).address(registry).encoded;

  /// Null for a card no key could spend, which the node cannot hold
  String? _cardAddressOf(String name, DotkCard card) {
    try {
      return cardAddress(name, card);
    } on DotkTxError {
      return null;
    }
  }

  Utxo? _deed(Iterable<Utxo> utxos, String deedAddress) {
    final deeds = utxos.where(
      (utxo) =>
          utxo.address == deedAddress &&
          utxo.utxoEntry.covenantId?.hex == registry.covenantId,
    );

    return deeds.length == 1 ? deeds.single : null;
  }

  /// A card's records, or null for a blob that does not decode or is longer
  /// than a record set may be
  static Map<String, Object>? _records(DotkCard card) =>
      card.blob.length > DotkRecords.blobMaxLength
      ? null
      : DotkRecords.tryDecode(card.blob);

  /// The most recent claim to primary wins, and the outpoint breaks a tie
  static bool _isNewer(Utxo a, Utxo b) {
    final byScore = a.utxoEntry.blockDaaScore.compareTo(
      b.utxoEntry.blockDaaScore,
    );
    if (byScore != 0) {
      return byScore > 0;
    }
    final byTransaction = a.outpoint.transactionId.compareTo(
      b.outpoint.transactionId,
    );
    return byTransaction != 0
        ? byTransaction < 0
        : a.outpoint.index < b.outpoint.index;
  }

  /// A card speaks for its name only as output 1 of the transaction that
  /// created the deed's current UTXO
  bool _isCard(Iterable<Utxo> utxos, String cardAddress, Utxo deed) =>
      _cardUtxo(utxos, cardAddress, deed) != null;

  Utxo? _cardUtxo(Iterable<Utxo> utxos, String cardAddress, Utxo deed) =>
      utxos.firstWhereOrNull(
        (utxo) =>
            utxo.address == cardAddress &&
            utxo.outpoint.transactionId == deed.outpoint.transactionId &&
            utxo.outpoint.index == 1,
      );
}
