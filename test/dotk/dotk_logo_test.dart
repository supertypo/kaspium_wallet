import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspium_wallet/dotk/dotk_logo.dart';
import 'package:kaspium_wallet/settings/available_themes.dart';

void main() {
  // The logo holds its own colors, so one background covers it
  testWidgets('logo matches the SVG', (tester) async {
    tester.view.physicalSize = const Size(260, 160);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const golden = Key('golden');
    final background = ThemeSetting(
      ThemeOptions.KASPIUM_DARK,
    ).getTheme().background;
    await tester.pumpWidget(
      Center(
        child: RepaintBoundary(
          key: golden,
          child: ColoredBox(
            color: background,
            child: const Padding(
              padding: .all(8),
              child: Row(
                mainAxisSize: .min,
                crossAxisAlignment: .end,
                textDirection: .ltr,
                children: [
                  DotkLogo(size: 128),
                  SizedBox(width: 8),
                  DotkLogo(size: 64),
                  SizedBox(width: 8),
                  DotkLogo(size: 22),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await expectLater(
      find.byKey(golden),
      matchesGoldenFile('goldens/dotk_logo_dark.png'),
    );
  });
}
