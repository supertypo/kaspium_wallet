/// The chain stores the bare name, like `kaspa`, and the `.k` suffix is added
/// for display. Wallet input is the exception: the suffix is required there,
/// because the same field also takes addresses and `@contacts`.
class DotkName {
  static const suffix = '.k';

  static const maxLength = 32;

  static bool isValid(String bare) {
    if (bare.isEmpty || bare.length > maxLength) {
      return false;
    }
    if (bare.startsWith('-') || bare.endsWith('-')) {
      return false;
    }
    for (final unit in bare.codeUnits) {
      final allowed =
          (unit >= 0x61 && unit <= 0x7a) || // a-z
          (unit >= 0x30 && unit <= 0x39) || // 0-9
          unit == 0x2d; // -
      if (!allowed) {
        return false;
      }
    }
    return true;
  }

  static String? tryNormalize(String text) {
    final folded = text.trim().toLowerCase();
    if (!folded.endsWith(suffix)) {
      return null;
    }
    final bare = folded.substring(0, folded.length - suffix.length);

    return isValid(bare) ? bare : null;
  }

  static bool isName(String text) => tryNormalize(text) != null;

  static String display(String bare) => '$bare$suffix';

  static int displayOrder(String a, String b) {
    final byLength = a.length.compareTo(b.length);

    return byLength != 0 ? byLength : a.compareTo(b);
  }
}
