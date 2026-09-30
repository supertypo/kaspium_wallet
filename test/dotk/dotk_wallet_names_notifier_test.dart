import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kaspium_wallet/dotk/dotk_owned_name.dart';
import 'package:kaspium_wallet/dotk/dotk_registry.dart';
import 'package:kaspium_wallet/dotk/dotk_service.dart';
import 'package:kaspium_wallet/dotk/dotk_wallet_names_notifier.dart';
import 'package:kaspium_wallet/kaspa/api/json_client.dart';
import 'package:retry/retry.dart';

import 'dotk_fake_node.dart';

const kBaseUrl = 'https://api.dotk.name/v1';
const kAddress =
    'kaspa:qpvtxyhfm0x63y97g2ktamen5ngpdmjwpslcf92quu5x5e5ag3uezpj2gt9km';
const kOtherAddress =
    'kaspa:qpsk3cj9pr4dmexwcuj37ma3nm2075ht2yara3xxk4twufmv7kd27vpczqyjd';

class FakeIndexer {
  final Map<String, List<String>> names;
  final failing = <String>{};
  final requests = <String>[];

  /// Each request for an address answers with the names it has when asked,
  /// then waits for the next gate the address has, if any
  final gates = <String, List<Completer<void>>>{};

  FakeIndexer(this.names);

  late final service = DotkService(
    JsonClient(
      kBaseUrl,
      r: const RetryOptions(maxAttempts: 1, delayFactor: Duration.zero),
      minRequestGap: .zero,
      client: MockClient(_handle),
    ),
  );

  Future<http.Response> _handle(http.Request request) async {
    final address = request.url.pathSegments.last;
    requests.add(address);

    final response = failing.contains(address)
        ? http.Response('{"error":"boom"}', 500)
        : http.Response(
            json.encode({
              'ownerType': 0,
              'owner': 'abcd',
              'address': address,
              'names': names[address] ?? <String>[],
              'cards': <Object?>[],
              'registryCovenantId': DotkRegistry.mainnet.covenantId,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
    final waiting = gates[address];
    if (waiting != null && waiting.isNotEmpty) {
      await waiting.removeAt(0).future;
    }
    return response;
  }

  /// Holds the next answer for [address] until the returned gate completes
  Completer<void> hold(String address) {
    final gate = Completer<void>();
    (gates[address] ??= []).add(gate);
    return gate;
  }
}

void main() {
  late FakeIndexer indexer;
  late DotkWalletNamesNotifier notifier;

  setUp(() {
    indexer = FakeIndexer({
      kAddress: ['kaspa', 'coinbase', 'x'],
      kOtherAddress: [],
    });
    notifier = DotkWalletNamesNotifier(
      indexer.service,
      prover: provingEverything,
      addresses: () => [kAddress, kOtherAddress],
      followInterval: const Duration(milliseconds: 20),
    );
  });

  tearDown(() => notifier.dispose());

  test('lists the proven names of every address, shortest first', () async {
    await notifier.scan();

    expect(indexer.requests.toSet(), {kAddress, kOtherAddress});
    expect(notifier.names.map((name) => name.name), ['x', 'kaspa', 'coinbase']);
    expect(notifier.names.first.address, kAddress);
    expect(notifier.addressCount, 1);
    expect(notifier.failed, isEmpty);
    expect(notifier.ownedName('kaspa')?.primary, DotkPrimary.none);
    expect(notifier.ownedName('nope'), isNull);

    // Nothing is listed that no prover backs
    final unproven = DotkWalletNamesNotifier(
      indexer.service,
      prover: () => null,
      addresses: () => [kAddress],
    );
    addTearDown(unproven.dispose);
    await unproven.scan();
    expect(unproven.names, isEmpty);
  });

  test('keeps the rows of a failed address and retries only it', () async {
    indexer.failing.add(kAddress);
    await notifier.scan();
    expect(notifier.names, isEmpty);
    expect(notifier.failed, {kAddress});

    indexer.failing.clear();
    indexer.requests.clear();
    await notifier.scan(onlyFailed: true);
    expect(indexer.requests, [kAddress]);
    expect(notifier.failed, isEmpty);
    expect(notifier.names, hasLength(3));

    indexer.failing.add(kAddress);
    await notifier.scan();
    expect(notifier.names, hasLength(3));
    expect(notifier.failed, {kAddress});
  });

  test('a name awaited during a scan wins over its older answer', () async {
    final gate = indexer.hold(kAddress);
    final scan = notifier.scan();
    await pumpEventQueue();
    expect(notifier.isScanning, isTrue);
    indexer.names[kAddress] = ['kaspa'];

    final awaiting = notifier.awaitName('kaspa', kAddress);
    expect(notifier.awaiting, {'kaspa'});
    await awaiting;
    expect(notifier.awaiting, isEmpty);
    expect(indexer.requests.where((a) => a == kAddress), hasLength(2));
    expect(notifier.names.map((name) => name.name), ['kaspa']);

    gate.complete();
    await scan;
    expect(notifier.names.map((name) => name.name), ['kaspa']);
  });

  test('a name still polled for is not scanned for as well', () async {
    await notifier.scan();
    unawaited(notifier.awaitName('new', kAddress));
    await notifier.refreshIfStale();
    expect(indexer.requests.where((a) => a == kOtherAddress), hasLength(1));
  });

  group('follow', () {
    Future<void> untilAsked(String address, int count) => until(
      () => indexer.requests.where((a) => a == address).length >= count,
      reason: '$count requests for $address',
    );

    DotkOwnedName moved(DotkOwnedName name) => DotkOwnedName(
      name: name.name,
      address: name.address,
      deed: fakeUtxo(name.address, transactionId: 'ee' * 32),
    );

    test('keeps following while the deed stays', () async {
      await notifier.scan();
      final kaspa = notifier.ownedName('kaspa')!;

      unawaited(notifier.follow(kaspa));
      await untilAsked(kAddress, 3);

      expect(notifier.inFlight.keys, ['kaspa']);
      expect(notifier.isFollowingAt(kAddress), isTrue);
      expect(notifier.isFollowingAt(kOtherAddress), isFalse);
    });

    test('lets go once the deed moves, through a failed lookup', () async {
      await notifier.scan();
      indexer.failing.add(kAddress);

      final following = notifier.follow(moved(notifier.ownedName('kaspa')!));
      await untilAsked(kAddress, 3);

      expect(notifier.inFlight.keys, ['kaspa']);
      expect(notifier.names, hasLength(3));
      indexer.failing.clear();
      await following;
      expect(notifier.inFlight, isEmpty);
    });

    test('a minted card the indexer does not list keeps the follow', () async {
      await notifier.scan();
      unawaited(
        notifier.follow(
          moved(notifier.ownedName('kaspa')!),
          inFlight: false,
          mintBlob: Uint8List.fromList([0xa0]),
        ),
      );

      await untilAsked(kAddress, 4);
      expect(notifier.isFollowing('kaspa'), isTrue);
    });

    test('to an own address waits until that address lists it', () async {
      await notifier.scan();
      indexer.names[kAddress] = ['coinbase', 'x'];

      final following = notifier.follow(
        moved(notifier.ownedName('kaspa')!),
        to: kOtherAddress,
      );
      await untilAsked(kOtherAddress, 3);
      expect(notifier.inFlight.keys, ['kaspa']);

      indexer.names[kOtherAddress] = ['kaspa'];
      await following;
      expect(notifier.inFlight, isEmpty);
      expect(notifier.ownedName('kaspa')?.address, kOtherAddress);
    });
  });
}
