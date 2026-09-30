import 'dart:convert';
import 'dart:io';

import 'package:blake3_dart/blake3_dart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspium_wallet/dotk/dotk_names.dart';
import 'package:kaspium_wallet/dotk/dotk_owned_name.dart';
import 'package:kaspium_wallet/dotk/dotk_proof.dart';
import 'package:kaspium_wallet/dotk/dotk_records.dart';
import 'package:kaspium_wallet/dotk/dotk_registry.dart';
import 'package:kaspium_wallet/dotk/dotk_types.dart';
import 'package:kaspium_wallet/kaspa/kaspa.dart';
import 'package:kaspium_wallet/kaspa/rpc/grpc/rpc.pb.dart';
import 'package:kaspium_wallet/kaspa/rpc/grpc_converters.dart';

import 'dotk_fake_node.dart';

const kOwnerKey =
    '4f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa';

AddressPrefix prefixOf(String network) => switch (network) {
  'mainnet' => .kaspa,
  'testnet-10' => .kaspaTest,
  'devnet' => .kaspaDev,
  'simnet' => .kaspaSim,
  _ => throw ArgumentError(network),
};

DotkCard cardOf(Map<String, dynamic> records) => DotkCard(
  spenderType: DotkOwnerType.schnorr,
  spender: hexToBytes(kOwnerKey),
  blob: encodeRecords(records),
);

void main() {
  final vectors =
      json.decode(File('test/dotk/dotk_vectors.json').readAsStringSync())
          as Map<String, dynamic>;
  List<Map<String, dynamic>> cases(String section) =>
      (vectors[section] as List).cast<Map<String, dynamic>>();

  final ownerKey = hexToBytes(kOwnerKey);
  final owner = Address.publicKey(prefix: .kaspa, publicKey: ownerKey);

  group('vectors', () {
    test('record blobs decode to the pinned records', () {
      for (final c in cases('recordsDecode')) {
        final records = DotkRecords.tryDecode(hexToBytes(c['blob']));
        final expected = c['records'] as Map<String, dynamic>?;

        expect(
          records?.map(
            (key, value) => MapEntry(
              key,
              value is Uint8List ? {'opaque': value.hex} : value,
            ),
          ),
          expected,
          reason: c['what'],
        );
      }
    });

    test('record keys keep a leading byte order mark', () {
      final records = DotkRecords.decode(
        encodeRecords({
          '\u{feff}sub:bob': true,
          '\u{feff}\u{feff}x': true,
          '\u{fffd}x': true,
        }),
      );

      expect(records.keys, [
        '\u{feff}sub:bob',
        '\u{feff}\u{feff}x',
        '\u{fffd}x',
      ]);
    });

    test('subnames resolve to the pinned payees', () async {
      for (final c in cases('subname')) {
        final input = c['input'] as String;
        final expected = c['address'] as String?;
        final target = DotkName.tryNormalize(input);
        if (target == null) {
          // The wallet requires the suffix, so a dotted input without one is
          // refused here, and the vectors pin no payee for it either
          expect(expected, isNull, reason: input);
          continue;
        }
        final (parent, label) = DotkName.splitTarget(target);
        expect((parent, label), (c['parent'], c['label']), reason: input);
        if (label == null || c['ownerType'] == 4) {
          continue;
        }

        final prefix = prefixOf(c['network']);
        final card = DotkCard(
          spenderType: DotkOwnerType.schnorr,
          spender: hexToBytes(kOwnerKey),
          blob: encodeRecords(c['records']),
        );
        final node = FakeNode();
        final prover = DotkProver(
          node,
          registry: DotkRegistry.mainnet,
          prefix: prefix,
        );
        node.utxos.addAll([
          fakeUtxo(
            prover.deedAddress(parent, DotkOwnerType.schnorr, ownerKey),
            covenantId: DotkRegistry.mainnet.covenantId,
          ),
          fakeUtxo(prover.cardAddress(parent, card), index: 1),
        ]);

        final lookup = await prover.prove(
          DotkNameClaim(
            target: target,
            address: Address.publicKey(
              prefix: prefix,
              publicKey: ownerKey,
            ).encoded,
            registryCovenantId: DotkRegistry.mainnet.covenantId,
            card: card,
          ),
        );

        expect(lookup.resolution?.address, expected, reason: input);
        if (expected == null) {
          expect(lookup.status, DotkLookupStatus.notRegistered, reason: input);
        }
      }
    });
  });

  group('prove', () {
    final registry = DotkRegistry.mainnet;
    late FakeNode node;
    late DotkProver prover;

    setUp(() {
      node = FakeNode();
      prover = DotkProver(node, registry: registry, prefix: .kaspa);
    });

    String deedAddress(String name) =>
        prover.deedAddress(name, DotkOwnerType.schnorr, ownerKey);

    final bobRecords = {
      'sub:bob': {'opaque': '582100$kOwnerKey'},
      'primary': true,
    };

    DotkNameClaim claim(
      String target, {
      DotkCard? card,
      String? address,
      String? registryCovenantId,
    }) => DotkNameClaim(
      target: target,
      address: address ?? owner.encoded,
      registryCovenantId: registryCovenantId ?? registry.covenantId,
      card: card,
    );

    void holdDeed(String name, {String? transactionId}) => node.utxos.add(
      fakeUtxo(
        deedAddress(name),
        transactionId: transactionId,
        covenantId: registry.covenantId,
      ),
    );

    test('resolves a name the node holds a registry deed for', () async {
      holdDeed('alice');

      final lookup = await prover.prove(claim('alice'));

      expect(lookup.status, DotkLookupStatus.resolved);
      expect(lookup.resolution?.address, owner.encoded);
      expect(node.asked, [
        [deedAddress('alice')],
      ]);
    });

    test('does not confirm a deed that is not the registry\'s', () async {
      for (final utxos in [
        <Utxo>[],
        [fakeUtxo(deedAddress('alice'))],
        [
          fakeUtxo(deedAddress('alice'), covenantId: registry.covenantId),
          fakeUtxo(
            deedAddress('alice'),
            index: 1,
            covenantId: registry.covenantId,
          ),
        ],
        [
          fakeUtxo(
            deedAddress('alice'),
            covenantId: DotkRegistry.testnet10.covenantId,
          ),
        ],
      ]) {
        node.utxos
          ..clear()
          ..addAll(utxos);

        final lookup = await prover.prove(claim('alice'));

        expect(lookup.status, DotkLookupStatus.unconfirmed);
      }
    });

    test('proves the deed of every owner scheme an address has', () async {
      final even = Uint8List.fromList([0x02, ...ownerKey]);
      final odd = Uint8List.fromList([0x03, ...ownerKey]);
      final hash = Uint8List(32)..fillRange(0, 32, 0x22);
      for (final (address, type, payload) in [
        (owner, DotkOwnerType.schnorr, ownerKey),
        (
          Address.pubKeyECDSA(prefix: .kaspa, publicKey: even),
          DotkOwnerType.ecdsaEvenY,
          ownerKey,
        ),
        (
          Address.pubKeyECDSA(prefix: .kaspa, publicKey: odd),
          DotkOwnerType.ecdsaOddY,
          ownerKey,
        ),
        (
          Address.scriptHash(prefix: .kaspa, hash: hash),
          DotkOwnerType.scriptHash,
          hash,
        ),
      ]) {
        node.utxos
          ..clear()
          ..add(
            fakeUtxo(
              prover.deedAddress('alice', type, payload),
              covenantId: registry.covenantId,
            ),
          );

        final lookup = await prover.prove(
          claim('alice', address: address.encoded),
        );

        expect(lookup.resolution?.address, address.encoded, reason: '$type');
      }

      final uncompressed = Address.pubKeyECDSA(
        prefix: .kaspa,
        publicKey: Uint8List.fromList([0x04, ...ownerKey]),
      );
      expect(DotkProver.ownerOf(uncompressed), isNull);
    });

    test('reads the covenant id the node reports', () {
      final id = registry.covenantId;

      expect(decodeUtxoEntry(RpcUtxoEntry(covenantId: id)).covenantId?.hex, id);
      expect(decodeUtxoEntry(RpcUtxoEntry()).covenantId, isNull);
    });

    test('does not confirm an answer from another registry', () async {
      holdDeed('alice');

      final lookup = await prover.prove(
        claim(
          'alice',
          registryCovenantId: DotkRegistry.testnet10.covenantId,
        ),
      );

      expect(lookup.status, DotkLookupStatus.unconfirmed);
      expect(node.asked, isEmpty);
    });

    test('answers not registered for an owner on another network', () async {
      final lookup = await prover.prove(
        claim(
          'alice',
          address: Address.publicKey(
            prefix: .kaspaTest,
            publicKey: ownerKey,
          ).encoded,
        ),
      );

      expect(lookup.status, DotkLookupStatus.notRegistered);
      expect(node.asked, isEmpty);
    });

    test('resolves a label on the proven card', () async {
      final card = cardOf(bobRecords);
      holdDeed('alice');
      node.utxos.add(fakeUtxo(prover.cardAddress('alice', card), index: 1));

      final lookup = await prover.prove(claim('bob.alice', card: card));

      expect(lookup.status, DotkLookupStatus.resolved);
      expect(lookup.resolution?.display, 'bob.alice.k');
      expect(lookup.resolution?.address, owner.encoded);
    });

    test('does not confirm a card that is not the deed\'s', () async {
      final card = cardOf(bobRecords);
      for (final utxo in [
        fakeUtxo(prover.cardAddress('alice', card), index: 0),
        fakeUtxo(
          prover.cardAddress('alice', card),
          index: 1,
          transactionId: 'ee' * 32,
        ),
        fakeUtxo(prover.cardAddress('bob', card), index: 1),
      ]) {
        node.utxos.clear();
        holdDeed('alice');
        node.utxos.add(utxo);

        final lookup = await prover.prove(claim('bob.alice', card: card));

        expect(lookup.status, DotkLookupStatus.unconfirmed);
      }
    });

    test('does not confirm a blob the owner did not publish', () async {
      final published = cardOf(bobRecords);
      holdDeed('alice');
      node.utxos.add(
        fakeUtxo(prover.cardAddress('alice', published), index: 1),
      );

      final forged = cardOf({
        'sub:bob': {'opaque': '582103${'ab' * 32}'},
      });
      final lookup = await prover.prove(claim('bob.alice', card: forged));

      expect(lookup.status, DotkLookupStatus.unconfirmed);
    });

    test('answers not registered for a label the proven card lacks', () async {
      final card = cardOf(bobRecords);
      holdDeed('alice');
      node.utxos.add(fakeUtxo(prover.cardAddress('alice', card), index: 1));

      final lookup = await prover.prove(claim('pay.alice', card: card));

      expect(lookup.status, DotkLookupStatus.notRegistered);
    });
  });

  group('displayName', () {
    final registry = DotkRegistry.mainnet;
    late FakeNode node;
    late DotkProver prover;

    setUp(() {
      node = FakeNode();
      prover = DotkProver(node, registry: registry, prefix: .kaspa);
    });

    DotkAddressClaim claim({
      Map<String, DotkCard> primaryCards = const {},
      String? registryId,
    }) => DotkAddressClaim(
      names: const ['x', 'kaspa', 'coinbase'],
      cards: primaryCards,
      primaryHints: primaryCards.keys.toSet(),
      registryCovenantId: registryId ?? registry.covenantId,
    );

    void hold(String name, {DotkCard? card, int daaScore = 0}) {
      node.utxos.add(
        fakeUtxo(
          prover.deedAddress(name, DotkOwnerType.schnorr, ownerKey),
          transactionId: blake3(ascii.encode(name)).hex,
          daaScore: daaScore,
          covenantId: registry.covenantId,
        ),
      );
      if (card != null) {
        node.utxos.add(
          fakeUtxo(
            prover.cardAddress(name, card),
            transactionId: blake3(ascii.encode(name)).hex,
            index: 1,
          ),
        );
      }
    }

    test('shows the primary name when the node proves its card', () async {
      final card = cardOf({'primary': true});
      hold('x');
      hold('kaspa', card: card);

      expect(
        await prover.displayName(
          owner.encoded,
          claim(primaryCards: {'kaspa': card}),
        ),
        'kaspa',
      );
      expect(node.asked.single, hasLength(3));
    });

    test('shows the most recent of two primary names', () async {
      final card = cardOf({'primary': true});
      hold('x');
      hold('kaspa', card: card, daaScore: 7);
      hold('coinbase', card: card, daaScore: 9);

      expect(
        await prover.displayName(
          owner.encoded,
          claim(primaryCards: {'kaspa': card, 'coinbase': card}),
        ),
        'coinbase',
      );
    });

    test('breaks a tie between primaries by transaction id', () async {
      final card = cardOf({'primary': true});
      hold('kaspa', card: card);
      hold('coinbase', card: card);
      final lower =
          blake3(ascii.encode('kaspa')).hex.compareTo(
                blake3(ascii.encode('coinbase')).hex,
              ) <
              0
          ? 'kaspa'
          : 'coinbase';

      expect(
        await prover.displayName(
          owner.encoded,
          claim(primaryCards: {'kaspa': card, 'coinbase': card}),
        ),
        lower,
      );
    });

    test('falls back to the first name for an unproven primary', () async {
      final card = cardOf({'primary': true});
      final notPrimary = cardOf({'primary': false});
      hold('x');
      hold('kaspa', card: notPrimary);

      expect(
        await prover.displayName(
          owner.encoded,
          claim(primaryCards: {'kaspa': card}),
        ),
        'x',
      );
      expect(
        await prover.displayName(
          owner.encoded,
          claim(primaryCards: {'kaspa': notPrimary}),
        ),
        'x',
      );
    });

    test('proves a card setting primary the indexer did not hint', () async {
      final card = cardOf({'primary': true});
      final notPrimary = cardOf({'url': 'https://kaspa.org'});
      hold('x');
      hold('kaspa', card: card);
      hold('coinbase', card: notPrimary);

      final name = await prover.displayName(
        owner.encoded,
        DotkAddressClaim(
          names: const ['x', 'kaspa', 'coinbase'],
          cards: {'kaspa': card, 'coinbase': notPrimary},
          primaryHints: const {'coinbase'},
          registryCovenantId: registry.covenantId,
        ),
      );

      expect(name, 'kaspa');
      // The deeds of x and kaspa and kaspa's card: coinbase's blob does not
      // set primary, whatever the hint says
      expect(node.asked.single, hasLength(3));
    });

    test('shows the first name when the node proves it', () async {
      hold('x');

      expect(await prover.displayName(owner.encoded, claim()), 'x');
      expect(node.asked.single, hasLength(1));
    });

    test('shows nothing when the node does not prove the first name', () async {
      hold('kaspa');

      expect(await prover.displayName(owner.encoded, claim()), isNull);
    });

    test('proves at most ten primaries and the first name', () async {
      final card = cardOf({'primary': true});
      final names = [for (var i = 0; i < 40; i++) 'n$i'];
      hold(names.last, card: card);

      final name = await prover.displayName(
        owner.encoded,
        DotkAddressClaim(
          names: names,
          cards: {for (final name in names.reversed) name: card},
          primaryHints: names.toSet(),
          registryCovenantId: registry.covenantId,
        ),
      );

      expect(name, 'n39');
      expect(
        node.asked.single,
        hasLength(2 * DotkProver.maxPrimariesProven + 1),
      );
    });

    test('shows nothing from another registry', () async {
      hold('x');

      expect(
        await prover.displayName(
          owner.encoded,
          claim(registryId: DotkRegistry.testnet10.covenantId),
        ),
        isNull,
      );
      expect(node.asked, isEmpty);
    });
  });

  group('proveOwned', () {
    final registry = DotkRegistry.mainnet;
    late FakeNode node;
    late DotkProver prover;

    setUp(() {
      node = FakeNode();
      prover = DotkProver(node, registry: registry, prefix: .kaspa);
    });

    DotkAddressClaim claim(
      List<String> names, {
      Map<String, DotkCard> cards = const {},
      String? registryId,
    }) => DotkAddressClaim(
      names: names,
      cards: cards,
      registryCovenantId: registryId ?? registry.covenantId,
    );

    void hold(
      String name, {
      DotkCard? card,
      int daaScore = 0,
      int cardIndex = 1,
    }) {
      node.utxos.add(
        fakeUtxo(
          prover.deedAddress(name, DotkOwnerType.schnorr, ownerKey),
          transactionId: blake3(ascii.encode(name)).hex,
          daaScore: daaScore,
          covenantId: registry.covenantId,
        ),
      );
      if (card != null) {
        node.utxos.add(
          fakeUtxo(
            prover.cardAddress(name, card),
            transactionId: blake3(ascii.encode(name)).hex,
            index: cardIndex,
          ),
        );
      }
    }

    test('lists only the names the node backs, from this registry', () async {
      hold('kaspa');

      final owned = await prover.proveOwned({
        owner.encoded: claim(['kaspa', 'x']),
      });

      expect(owned.map((name) => name.name), ['kaspa']);
      expect(owned.single.address, owner.encoded);
      expect(owned.single.recordsState, DotkRecordsState.none);
      expect(owned.single.primary, DotkPrimary.none);

      final other = await prover.proveOwned({
        owner.encoded: claim(['kaspa'], registryId: 'ff' * 32),
      });
      expect(other, isEmpty);
    });

    test('shows records only from output 1 of the deed', () async {
      final card = cardOf({'url': 'https://kaspa.org'});
      hold('kaspa', card: card);
      final proven = await prover.proveOwned({
        owner.encoded: claim(['kaspa'], cards: {'kaspa': card}),
      });
      expect(proven.single.recordsState, DotkRecordsState.proven);
      expect(proven.single.records, {'url': 'https://kaspa.org'});

      node.utxos.clear();
      hold('kaspa', card: card, cardIndex: 2);
      final unproven = await prover.proveOwned({
        owner.encoded: claim(['kaspa'], cards: {'kaspa': card}),
      });
      expect(unproven.single.recordsState, DotkRecordsState.unproven);
      expect(unproven.single.records, isEmpty);
      expect(unproven.single.card, isNull);
      // A transfer still sees the listing, and refuses to drop it
      expect(unproven.single.listedCard, isNotNull);
    });

    test('marks a card the node holds but cannot read unreadable', () async {
      for (final blob in [
        Uint8List.fromList([0xff]),
        encodeRecords({
          'primary': true,
          'bio': 'a' * DotkRecords.blobMaxLength,
        }),
      ]) {
        node.utxos.clear();
        final card = DotkCard(
          spenderType: DotkOwnerType.schnorr,
          spender: ownerKey,
          blob: blob,
        );
        hold('kaspa', card: card);

        final owned = await prover.proveOwned({
          owner.encoded: claim(['kaspa'], cards: {'kaspa': card}),
        });

        final reason = '${blob.length} bytes';
        expect(
          owned.single.recordsState,
          DotkRecordsState.unreadable,
          reason: reason,
        );
        expect(owned.single.records, isEmpty, reason: reason);
        expect(owned.single.card, same(card), reason: reason);
        expect(owned.single.cardUtxo?.outpoint.index, 1, reason: reason);
        expect(owned.single.primary, DotkPrimary.none, reason: reason);
      }
    });

    test('picks a primary winner for each address', () async {
      final card = cardOf({'primary': true});
      final ecdsa = Address.pubKeyECDSA(
        prefix: .kaspa,
        publicKey: Uint8List.fromList([0x02, ...ownerKey]),
      );
      hold('kaspa', card: card, daaScore: 9);
      hold('coinbase', card: card, daaScore: 7);
      for (final (name, daaScore) in [('x', 3), ('y', 5)]) {
        final transactionId = blake3(ascii.encode('ecdsa $name')).hex;
        node.utxos.addAll([
          fakeUtxo(
            prover.deedAddress(name, DotkOwnerType.ecdsaEvenY, ownerKey),
            transactionId: transactionId,
            daaScore: daaScore,
            covenantId: registry.covenantId,
          ),
          fakeUtxo(
            prover.cardAddress(name, card),
            transactionId: transactionId,
            index: 1,
          ),
        ]);
      }

      final owned = await prover.proveOwned({
        owner.encoded: claim(
          ['kaspa', 'coinbase'],
          cards: {'kaspa': card, 'coinbase': card},
        ),
        ecdsa.encoded: claim(['x', 'y'], cards: {'x': card, 'y': card}),
      });

      final primary = {
        for (final name in owned) (name.address, name.name): name.primary,
      };
      expect(primary, {
        (owner.encoded, 'kaspa'): DotkPrimary.winner,
        (owner.encoded, 'coinbase'): DotkPrimary.older,
        (ecdsa.encoded, 'x'): DotkPrimary.older,
        (ecdsa.encoded, 'y'): DotkPrimary.winner,
      });
    });

    test('proves the names of ECDSA and P2SH owners', () async {
      final hash = Uint8List(32)..fillRange(0, 32, 0x22);
      final owners = [
        (
          Address.pubKeyECDSA(
            prefix: .kaspa,
            publicKey: Uint8List.fromList([0x02, ...ownerKey]),
          ),
          DotkOwnerType.ecdsaEvenY,
          ownerKey,
        ),
        (
          Address.pubKeyECDSA(
            prefix: .kaspa,
            publicKey: Uint8List.fromList([0x03, ...ownerKey]),
          ),
          DotkOwnerType.ecdsaOddY,
          ownerKey,
        ),
        (
          Address.scriptHash(prefix: .kaspa, hash: hash),
          DotkOwnerType.scriptHash,
          hash,
        ),
      ];
      for (final (_, type, payload) in owners) {
        node.utxos.add(
          fakeUtxo(
            prover.deedAddress('kaspa', type, payload),
            transactionId: blake3(ascii.encode('$type')).hex,
            covenantId: registry.covenantId,
          ),
        );
      }

      final owned = await prover.proveOwned({
        for (final (address, _, _) in owners)
          address.encoded: claim(['kaspa', 'x']),
      });

      expect(owned.map((name) => name.address), [
        for (final (address, _, _) in owners) address.encoded,
      ]);
      expect(owned.map((name) => name.name).toSet(), {'kaspa'});
    });

    test('asks the node in chunks', () async {
      final names = [for (var i = 0; i < DotkProver.ownedChunk + 1; i++) 'n$i'];

      await prover.proveOwned({owner.encoded: claim(names)});

      expect(node.asked.map((asked) => asked.length), [
        DotkProver.ownedChunk,
        1,
      ]);
    });
  });
}
