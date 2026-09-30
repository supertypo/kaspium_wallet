import 'package:flutter_test/flutter_test.dart';
import 'package:kaspium_wallet/dotk/dotk_record_edits.dart';
import 'package:kaspium_wallet/dotk/dotk_records.dart';
import 'package:kaspium_wallet/kaspa/kaspa.dart';

import 'dotk_fake_tx.dart';

void main() {
  test('touch only the primary entry, byte for byte', () {
    final without = DotkRecordEdits.withoutPrimary(primaryBlob);
    expect(DotkRecords.decode(without), {'url': 'https://kaspa.org'});
    expect(DotkRecordEdits.withPrimary(without), primaryBlob);
    expect(DotkRecordEdits.withPrimary(primaryBlob), same(primaryBlob));
    expect(DotkRecordEdits.withoutPrimary(without), same(without));

    // {z: 0x01 as a two-byte head, primary: false, a: [1]}
    final odd = hexToBytes('a3617a1801677072696d617279f461618101');
    expect(
      DotkRecordEdits.withPrimary(odd).hex,
      'a3617a1801677072696d617279f561618101',
    );
    final removed = DotkRecordEdits.withoutPrimary(odd);
    expect(removed.hex, 'a2617a180161618101');
    expect(DotkRecords.decode(removed).keys, ['z', 'a']);

    // The map head grows past 23 entries
    final entries = [
      for (var i = 0; i < 23; i++) [0x62, 0x6b, 0x61 + i, 0xf5],
    ];
    final blob = Uint8List.fromList([0xb7, for (final e in entries) ...e]);
    final set = DotkRecordEdits.withPrimary(blob);
    expect(set.sublist(0, 2), [0xb8, 24]);
    expect(DotkRecords.decode(set).length, 24);
    expect(DotkRecordEdits.withoutPrimary(set), blob);
  });
}
