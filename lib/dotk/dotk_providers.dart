import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core_providers.dart';
import '../rpc/rpc_providers.dart';
import '../settings/settings_providers.dart';
import '../wallet_address/wallet_address_providers.dart';
import '../wallet_auth/wallet_auth_providers.dart';
import 'dotk_names_notifier.dart';
import 'dotk_proof.dart';
import 'dotk_registry.dart';
import 'dotk_service.dart';
import 'dotk_wallet_names_notifier.dart';

final dotkServiceProvider = Provider((ref) {
  final enabled = ref.watch(dotkEnabledProvider);
  final apiUrl = ref.watch(dotkApiUrlProvider);

  return DotkService.url(enabled ? apiUrl : '');
});

final dotkProverProvider = Provider.autoDispose((ref) {
  final networkId = ref.watch(networkIdProvider);
  final registry = DotkRegistry.forNetworkId(networkId);
  if (registry == null) {
    return null;
  }

  return DotkProver(
    ref.watch(kaspaRpcProvider),
    registry: registry,
    prefix: ref.watch(addressPrefixProvider),
  );
});

final dotkNamesProvider = ChangeNotifierProvider((ref) {
  final service = ref.watch(dotkServiceProvider);
  final log = ref.read(loggerProvider);

  return DotkNamesNotifier(
    service,
    prover: () => ref.read(dotkProverProvider),
    log: log,
  );
});

final dotkNameForAddressProvider = Provider.family<String?, String>((
  ref,
  address,
) {
  final names = ref.watch(dotkNamesProvider);

  return names.nameForAddress(address);
});

/// Whether the wallet can show the names its addresses own: lookups are on
/// and the network has a registry
final dotkNamesAvailableProvider = Provider.autoDispose((ref) {
  final service = ref.watch(dotkServiceProvider);
  final networkId = ref.watch(networkIdProvider);

  return service.isEnabled && DotkRegistry.forNetworkId(networkId) != null;
});

final dotkWalletNamesProvider = ChangeNotifierProvider.autoDispose((ref) {
  final service = ref.watch(dotkServiceProvider);
  final log = ref.read(loggerProvider);
  // A scan belongs to one wallet on one network
  ref.watch(walletProvider);
  ref.watch(networkIdProvider);
  ref.keepAlive();

  return DotkWalletNamesNotifier(
    service,
    prover: () => ref.read(dotkProverProvider),
    addresses: () => ref.read(addressNotifierProvider).allAddresses,
    log: log,
  );
});
