import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'dotk_names.dart';

/// Marks a name the wallet's node proved
const kDotkProvenIcon = Icons.verified_user;

class DotkProvenName extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final TextAlign textAlign;

  const DotkProvenName(
    this.text, {
    super.key,
    this.style,
    this.textAlign = .center,
  });

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(this.style);

    return Semantics(
      label: '${l10nOf(context).dotkProven}, $text',
      excludeSemantics: true,
      child: Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: .middle,
              child: Icon(
                kDotkProvenIcon,
                size: style.fontSize,
                color: style.color,
              ),
            ),
            TextSpan(text: ' ${DotkName.isolated(text)}'),
          ],
        ),
        style: style,
        textAlign: textAlign,
      ),
    );
  }
}
