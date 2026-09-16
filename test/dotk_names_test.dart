import 'package:flutter_test/flutter_test.dart';
import 'package:kaspium_wallet/dotk/dotk_names.dart';

void main() {
  group('isValid', () {
    test('accepts letters, digits and inner hyphens', () {
      expect(DotkName.isValid('kaspa'), isTrue);
      expect(DotkName.isValid('x'), isTrue);
      expect(DotkName.isValid('0'), isTrue);
      expect(DotkName.isValid('kas-pa'), isTrue);
      expect(DotkName.isValid('a-b-c-1'), isTrue);
    });

    test('rejects an empty name', () {
      expect(DotkName.isValid(''), isFalse);
    });

    test('accepts 32 bytes and rejects 33', () {
      expect(DotkName.isValid('a' * 32), isTrue);
      expect(DotkName.isValid('a' * 33), isFalse);
      expect(DotkName.maxLength, 32);
    });

    test('rejects hyphens at the edges', () {
      expect(DotkName.isValid('-kaspa'), isFalse);
      expect(DotkName.isValid('kaspa-'), isFalse);
      expect(DotkName.isValid('-'), isFalse);
    });

    test('rejects anything outside a-z 0-9 and hyphen', () {
      expect(DotkName.isValid('Kaspa'), isFalse);
      expect(DotkName.isValid('kas pa'), isFalse);
      expect(DotkName.isValid('kas_pa'), isFalse);
      expect(DotkName.isValid('kas.pa'), isFalse);
      expect(DotkName.isValid('kaspa.k'), isFalse);
      expect(DotkName.isValid('kaspa!'), isFalse);
    });
  });

  group('tryNormalize', () {
    test('folds case and the whitespace around the name', () {
      expect(DotkName.tryNormalize('kaspa.k'), 'kaspa');
      expect(DotkName.tryNormalize('KASPA.K'), 'kaspa');
      expect(DotkName.tryNormalize('  Kaspa.k  '), 'kaspa');
    });

    test('requires the suffix', () {
      expect(DotkName.tryNormalize('kaspa'), isNull);
      expect(DotkName.tryNormalize('kaspa.'), isNull);
      expect(DotkName.tryNormalize('kaspa.kk'), isNull);
      expect(DotkName.tryNormalize('kaspa.k.'), isNull);
    });

    test('rejects an empty name and a bare suffix', () {
      expect(DotkName.tryNormalize('.k'), isNull);
      expect(DotkName.tryNormalize(''), isNull);
      expect(DotkName.tryNormalize('   '), isNull);
    });

    test('rejects a name that is invalid without the suffix', () {
      expect(DotkName.tryNormalize('-kaspa.k'), isNull);
      expect(DotkName.tryNormalize('kaspa-.k'), isNull);
      expect(DotkName.tryNormalize('kas pa.k'), isNull);
      expect(DotkName.tryNormalize('${'a' * 33}.k'), isNull);
      expect(DotkName.tryNormalize('${'a' * 32}.k'), 'a' * 32);
    });

    test('is not confused by an address or a contact', () {
      expect(DotkName.tryNormalize('kaspa:qz0123'), isNull);
      expect(DotkName.tryNormalize('@KaspiumTeam'), isNull);
    });
  });

  test('isName follows tryNormalize', () {
    expect(DotkName.isName('Kaspa.k'), isTrue);
    expect(DotkName.isName('kaspa'), isFalse);
  });

  test('display adds the suffix', () {
    expect(DotkName.display('kaspa'), 'kaspa.k');
    expect(DotkName.suffix, '.k');
  });

  group('displayOrder', () {
    test('sorts by length first, then by codepoint', () {
      final names = ['kaspa', 'x', 'coinbase', 'ab', 'aa', '0', 'a-b'];
      names.sort(DotkName.displayOrder);

      expect(names, ['0', 'x', 'aa', 'ab', 'a-b', 'kaspa', 'coinbase']);
    });

    test('is zero for the same name', () {
      expect(DotkName.displayOrder('kaspa', 'kaspa'), 0);
    });
  });
}
