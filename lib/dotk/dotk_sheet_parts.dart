import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_providers.dart';
import '../app_styles.dart';
import '../kaspa/kaspa.dart';
import '../util/numberutil.dart';
import 'dotk_registry.dart';

/// An amount with the network's coin symbol, like `40 KAS` or `40 TKAS`
String dotkAmount(BigInt raw, String symbol) =>
    '${NumberUtil.formatedAmount(Amount.raw(raw))} $symbol';

/// What an evicted reservation loses: the deposit goes to the devfund, and
/// the bond and the gap value go to whoever evicts it
BigInt dotkAtRisk(DotkParams? params) => params == null
    ? BigInt.zero
    : params.bond + params.deposit + params.gapValue;

/// The small capitals over a group in the .k name sheets
class DotkSection extends ConsumerWidget {
  final String title;

  const DotkSection(this.title, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final styles = ref.watch(stylesProvider);

    return Padding(
      padding: const .fromLTRB(4, 18, 4, 6),
      child: Semantics(
        header: true,
        child: Text(
          title.toUpperCase(),
          style: styles.textStyleSettingItemSubheader.copyWith(
            fontWeight: .w700,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }
}

class DotkBox extends ConsumerWidget {
  final List<Widget> children;

  const DotkBox({super.key, required this.children});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);

    return Container(
      decoration: BoxDecoration(
        color: theme.text05,
        // The fill alone barely shows on a light sheet
        border: .all(color: theme.text10),
        borderRadius: .circular(12),
      ),
      padding: const .symmetric(horizontal: 12, vertical: 4),
      child: Column(crossAxisAlignment: .stretch, children: children),
    );
  }
}

enum DotkNoticeKind { info, warning, danger }

class DotkNotice extends ConsumerWidget {
  final String text;
  final DotkNoticeKind kind;
  final String? action;
  final VoidCallback? onAction;

  const DotkNotice(
    this.text, {
    super.key,
    this.kind = .info,
    this.action,
    this.onAction,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final styles = ref.watch(stylesProvider);

    final color = switch (kind) {
      .info => theme.dotkAccent,
      .warning => theme.warning,
      .danger => theme.danger,
    };
    final action = this.action;

    return Container(
      padding: .directional(
        start: 14,
        top: 12,
        end: 8,
        bottom: action == null ? 12 : 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: kind == .info ? 0.06 : 0.1),
        border: .all(color: color.withValues(alpha: 0.5)),
        borderRadius: .circular(12),
      ),
      child: Column(
        crossAxisAlignment: .stretch,
        children: [
          Padding(
            padding: const .directional(end: 6),
            child: Text(
              text,
              style: styles.textStyleSettingItemSubheader.copyWith(
                fontSize: AppFontSizes.small,
                color: kind == .info ? theme.text : color,
              ),
            ),
          ),
          if (action != null)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  foregroundColor: color,
                  minimumSize: const Size(48, 48),
                ),
                child: Text(action.toUpperCase()),
              ),
            ),
        ],
      ),
    );
  }
}

class DotkValueRow extends ConsumerWidget {
  final String label;
  final String value;
  final bool bold;

  const DotkValueRow(this.label, this.value, {super.key, this.bold = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final styles = ref.watch(stylesProvider);

    final labelStyle = bold
        ? styles.textStyleSettingItemHeader.copyWith(
            fontSize: AppFontSizes.small,
            fontWeight: .w800,
          )
        : styles.textStyleSettingItemSubheader.copyWith(
            fontSize: AppFontSizes.small,
          );

    return Padding(
      padding: const .symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: .start,
        children: [
          Expanded(child: Text(label, style: labelStyle)),
          const SizedBox(width: 12),
          Flexible(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Text(
                value,
                textAlign: .end,
                style: styles.textStyleSettingItemHeader.copyWith(
                  fontSize: AppFontSizes.small,
                  fontWeight: bold ? .w800 : .w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
