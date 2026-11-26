import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/design/pressable.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/tokens.dart';
import 'package:yamibo_flutter/design/widgets/bottom_nav.dart';
import 'package:yamibo_flutter/design/widgets/chip.dart';

/// 字号策略：
/// - 内容文字跟随系统 textScaler（放大到 2.0 就是 2.0）；
/// - 定高件（胶囊 / 按钮 / 底栏 / 工具条）钳到 1.5；
/// - 定高件在 2.0 下不得溢出。
void main() {
  Future<void> pumpAt(WidgetTester tester, Widget child, double scale) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, appChild) {
          final mq = MediaQuery.of(context);
          return MediaQuery(
            data: mq.copyWith(
              textScaler: TextScaler.linear(scale),
              padding: const EdgeInsets.only(top: 24),
              size: const Size(390, 844),
            ),
            child: appChild!,
          );
        },
        home: YmScope(
          colors: YmColors.railLight,
          themeId: YmThemeId.rail,
          onThemeChanged: (_) {},
          child: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    await tester.pump();
  }

  double textHeight(WidgetTester tester, String label) =>
      tester.getSize(find.text(label)).height;

  testWidgets('胶囊：2.0 时文字钳在 1.5，与 1.5 档等高', (tester) async {
    const chip = YmChip(
      label: '筛选胶囊',
      style: YmChipStyle.pill,
      pressKind: YmPressKind.row,
    );
    await pumpAt(tester, chip, 1.5);
    final at15 = textHeight(tester, '筛选胶囊');
    await pumpAt(tester, chip, 2.0);
    final at20 = textHeight(tester, '筛选胶囊');

    expect(at20, closeTo(at15, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('底栏：2.0 不溢出', (tester) async {
    await pumpAt(
      tester,
      YmBottomNav(index: 0, onChanged: (_) {}),
      2.0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('内容文字：2.0 按系统倍数放大（不钳）', (tester) async {
    const body = Text('正文段落', style: TextStyle(fontSize: 14));
    await pumpAt(tester, body, 1.0);
    final at10 = textHeight(tester, '正文段落');
    await pumpAt(tester, body, 2.0);
    final at20 = textHeight(tester, '正文段落');

    expect(at20, closeTo(at10 * 2, 1.0));
  });
}
