import 'package:flutter/services.dart';

import '../dotk_names.dart';

/// Lower case letters, digits and dashes, as a name holds them. A typed or
/// pasted `.k` suffix is dropped, and the caret stays where the user put it.
class DotkNameFormatter extends TextInputFormatter {
  static final _disallowed = RegExp(r'[^a-z0-9-]');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var text = newValue.text.toLowerCase();
    if (text.endsWith(DotkName.suffix)) {
      text = text.substring(0, text.length - DotkName.suffix.length);
    }
    // A dot waits for the k that makes it a suffix
    final dot = text.endsWith('.');
    text = text.replaceAll(_disallowed, '') + (dot ? '.' : '');
    if (text == newValue.text) {
      return newValue;
    }

    final removed = newValue.text.length - text.length;
    final offset = (newValue.selection.baseOffset - removed).clamp(
      0,
      text.length,
    );
    return TextEditingValue(
      text: text,
      selection: .collapsed(offset: offset),
    );
  }
}
