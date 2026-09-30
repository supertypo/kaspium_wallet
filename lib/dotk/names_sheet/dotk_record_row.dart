import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../app_styles.dart';
import '../../l10n/l10n.dart';
import '../../util/ui_util.dart';
import '../../util/util.dart';
import '../dotk_record_links.dart';

/// A label and a value. A tap opens [link] when there is one, and a long
/// press copies [copyText].
class DotkRecordRow extends ConsumerWidget {
  final String label;

  /// The card record the row shows, which dotk.name labels by name
  final String? recordKey;
  final Widget value;
  final String? link;
  final String? copyText;

  /// The value goes under the label instead of beside it
  final bool stacked;

  const DotkRecordRow({
    super.key,
    required this.label,
    required this.value,
    this.link,
    this.copyText,
    this.stacked = false,
  }) : recordKey = null;

  /// A record from a card, labelled and linked by dotk.name's rules
  DotkRecordRow.forRecord({
    super.key,
    required String this.recordKey,
    required Object recordValue,
    required this.value,
  }) : label = recordKey,
       // A long value, like a description, reads better under its label
       stacked = recordValue is String && recordValue.length > 30,
       link = recordValue is String
           ? DotkRecordLinks.linkOf(recordKey, recordValue)
           : null,
       copyText = recordValue is String ? recordValue : null;

  String _label(AppLocalizations l10n) =>
      switch (recordKey == null ? null : DotkRecordPreset.ofKey(recordKey!)) {
        .url => l10n.dotkRecordWebsite,
        .avatar => l10n.dotkRecordAvatar,
        .description => l10n.dotkRecordDescription,
        .email => l10n.dotkRecordEmail,
        .location => l10n.dotkRecordLocation,
        .github => l10n.dotkRecordGithub,
        .twitter => l10n.dotkRecordTwitter,
        .telegram => l10n.dotkRecordTelegram,
        .discord => l10n.dotkRecordDiscord,
        null => label,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final styles = ref.watch(stylesProvider);
    final l10n = l10nOf(context);

    final link = this.link;
    final copyText = this.copyText;
    final valueStyle = TextStyle(
      fontFamily: kDefaultFontFamily,
      fontSize: AppFontSizes.small,
      fontWeight: .w600,
      color: link != null ? theme.dotkAccent : theme.text,
      decoration: link != null ? TextDecoration.underline : null,
      decorationColor: theme.dotkAccent,
    );

    Future<void> copy() async {
      if (copyText == null) {
        return;
      }
      await Clipboard.setData(ClipboardData(text: copyText));
      UIUtil.showSnackbar(l10n.copied);
    }

    return Semantics(
      link: link != null,
      child: InkWell(
        onTap: switch (link == null ? null : Uri.tryParse(link)) {
          final uri? => () => openUri(uri),
          null => null,
        },
        onLongPress: copyText == null ? null : copy,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const .symmetric(vertical: 8),
            child: stacked
                ? Column(
                    crossAxisAlignment: .start,
                    children: [
                      // A record reads like the rows beside it, and a
                      // subname stands out as a name
                      Text(
                        _label(l10n),
                        style: recordKey == null
                            ? styles.textStyleSettingItemHeader.copyWith(
                                fontSize: AppFontSizes.small,
                              )
                            : styles.textStyleSettingItemSubheader.copyWith(
                                fontSize: AppFontSizes.small,
                              ),
                      ),
                      const SizedBox(height: 2),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: DefaultTextStyle.merge(
                          style: valueStyle,
                          child: value,
                        ),
                      ),
                    ],
                  )
                : Row(
                    crossAxisAlignment: .start,
                    children: [
                      // A custom key has no length limit
                      Flexible(
                        child: Text(
                          _label(l10n),
                          maxLines: 2,
                          overflow: .ellipsis,
                          style: styles.textStyleSettingItemSubheader.copyWith(
                            fontSize: AppFontSizes.small,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: DefaultTextStyle.merge(
                            style: valueStyle,
                            textAlign: .end,
                            child: value,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
