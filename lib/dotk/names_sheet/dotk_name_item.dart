import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../app_styles.dart';
import '../../l10n/l10n.dart';
import '../../widgets/address_widgets.dart';
import '../dotk_names.dart';
import '../dotk_owned_name.dart';
import '../dotk_proven_name.dart';
import '../dotk_registration_notifier.dart';
import 'dotk_primary_chip.dart';

class DotkNameItem extends ConsumerWidget {
  final DotkOwnedName name;

  /// A chip shown instead of the primary chip, as for a name in transfer
  final String? status;

  /// Shown instead of the owner's address
  final String? subtitle;
  final VoidCallback? onPressed;

  const DotkNameItem({
    super.key,
    required this.name,
    this.status,
    this.subtitle,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final styles = ref.watch(stylesProvider);

    final walletAddress = ref.watch(
      addressNotifierProvider.select(
        (notifier) => notifier.getAddress(name.address),
      ),
    );
    final label = subtitle ?? walletAddress?.name ?? '';
    final shortName = walletAddress?.getShortName().toUpperCase() ?? '';
    final pending = status != null;

    final nameStyle = TextStyle(
      fontFamily: kDefaultFontFamily,
      fontSize: AppFontSizes.medium,
      fontWeight: .w700,
      color: pending ? theme.text60 : theme.dotkAccent,
    );

    return TextButton(
      style: styles.defaultTextButtonStyle,
      onPressed: pending ? null : onPressed,
      child: Container(
        constraints: const BoxConstraints(minHeight: 72),
        padding: const .symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: .center,
              decoration: BoxDecoration(
                color: theme.text05,
                border: .all(color: theme.text10),
                borderRadius: .circular(10),
              ),
              child: Text(
                shortName,
                style: styles.textStyleAccountShortName.copyWith(
                  color: theme.text60,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: .start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: .center,
                    children: [
                      pending
                          ? Text(
                              DotkName.isolated(DotkName.display(name.name)),
                              style: nameStyle,
                            )
                          : DotkProvenName(
                              DotkName.display(name.name),
                              style: nameStyle,
                              textAlign: .start,
                            ),
                      if (status != null)
                        _StatusChip(status!)
                      else
                        DotkPrimaryChip(name.primary),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: styles.textStyleSettingItemSubheader,
                  ),
                  if (!pending)
                    AddressOneLineText(
                      address: name.address,
                      type: .PRIMARY60,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends ConsumerWidget {
  final String text;

  const _StatusChip(this.text);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);

    return Container(
      padding: const .symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: theme.text10,
        borderRadius: .circular(9),
      ),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontFamily: kDefaultFontFamily,
          fontSize: 10,
          fontWeight: .w800,
          letterSpacing: 0.4,
          color: theme.text,
        ),
      ),
    );
  }
}

/// A registration the wallet runs or that stopped, in the Names list
class DotkRegistrationItem extends ConsumerWidget {
  final DotkRegistrationEntry entry;
  final VoidCallback? onPressed;

  const DotkRegistrationItem({super.key, required this.entry, this.onPressed});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final styles = ref.watch(stylesProvider);
    final l10n = l10nOf(context);

    final walletAddress = ref.watch(
      addressNotifierProvider.select(
        (notifier) => notifier.getAddress(entry.owner),
      ),
    );

    return TextButton(
      style: styles.defaultTextButtonStyle,
      onPressed: onPressed,
      child: Container(
        constraints: const BoxConstraints(minHeight: 72),
        padding: const .symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: .center,
              decoration: BoxDecoration(
                color: theme.text05,
                border: .all(color: theme.text10),
                borderRadius: .circular(10),
              ),
              child: Text(
                walletAddress?.getShortName().toUpperCase() ?? '',
                style: styles.textStyleAccountShortName.copyWith(
                  color: theme.text60,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: .start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: .center,
                    children: [
                      Text(
                        DotkName.isolated(DotkName.display(entry.name)),
                        style: TextStyle(
                          fontFamily: kDefaultFontFamily,
                          fontSize: AppFontSizes.medium,
                          fontWeight: .w700,
                          color: theme.text60,
                        ),
                      ),
                      _StatusChip(switch (entry.stage) {
                        .failed => l10n.dotkStopped,
                        .done => l10n.dotkListing,
                        _ => l10n.dotkRegistering,
                      }),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    walletAddress?.name ?? '',
                    style: styles.textStyleSettingItemSubheader,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
