import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kaspium_wallet/dotk/dotk_service.dart';
import 'package:kaspium_wallet/kaspa/api/json_client.dart';
import 'package:retry/retry.dart';

const kBaseUrl = 'https://api.dotk.name/v1';
const kAddress =
    'kaspa:qpvtxyhfm0x63y97g2ktamen5ngpdmjwpslcf92quu5x5e5ag3uezpj2gt9km';
const kTestnetAddress =
    'kaspatest:pq3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyxccxflal';
const kSchnorrValue =
    '5821004f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa';
const kPayee =
    'kaspa:qp8n2k7uklxq4aegau7vawtptkgxsja4kt99lpv6krctwpq8tpc6547zhh9u4';

http.Response _json(Object? body, [int status = 200]) => http.Response(
  json.encode(body),
  status,
  headers: {'content-type': 'application/json'},
);

http.Response _notFound() =>
    _json({'code': 'not_found', 'error': 'not registered'}, 404);

void main() {
  final paths = <String>[];

  setUp(paths.clear);

  DotkService serviceOver(
    Future<http.Response> Function(http.Request request) handle,
  ) => DotkService(
    JsonClient(
      kBaseUrl,
      r: const RetryOptions(maxAttempts: 1, delayFactor: Duration.zero),
      minRequestGap: .zero,
      client: MockClient((request) {
        paths.add(request.url.path);
        return handle(request);
      }),
    ),
  );

  DotkService serviceAnswering(Map<String, Object?> body, [int status = 200]) =>
      serviceOver((_) async => _json(body, status));

  group('url', () {
    test('is disabled without a url', () {
      expect(DotkService.url('').isEnabled, isFalse);
      expect(DotkService.url('   ').isEnabled, isFalse);
    });

    test('drops trailing slashes from the base url', () {
      expect(DotkService.url('$kBaseUrl/').baseUrl, kBaseUrl);
      expect(DotkService.url('$kBaseUrl///').baseUrl, kBaseUrl);
      expect(DotkService.url(' $kBaseUrl/ ').baseUrl, kBaseUrl);
      expect(DotkService.url(kBaseUrl).baseUrl, kBaseUrl);
    });

    test('is enabled with a url', () {
      expect(DotkService.url(kBaseUrl).isEnabled, isTrue);
    });
  });

  group('resolveName', () {
    test('resolves a registered name', () async {
      final service = serviceAnswering({
        'name': 'kaspa',
        'ownerType': 0,
        'owner': 'abcd',
        'address': kAddress,
        'deedAddress': 'kaspa:pzdeed',
        'registryCovenantId': 'ffff',
      });

      final resolution = await service.resolveName('kaspa');

      expect(paths, ['/v1/names/kaspa']);
      expect(resolution?.name, 'kaspa');
      expect(resolution?.display, 'kaspa.k');
      expect(resolution?.address, kAddress);
    });

    test('does not ask about an invalid name', () async {
      final service = serviceAnswering(const {});

      expect(await service.resolveName('-kaspa'), isNull);
      expect(await service.resolveName(''), isNull);
      expect(await service.resolveName('a' * 33), isNull);
      expect(paths, isEmpty);
    });

    test('answers null for a name that is not registered', () async {
      final service = serviceOver((_) async => _notFound());

      expect(await service.resolveName('kaspa'), isNull);
      expect(paths, ['/v1/names/kaspa']);
    });

    test('answers null for a malformed name the api rejects', () async {
      final service = serviceAnswering({'code': 'invalid_name'}, 400);

      expect(await service.resolveName('kaspa'), isNull);
    });

    test('refuses a name a covenant owns', () async {
      final service = serviceAnswering({
        'name': 'kaspa',
        'ownerType': 4,
        'owner': 'abcd',
        'address': null,
        'registryCovenantId': 'ffff',
      });

      expect(await service.resolveName('kaspa'), isNull);
    });

    test('rethrows a server error', () async {
      final service = serviceAnswering({'error': 'boom'}, 500);

      await expectLater(
        service.resolveName('kaspa'),
        throwsA(isA<ApiException>()),
      );
    });

    test('fails a lookup with an unexpected shape', () async {
      final service = serviceOver((_) async => _json(['kaspa']));

      await expectLater(
        service.resolveName('kaspa'),
        throwsA(isA<FormatException>()),
      );

      final wrongAddress = serviceAnswering({'address': 42});

      await expectLater(
        wrongAddress.resolveName('kaspa'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('resolveName over a subname', () {
    Map<String, Object?> parent({
      Map<String, Object?>? records,
      bool card = true,
      bool decoded = true,
      bool live = true,
      bool covenant = false,
      String address = kAddress,
    }) => {
      'name': 'alice',
      'ownerType': covenant ? 4 : 0,
      'owner': 'abcd',
      if (!covenant) 'address': address,
      'deedAddress': 'kaspa:pzdeed',
      if (card)
        'card': {
          'key': 'abcd',
          'outpointTxid': 'ffff',
          'outpointIndex': 1,
          'value': 100000000,
          'spenderType': 0,
          'spender': 'abcd',
          'spenderAddress': address,
          'cardAddress': 'kaspa:pzcard',
          'recordsHash': 'eeee',
          'blob': 'a0',
          if (decoded) 'records': records ?? const <String, Object?>{},
          'live': live,
        },
      'registryCovenantId': 'ffff',
    };

    test(
      'reads the payee off the parent card, asking only for the parent',
      () async {
        final service = serviceAnswering(
          parent(
            records: {
              'sub:bob': {'opaque': kSchnorrValue},
            },
          ),
        );

        final resolution = await service.resolveName('bob.alice');

        expect(paths, ['/v1/names/alice']);
        expect(resolution?.name, 'bob.alice');
        expect(resolution?.display, 'bob.alice.k');
        expect(resolution?.address, kPayee);
      },
    );

    test(
      'renders the payee under the prefix the parent answered with',
      () async {
        final service = serviceAnswering(
          parent(
            address: kTestnetAddress,
            records: {
              'sub:bob': {'opaque': kSchnorrValue},
            },
          ),
        );

        final resolution = await service.resolveName('bob.alice');

        expect(resolution?.address, startsWith('kaspatest:'));
      },
    );

    test('answers null for a label the card does not hold', () async {
      final service = serviceAnswering(
        parent(
          records: {
            'sub:pay': {'opaque': kSchnorrValue},
            'primary': true,
          },
        ),
      );

      expect(await service.resolveName('bob.alice'), isNull);
    });

    test('answers null for a value that pays nobody', () async {
      // A covenant id, which no reader can pay
      final service = serviceAnswering(
        parent(
          records: {
            'sub:bob': {'opaque': '582104${'11' * 32}'},
          },
        ),
      );

      expect(await service.resolveName('bob.alice'), isNull);
    });

    test('answers null when the parent has no card', () async {
      final service = serviceAnswering(parent(card: false));

      expect(await service.resolveName('bob.alice'), isNull);
    });

    test('answers null for a card whose blob is not a record set', () async {
      // The indexer leaves the records out when it cannot decode the blob
      final service = serviceAnswering(parent(decoded: false));

      expect(await service.resolveName('bob.alice'), isNull);
    });

    test('answers null when a covenant owns the parent', () async {
      final service = serviceAnswering(
        parent(
          covenant: true,
          records: {
            'sub:bob': {'opaque': kSchnorrValue},
          },
        ),
      );

      expect(await service.resolveName('bob.alice'), isNull);
    });

    test('throws when the card is not the live one', () async {
      // The route serves the live card alone, so this is an indexer to ask
      // again rather than a label that pays nobody
      final service = serviceAnswering(
        parent(
          live: false,
          records: {
            'sub:bob': {'opaque': kSchnorrValue},
          },
        ),
      );

      await expectLater(
        service.resolveName('bob.alice'),
        throwsA(isA<FormatException>()),
      );
    });

    test('does not ask about an invalid label or parent', () async {
      final service = serviceAnswering(const {});

      expect(await service.resolveName('bob.-alice'), isNull);
      // A label under the suffix segment, which would otherwise read the name
      // `k` for every doubled-suffix typo
      expect(await service.resolveName('bob.alice.k'), isNull);
      expect(await service.resolveName('-bob.alice'), isNull);
      expect(await service.resolveName('${'z' * 65}.alice'), isNull);
      expect(paths, isEmpty);
    });
  });

  group('namesForAddress', () {
    test('orders names by display order', () async {
      final service = serviceAnswering({
        'ownerType': 0,
        'owner': 'abcd',
        'address': kAddress,
        'names': ['coinbase', 'kaspa', 'x'],
        'cards': [],
        'registryCovenantId': 'ffff',
      });

      expect(await service.namesForAddress(kAddress), [
        'x',
        'kaspa',
        'coinbase',
      ]);
      expect(paths, ['/v1/addresses/$kAddress']);
    });

    test('moves the primary name first', () async {
      final service = serviceAnswering({
        'names': ['coinbase', 'kaspa', 'x'],
        'cards': [
          {
            'name': 'kaspa',
            'records': {'url': 'https://kaspa.org', 'primary': true},
          },
        ],
      });

      expect(await service.namesForAddress(kAddress), [
        'kaspa',
        'x',
        'coinbase',
      ]);
    });

    test('takes the first primary name by display order', () async {
      final service = serviceAnswering({
        'names': ['coinbase', 'kaspa', 'x'],
        'cards': [
          {
            'name': 'coinbase',
            'records': {'primary': true},
          },
          {
            'name': 'kaspa',
            'records': {'primary': true},
          },
        ],
      });

      expect(await service.namesForAddress(kAddress), [
        'kaspa',
        'x',
        'coinbase',
      ]);
    });

    test('ignores cards that are not primary', () async {
      final service = serviceAnswering({
        'names': ['coinbase', 'kaspa'],
        'cards': [
          {
            'name': 'coinbase',
            'records': {'url': 'https://kaspa.org'},
          },
        ],
      });

      expect(await service.namesForAddress(kAddress), ['kaspa', 'coinbase']);
    });

    test('answers an empty list for an address without names', () async {
      final service = serviceAnswering({
        'ownerType': 0,
        'names': <String>[],
        'cards': <Object?>[],
      });

      expect(await service.namesForAddress(kAddress), isEmpty);
      expect(await service.displayNameForAddress(kAddress), isNull);
    });

    test('answers an empty list for an address the api rejects', () async {
      final service = serviceAnswering({'code': 'invalid_address'}, 400);

      expect(await service.namesForAddress(kAddress), isEmpty);
      expect(await service.displayNameForAddress(kAddress), isNull);
    });

    test('rethrows a server error', () async {
      final service = serviceAnswering({'error': 'boom'}, 500);

      await expectLater(
        service.namesForAddress(kAddress),
        throwsA(isA<ApiException>()),
      );
    });

    test('fails a lookup with an unexpected shape', () async {
      final service = serviceAnswering({'names': 'kaspa'});

      await expectLater(
        service.namesForAddress(kAddress),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('displayNameForAddress', () {
    test('is the first name in display form', () async {
      final service = serviceAnswering({
        'names': ['coinbase', 'kaspa', 'x'],
        'cards': [
          {
            'name': 'kaspa',
            'records': {'primary': true},
          },
        ],
      });

      expect(await service.displayNameForAddress(kAddress), 'kaspa.k');
    });
  });
}
