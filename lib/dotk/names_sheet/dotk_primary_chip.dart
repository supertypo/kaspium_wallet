import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../app_styles.dart';
import '../../l10n/l10n.dart';
import '../dotk_owned_name.dart';

/// PRIMARY in the accent for an address's primary name, and in grey for a
/// name whose card sets primary but lost to one that set it later
class DotkPrimaryChip extends ConsumerWidget {
  final DotkPrimary primary;

  const DotkPrimaryChip(this.primary, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final l10n = l10nOf(context);

    if (primary == .none) {
      return const SizedBox();
    }
    final winner = primary == .winner;
    final color = winner ? theme.dotkAccent : theme.text;

    return Semantics(
      label: winner ? l10n.dotkPrimary : l10n.dotkOlderPrimary,
      child: ExcludeSemantics(
        child: Container(
          padding: const .symmetric(horizontal: 7, vertical: 1),
          decoration: BoxDecoration(
            color: winner
                ? theme.dotkAccent.withValues(alpha: 0.14)
                : theme.text10,
            borderRadius: .circular(9),
          ),
          child: Text(
            (winner ? l10n.dotkPrimary : l10n.dotkOlderPrimary).toUpperCase(),
            style: TextStyle(
              fontFamily: kDefaultFontFamily,
              fontSize: 10,
              fontWeight: .w800,
              letterSpacing: 0.4,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}
