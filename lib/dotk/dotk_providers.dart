import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core_providers.dart';
import '../settings/settings_providers.dart';
import 'dotk_names_notifier.dart';
import 'dotk_service.dart';

final dotkServiceProvider = Provider((ref) {
  final enabled = ref.watch(dotkEnabledProvider);
  final apiUrl = ref.watch(dotkApiUrlProvider);

  return DotkService.url(enabled ? apiUrl : '');
});

final dotkNamesProvider = ChangeNotifierProvider((ref) {
  final service = ref.watch(dotkServiceProvider);
  final log = ref.read(loggerProvider);

  return DotkNamesNotifier(service, log: log);
});

final dotkNameForAddressProvider = Provider.family<String?, String>((
  ref,
  address,
) {
  final names = ref.watch(dotkNamesProvider);

  return names.nameForAddress(address);
});
