import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaspium_wallet/dotk/dotk_registry.dart';
import 'package:kaspium_wallet/dotk/dotk_script.dart';
import 'package:kaspium_wallet/dotk/dotk_tx.dart';
import 'package:kaspium_wallet/dotk/dotk_tx_assemble.dart';
import 'package:kaspium_wallet/dotk/dotk_types.dart';
import 'package:kaspium_wallet/kaspa/kaspa.dart';

import 'dotk_fake_node.dart';
import 'dotk_fake_tx.dart';

// A subset of the @dotk/sdk conformance vectors, see its `_source`
final _vectors =
    jsonDecode(File('test/dotk/dotk_tx_vectors.json').readAsStringSync())
        as Map<String, dynamic>;

const _networks = {'mainnet': 'mainnet', 'testnet-10': 'testnet'};

Utxo _utxo(
  String address,
  String txId,
  int index,
  int amount,
  String spk, {
  String? covenantId,
}) => Utxo(
  address: address,
  outpoint: Outpoint(transactionId: txId, index: index),
  utxoEntry: UtxoEntry(
    amount: .from(amount),
    scriptPublicKey: ScriptPublicKey(
      scriptPublicKey: hexToBytes(spk),
      version: 0,
    ),
    blockDaaScore: .zero,
    isCoinbase: false,
    covenantId: covenantId == null ? null : hexToBytes(covenantId),
  ),
);

List<Utxo> _funding(DotkRegistry registry, Map<String, dynamic> v) {
  final spk = hexToBytes(v['fundingSpk'] as String);
  final address = Address.publicKey(
    prefix: registry.prefix,
    publicKey: spk.sublist(1, 33),
  ).encoded;
  return [
    for (final [txId, index, amount] in v['funding'] as List)
      _utxo(address, txId, index, amount, v['fundingSpk']),
  ];
}

ScriptPublicKey _spk(String hex) =>
    ScriptPublicKey(scriptPublicKey: hexToBytes(hex), version: 0);

/// The transaction parts the vectors' safe JSON pins
void _expectSafeJson(RawTransaction tx, String safeJson) {
  final json = jsonDecode(safeJson) as Map<String, dynamic>;
  expect(transactionIdV1(tx), json['id']);
  final inputs = json['inputs'] as List;
  expect(tx.inputs.length, inputs.length);
  for (final (at, input) in tx.inputs.indexed) {
    final expected = inputs[at] as Map<String, dynamic>;
    expect(input.previousOutpoint.transactionId, expected['transactionId']);
    expect(input.previousOutpoint.index, expected['index']);
    expect(input.computeBudget, expected['computeBudget']);
    expect(input.signatureScript.hex, expected['signatureScript']);
  }
  final outputs = json['outputs'] as List;
  expect(tx.outputs.length, outputs.length);
  for (final (at, output) in tx.outputs.indexed) {
    final expected = outputs[at] as Map<String, dynamic>;
    expect(output.value.toString(), expected['value']);
    expect(
      '0000${output.scriptPublicKey.scriptPublicKey.hex}',
      expected['scriptPublicKey'],
    );
    final covenant = expected['covenant'] as Map<String, dynamic>?;
    expect(output.covenant?.authorizingInput, covenant?['authorizingInput']);
    expect(output.covenant?.covenantId.hex, covenant?['covenantId']);
  }
  expect(tx.payload?.hex ?? '', json['payload']);
}

void _expectSighashes(RawTransaction tx, List sighashes) {
  final reused = SigHashReusedValues();
  for (final case_ in sighashes) {
    final hash = getSchnorrSignatureHash(
      tx: tx,
      inputIndex: case_['input'],
      hashType: .sigHashAll,
      reusedValues: reused,
    );
    expect(hash.hex, case_['schnorr'], reason: 'input ${case_['input']}');
  }
}

void main() {
  for (final MapEntry(key: network, value: networkId) in _networks.entries) {
    final v = _vectors[network] as Map<String, dynamic>;
    final registry = DotkRegistry.forNetworkId(networkId)!;

    group('dotk tx vectors on $network', () {
      // A section renamed upstream fails here rather than skipping its test
      if (network == 'mainnet') {
        test('holds every section', () {
          expect(
            v.keys,
            containsAll([
              'keyOf',
              'feeForName',
              'transferSigScript',
              'transferAssembly',
              'cardAssembly',
              'registrationAssembly',
              'storageMass',
            ]),
          );
        });
      }

      test('registry', () {
        expect(registry.covenantId, v['manifest']['registryCovenantId']);
        expect(registry.network, network);
        expect(ascii.decode(registry.cardMagic), 'dotk');
      });

      // Sections testnet-10 leaves out run on mainnet only
      if (v.containsKey('keyOf')) {
        test('keys and fees', () {
          for (final c in v['keyOf']) {
            expect(DotkState.keyOf(c['name']).hex, c['key']);
          }
          for (final c in v['feeForName']) {
            expect(
              registry.params.feeForName(c['name']),
              BigInt.from(c['fee']),
            );
          }
        });
      }

      if (v.containsKey('transferSigScript')) {
        test('transfer signature scripts', () {
          for (final c in v['transferSigScript']) {
            final sig = c['sig'] as String?;
            final script = DotkIntents.transferSigScript(
              registry: registry,
              state: DotkState.activeDeed(
                c['name'],
                c['ownerType'],
                hexToBytes(c['owner']),
              ),
              newOwnerType: c['newOwnerType'],
              newOwner: hexToBytes(c['newOwner']),
              signature: sig == null ? null : hexToBytes(sig),
              unsigned: sig == null,
              witness: c['witness'],
            );
            expect(script.hex, c['sigScript']);
          }
        });
      }

      test('addresses and scripts', () {
        for (final c in v['deedAddress']) {
          final state = DotkState.activeDeed(
            c['name'],
            c['ownerType'],
            hexToBytes(c['owner']),
          );
          expect(state.hex, c['state']);
          expect(registry.deedAddress(state).encoded, c['address']);
        }
        for (final c in v['gapAddress']) {
          final state = DotkState.gap(hexToBytes(c['lo']), hexToBytes(c['hi']));
          expect(state.hex, c['state']);
          expect(registry.gapAddress(state).encoded, c['address']);
        }
        for (final c in v['card']) {
          final blob = hexToBytes(c['blob']);
          final state = DotkCardState.forBlob(
            c['name'],
            blob,
            spenderType: c['spenderType'],
            spender: hexToBytes(c['spender']),
          );
          expect(state.records.hex, c['recordsHash']);
          expect(state.encode().hex, c['state']);
          expect(state.redeemScript(registry.cardMagic).hex, c['redeemScript']);
          expect(
            state.scriptPublicKey(registry.cardMagic).scriptPublicKey.hex,
            c['spk'],
          );
          expect(state.address(registry).encoded, c['address']);
          expect(
            state.sweepSigScript(registry.cardMagic).hex,
            c['sweepSigScript'],
          );
          expect(
            DotkCardMint(state, blob).payload(registry.cardMagic).hex,
            c['payload'],
          );
        }
      });

      DotkAssembled assembleTransfer(Map<String, dynamic> c) {
        final owner = hexToBytes(c['owner']);
        final deedState = DotkState.activeDeed(
          c['name'],
          c['ownerType'],
          owner,
        );
        final [deedTxId, deedIndex] = c['deedOutpoint'] as List;
        final deed = DotkDeed(
          name: c['name'],
          ownerType: c['ownerType'],
          owner: owner,
          utxo: _utxo(
            registry.deedAddress(deedState).encoded,
            deedTxId,
            deedIndex,
            registry.params.bond.toInt(),
            registry.deedScriptPublicKey(deedState).scriptPublicKey.hex,
            covenantId: registry.covenantId,
          ),
        );

        final cards = c['cards'] as Map<String, dynamic>?;
        final mint = cards?['mint'] as Map<String, dynamic>?;
        final sweep = [
          for (final s in (cards?['sweep'] as List?) ?? const [])
            () {
              final state = DotkCardState(
                key: DotkState.keyOf(c['name']),
                records: hexToBytes(s['recordsHash']),
                spenderType: s['spenderType'],
                spender: hexToBytes(s['spender']),
              );
              final [txId, index] = s['outpoint'] as List;
              return DotkCardSweep(
                utxo: _utxo(
                  state.address(registry).encoded,
                  txId,
                  index,
                  s['value'],
                  state.scriptPublicKey(registry.cardMagic).scriptPublicKey.hex,
                ),
                state: state,
              );
            }(),
        ];
        DotkCardMint? cardMint;
        if (mint != null) {
          final blob = encodeRecords(mint['records'], sorted: true);
          cardMint = DotkCardMint(
            DotkCardState.forBlob(
              c['name'],
              blob,
              spenderType: mint['spenderType'],
              spender: hexToBytes(mint['spender']),
            ),
            blob,
          );
        }

        final intent = DotkIntents.transfer(
          registry: registry,
          deed: deed,
          ownerAddress: Address.publicKey(
            prefix: registry.prefix,
            publicKey: owner,
          ),
          newOwnerType: c['newOwnerType'],
          newOwner: hexToBytes(c['newOwner']),
          cards: DotkCardPlan(mint: cardMint, sweep: sweep),
        );
        return DotkAssembler.assemble(
          intent,
          funding: _funding(registry, c),
          changeScript: _spk(c['changeSpk']),
          feerate: (c['feerate'] as num).toDouble(),
          readyMass: _readyMass(c),
        );
      }

      if (v.containsKey('transferAssembly')) {
        test('transfer and card assembly', () {
          for (final key in ['transferAssembly', 'cardAssembly']) {
            for (final c in v[key]) {
              final assembled = assembleTransfer(c);
              expect(assembled.masses.size, BigInt.from(c['size']));
              expect(assembled.masses.compute, BigInt.from(c['computeMass']));
              expect(
                assembled.masses.transient,
                BigInt.from(c['transientMass']),
              );
              expect(assembled.masses.fee, BigInt.from(c['feeMass']));
              expect(assembled.fee, BigInt.from(c['fee']));
              expect(
                assembled.change,
                c['changeValue'] == null ? null : BigInt.from(c['changeValue']),
              );
              _expectSafeJson(assembled.tx, c['safeJson']);
              _expectSighashes(assembled.tx, c['sighashes']);
            }
          }
        });
      }

      if (v.containsKey('registrationAssembly')) {
        test('registration split and activation', () {
          for (final c in v['registrationAssembly']) {
            final gapCase = c['gap'] as Map<String, dynamic>;
            final lo = hexToBytes(gapCase['lo']);
            final hi = hexToBytes(gapCase['hi']);
            final [gapTxId, gapIndex] = gapCase['outpoint'] as List;
            final gap = DotkGap(
              lo: lo,
              hi: hi,
              utxo: _utxo(
                registry.gapAddress(DotkState.gap(lo, hi)).encoded,
                gapTxId,
                gapIndex,
                registry.params.gapValue.toInt(),
                gapCase['spk'],
                covenantId: registry.covenantId,
              ),
            );
            final changeSpk = hexToBytes(c['changeSpk']);
            final built = DotkRegistration.build(
              registry: registry,
              gap: gap,
              name: c['name'],
              ownerType: c['ownerType'],
              owner: hexToBytes(c['owner']),
              funding: _funding(registry, c),
              changeAddress: Address.publicKey(
                prefix: registry.prefix,
                publicKey: changeSpk.sublist(1, 33),
              ),
              feerate: (c['feerate'] as num).toDouble(),
              readyMass: _readyMass(c),
            );

            final split = built.split;
            if (c == v['registrationAssembly'].first) {
              // A coin that joins stays while the fee settles back down
              final intent = DotkIntents.split(
                registry: registry,
                gap: gap,
                name: c['name'],
                ownerType: c['ownerType'],
                owner: hexToBytes(c['owner']),
              );
              final [coin] = _funding(registry, c);
              Utxo sized(int index, BigInt amount) => coin.copyWith(
                outpoint: Outpoint(transactionId: 'bb' * 32, index: index),
                utxoEntry: coin.utxoEntry.copyWith(amount: amount),
              );
              final full = DotkAssembler.assemble(
                intent,
                funding: [
                  sized(1, intent.requiredFunding + BigInt.from(14970254)),
                  sized(2, BigInt.from(500000000)),
                ],
                changeScript: _spk(c['changeSpk']),
                feerate: 150,
                readyMass: BigInt.from(500001),
              );
              expect(full.fundingInputs, hasLength(2));

              DotkAssembled congested(List<Utxo> funding, double feerate) =>
                  DotkAssembler.assemble(
                    intent,
                    funding: funding,
                    changeScript: _spk(c['changeSpk']),
                    feerate: feerate,
                    readyMass: BigInt.from(500001),
                  );
              // Where every pass needs more than the ceiling, more funds
              // cannot help
              expect(
                () => congested([
                  for (var i = 0; i < 360; i++) sized(i + 3, .from(12000000)),
                ], 1000),
                throwsA(isA<DotkFeeCeilingError>()),
              );
              // Change just over the runaway, which another coin remedies
              expect(
                () => congested([
                  sized(3, intent.requiredFunding + .from(47473175)),
                ], 500),
                throwsA(isA<DotkChangeTooSmallError>()),
              );
            }
            expect(
              split.tx.inputs.first.signatureScript.hex,
              c['splitSigScript'],
            );
            expect(split.tx.inputs.first.computeBudget, 150);
            for (final (at, [value, spk])
                in (c['splitOutputs'] as List).indexed) {
              expect(split.tx.outputs[at].value, BigInt.from(value));
              expect(
                split.tx.outputs[at].scriptPublicKey.scriptPublicKey.hex,
                spk,
              );
              expect(
                split.tx.outputs[at].covenant?.covenantId.hex,
                registry.covenantId,
              );
            }
            expect(split.fee, BigInt.from(c['splitFee']));
            final [splitChangeIndex, splitChange] = c['splitChange'] as List;
            expect(split.changeIndex, splitChangeIndex);
            expect(split.change, BigInt.from(splitChange));

            final activate = built.activate;
            expect(
              activate.tx.inputs.first.signatureScript.hex,
              c['activateSigScript'],
            );
            expect(
              activate.tx.inputs.first.previousOutpoint.transactionId,
              split.id,
            );
            expect(
              activate.tx.inputs[1].previousOutpoint.index,
              splitChangeIndex,
            );
            for (final (at, [value, spk])
                in (c['activateOutputs'] as List).indexed) {
              expect(activate.tx.outputs[at].value, BigInt.from(value));
              expect(
                activate.tx.outputs[at].scriptPublicKey.scriptPublicKey.hex,
                spk,
              );
            }
            expect(activate.fee, BigInt.from(c['activateFee']));
            final [activateChangeIndex, activateChange] =
                c['activateChange'] as List;
            expect(activate.changeIndex, activateChangeIndex);
            expect(activate.change, BigInt.from(activateChange));
            expect(built.tier, BigInt.from(c['feeTier']));
            expect(
              DotkIntents.activate(
                registry: registry,
                pending: built.pending,
                name: c['name'],
                ownerType: c['ownerType'],
                owner: hexToBytes(c['owner']),
              ).requiredFunding,
              BigInt.from(c['activateRequiredFunding']),
            );
            expect(
              DotkIntents.split(
                registry: registry,
                gap: gap,
                name: c['name'],
                ownerType: c['ownerType'],
                owner: hexToBytes(c['owner']),
              ).requiredFunding,
              BigInt.from(c['splitRequiredFunding']),
            );
          }
        });
      }

      if (v.containsKey('storageMass')) {
        test('storage mass', () {
          for (final c in v['storageMass']) {
            RawTransaction txOf(List ins, List outs) => RawTransaction(
              version: 1,
              inputs: [
                for (final (at, i) in ins.indexed)
                  RawInput(
                    address: Address.publicKey(
                      prefix: .kaspa,
                      publicKey: Uint8List(32),
                    ),
                    previousOutpoint: Outpoint(
                      transactionId: '00' * 32,
                      index: at,
                    ),
                    signatureScript: Uint8List(0),
                    sequence: .zero,
                    utxoEntry: UtxoEntry(
                      amount: .from(i['amount']),
                      scriptPublicKey: _spk(i['spk']),
                      blockDaaScore: .zero,
                      isCoinbase: false,
                      covenantId: i['covenant'] == true ? Uint8List(32) : null,
                    ),
                  ),
              ],
              outputs: [
                for (final o in outs)
                  RawOutput(
                    value: .from(o['amount']),
                    scriptPublicKey: _spk(o['spk']),
                    covenant: o['covenant'] == true
                        ? CovenantBinding(
                            authorizingInput: 0,
                            covenantId: Uint8List(32),
                          )
                        : null,
                  ),
              ],
              lockTime: .zero,
              subnetworkId: kSubnetworkIdNative,
              gas: .zero,
            );
            final mass = DotkFees.storageMassOf(txOf(c['ins'], c['outs']));
            expect(
              mass,
              c['mass'] == null ? null : BigInt.from(c['mass']),
              reason: c['why'],
            );
          }
        });
      }
    });
  }

  group('dotk signing', () {
    final registry = testRegistry;
    final key = TestKey('11' * 32);
    final privateKey = key.privateKey;
    final publicKey = key.publicKey;
    final wallet = key.address;

    test('signs the deed and funding, and refuses a wrong signature', () async {
      final state = DotkState.activeDeed(
        'kaspa',
        DotkOwnerType.schnorr,
        publicKey,
      );
      final intent = DotkIntents.transfer(
        registry: registry,
        deed: DotkDeed(
          name: 'kaspa',
          ownerType: DotkOwnerType.schnorr,
          owner: publicKey,
          utxo: _utxo(
            registry.deedAddress(state).encoded,
            'aa' * 32,
            0,
            registry.params.bond.toInt(),
            registry.deedScriptPublicKey(state).scriptPublicKey.hex,
            covenantId: registry.covenantId,
          ),
        ),
        ownerAddress: wallet,
        newOwnerType: DotkOwnerType.schnorr,
        newOwner: hexToBytes('22' * 32),
      );
      final assembled = DotkAssembler.assemble(
        intent,
        funding: [
          _utxo(
            wallet.encoded,
            'bb' * 32,
            1,
            1000000000,
            payToAddressScript(wallet).scriptPublicKey.hex,
          ),
        ],
        changeScript: payToAddressScript(wallet),
        feerate: 1,
      );
      final signed = await DotkSigner.sign(
        assembled,
        (hash, address) async {
          expect(address, wallet);
          return signSchnorr(hash: hash, privateKey: privateKey);
        },
      );

      final deedScript = signed.inputs[0].signatureScript;
      expect(deedScript.length, assembled.tx.inputs[0].signatureScript.length);
      expect(DotkScript.hasPlaceholder(deedScript), isFalse);
      final funding = signed.inputs[1].signatureScript;
      expect(funding.length, DotkFees.fundingSigScriptLength);
      expect(funding.first, 0x41);
      expect(funding.last, kSigHashAll);
      expect(transactionIdV1(signed), assembled.id);
      expect(DotkFees.massesOf(signed).size, assembled.masses.size);

      await expectLater(
        DotkSigner.sign(
          assembled,
          (hash, address) async =>
              signSchnorr(hash: Uint8List(32), privateKey: privateKey),
        ),
        throwsA(isA<DotkTxError>()),
      );
    });
  });
}

BigInt? _readyMass(Map<String, dynamic> c) => switch (c['readyMass']) {
  final num mass => BigInt.from(mass),
  _ => null,
};
