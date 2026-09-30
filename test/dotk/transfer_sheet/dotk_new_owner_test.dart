import 'package:flutter_test/flutter_test.dart';
import 'package:kaspium_wallet/dotk/transfer_sheet/dotk_new_owner.dart';
import 'package:kaspium_wallet/kaspa/kaspa.dart';

const kSchnorr =
    'kaspa:qpvtxyhfm0x63y97g2ktamen5ngpdmjwpslcf92quu5x5e5ag3uezpj2gt9km';
const kOther =
    'kaspa:qpsk3cj9pr4dmexwcuj37ma3nm2075ht2yara3xxk4twufmv7kd27vpczqyjd';

void main() {
  group('parseNewOwner', () {
    (Address?, DotkNewOwnerError?) parse(
      String text, {
      String owner = kOther,
    }) => parseNewOwner(text, prefix: .kaspa, owner: owner);

    final ecdsa = Address.pubKeyECDSA(
      prefix: .kaspa,
      publicKey: Uint8List.fromList([0x02, ...List.filled(32, 7)]),
    ).encoded;
    final script = Address.scriptHash(
      prefix: .kaspa,
      hash: Uint8List.fromList(List.filled(32, 9)),
    ).encoded;
    final testnet = Address.decodeAddress(kSchnorr).when(
      publicKey: (_, key) =>
          Address.publicKey(prefix: .kaspaTest, publicKey: key).encoded,
      pubKeyECDSA: (_, _) => '',
      scriptHash: (_, _) => '',
    );

    test('accepts a Schnorr or ECDSA address, trimmed', () {
      final (address, error) = parse('  $kSchnorr \n');
      expect(error, isNull);
      expect(address?.encoded, kSchnorr);
      expect(parse(ecdsa).$2, isNull);
    });

    test('names why it refuses an owner', () {
      expect(parse('bob').$2, DotkNewOwnerError.notAddress);
      expect(parse('').$2, DotkNewOwnerError.notAddress);
      expect(parse(testnet).$2, DotkNewOwnerError.otherNetwork);
      expect(parse(script).$2, DotkNewOwnerError.scriptAddress);
      expect(parse(kSchnorr, owner: kSchnorr).$2, DotkNewOwnerError.sameOwner);
    });
  });
}
