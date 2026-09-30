import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_styles.dart';
import '../core/core_providers.dart';
import '../l10n/l10n.dart';

/// The dotk logo as on dotk.name. It holds its own colors, so it needs no
/// light variant. Screen readers skip it; the text beside it names it.
class DotkLogo extends StatelessWidget {
  final double size;

  const DotkLogo({super.key, this.size = 22});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      size: Size.square(size),
      painter: const _DotkLogoPainter(),
    ),
  );
}

/// The dot.k lockup: the logo followed by the word dot.k, read as "dot k"
class DotkWordmark extends ConsumerWidget {
  final double logoSize;
  final double gap;

  /// The word's style, whose color gives way to the dotk ink and accent
  final TextStyle? style;

  const DotkWordmark({
    super.key,
    this.logoSize = 22,
    this.gap = 6,
    this.style,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    final style =
        (this.style ??
                const TextStyle(fontFamily: kDefaultFontFamily, fontSize: 17))
            .copyWith(fontWeight: .w700, color: theme.dotkInk);

    return Semantics(
      label: l10nOf(context).dotkNameLabel,
      container: true,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: .min,
          children: [
            DotkLogo(size: logoSize),
            SizedBox(width: gap),
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'dot'),
                  TextSpan(
                    text: '.k',
                    style: TextStyle(color: theme.dotkAccent),
                  ),
                ],
              ),
              style: style,
            ),
          ],
        ),
      ),
    );
  }
}

class _DotkLogoPainter extends CustomPainter {
  // The SVG's viewBox is 128 by 128, centred on (64, 64).
  static const _frame = 128.0;
  static const _center = Offset(64, 64);

  static const _disc = Color(0xff071c19);
  static const _ringStart = Color(0xff89f1dd);
  static const _ringEnd = Color(0xff26b998);
  static const _dot = Color(0xffa5f7e6);
  static const _k = Color(0xff49eacb);

  static const _ringRadius = 56.0;
  static const _ringWidth = 9.0;
  static const _dash = 95.3;
  static const _gap = 22.0;

  static final _kPath = Path()
    ..moveTo(41.05, 32.18)
    ..lineTo(55.74, 32.18)
    ..lineTo(55.74, 66.92)
    ..lineTo(72.64, 50.06)
    ..lineTo(89.70, 50.06)
    ..lineTo(67.26, 71.14)
    ..lineTo(91.46, 96.00)
    ..lineTo(73.66, 96.00)
    ..lineTo(55.74, 76.85)
    ..lineTo(55.74, 96.00)
    ..lineTo(41.05, 96.00)
    ..close();

  const _DotkLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _frame, size.height / _frame);

    canvas.drawCircle(_center, 64, Paint()..color = _disc);

    // The ring's circle is rotated by -100 degrees, and its gradient with it:
    // the gradient runs over the circle's own bounding box, before the turn.
    canvas.save();
    _rotateAbout(canvas, _center, -100);
    final ringBox = Rect.fromCircle(center: _center, radius: _ringRadius);
    final ring = Paint()
      ..style = .stroke
      ..strokeWidth = _ringWidth
      ..strokeCap = .round
      ..shader = const LinearGradient(
        begin: .topLeft,
        end: .bottomRight,
        colors: [_ringStart, _ringEnd],
      ).createShader(ringBox);
    // An SVG circle's stroke starts at 3 o'clock and runs clockwise, and the
    // three dashes and gaps add up to the circumference.
    const sweep = _dash / _ringRadius;
    const step = (_dash + _gap) / _ringRadius;
    for (var i = 0; i < 3; i++) {
      canvas.drawArc(ringBox, i * step, sweep, false, ring);
    }
    canvas.restore();

    // The mark: scaled about the centre to clear the ring, then moved right.
    canvas.translate(64, 64);
    canvas.scale(0.784);
    canvas.translate(-64 + 18.27, -64 - 0.09);

    canvas.drawCircle(const Offset(12, 84), 12, Paint()..color = _dot);

    // The `k` is scaled about its bottom-left corner.
    canvas.translate(41.05, 96);
    canvas.scale(1.15);
    canvas.translate(-41.05, -96);
    canvas.drawPath(_kPath, Paint()..color = _k);

    canvas.restore();
  }

  static void _rotateAbout(Canvas canvas, Offset center, double degrees) {
    canvas.translate(center.dx, center.dy);
    canvas.rotate(degrees * math.pi / 180);
    canvas.translate(-center.dx, -center.dy);
  }

  @override
  bool shouldRepaint(_DotkLogoPainter oldDelegate) => false;
}
