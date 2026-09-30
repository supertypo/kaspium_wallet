import 'package:flutter_test/flutter_test.dart';
import 'package:kaspium_wallet/dotk/register_sheet/dotk_name_formatter.dart';

void main() {
  group('DotkNameFormatter', () {
    TextEditingValue type(String before, String after, {int? caret}) =>
        DotkNameFormatter().formatEditUpdate(
          TextEditingValue(text: before),
          TextEditingValue(
            text: after,
            selection: .collapsed(offset: caret ?? after.length),
          ),
        );

    test('keeps only what a name can hold, without the .k suffix', () {
      expect(type('', 'Hello World!').text, 'helloworld');
      expect(type('alice', 'alice.k').text, 'alice');
      expect(type('', 'Alice.K').text, 'alice');
      // A trailing dot stays until the k arrives
      expect(type('foo', 'foo.').text, 'foo.');
      expect(type('foo.', 'foo.k').text, 'foo');
    });

    test('keeps the caret on the same character', () {
      final kept = type('abd', 'abCd', caret: 3);
      expect(kept.text, 'abcd');
      expect(kept.selection.baseOffset, 3);
      final moved = type('ab', 'a!b', caret: 2);
      expect(moved.text, 'ab');
      expect(moved.selection.baseOffset, 1);
    });
  });
}
