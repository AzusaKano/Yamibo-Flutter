import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/widgets/chip.dart';
import 'package:yamibo_flutter/design/widgets/hscroll_fade.dart';
import 'package:yamibo_flutter/design/pressable.dart';

/// 横滑胶囊条的「内容超出」渐隐（2026-10-25，口径照轨交速查 `.hscroll-fade`）：
///
/// - **溢出才出现**；**滚到最右端收起**；**滚回来恢复**。
/// - 覆盖层不挡手势（`IgnorePointer`），所以点最右边那颗被渐隐盖住的胶囊仍然有效。
void main() {
  Future<void> pumpBar(WidgetTester tester, {required List<String> labels}) async {
    tester.view.physicalSize = const Size(1080, 1920); // 360×640 逻辑像素
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final colors = ymPalette(YmThemeId.yamibo, Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildYmTheme(colors, Brightness.light),
        builder: (context, child) => YmScope(
          colors: colors,
          themeId: YmThemeId.yamibo,
          onThemeChanged: (_) {},
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: YmHScrollFade(
              spacing: 7,
              children: [for (final t in labels) YmChip(label: t, style: YmChipStyle.line, pressKind: YmPressKind.solid)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const many = ['原创小说', '同人小说', '百合漫画', '同人漫画', '完结', '签约', '短篇', '长篇'];
  const few = ['原创', '同人'];

  testWidgets('内容溢出：右缘出现渐隐，滚到最右收起，滚回来再出现', (tester) async {
    await pumpBar(tester, labels: many);
    expect(find.byKey(YmHScrollFade.fadeKey), findsOneWidget, reason: '溢出就该提示「后面还有」');

    // 一直拖到最右端
    await tester.drag(find.byType(YmHScrollFade), const Offset(-1200, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(YmHScrollFade.fadeKey), findsNothing, reason: '到末端不该再提示');

    // 往回滚一点就恢复
    await tester.drag(find.byType(YmHScrollFade), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(YmHScrollFade.fadeKey), findsOneWidget, reason: '右边又有未显示内容了');
  });

  testWidgets('选中项自动滚到可视区中间；两端由滚动边界钳住', (tester) async {
    Future<void> pumpWithFocus(int? focus) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      final colors = ymPalette(YmThemeId.yamibo, Brightness.light);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildYmTheme(colors, Brightness.light),
          builder: (context, child) => YmScope(
            colors: colors,
            themeId: YmThemeId.yamibo,
            onThemeChanged: (_) {},
            child: child ?? const SizedBox.shrink(),
          ),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: YmHScrollFade(
                spacing: 7,
                focusIndex: focus,
                children: [
                  for (final t in many) YmChip(label: t, style: YmChipStyle.line, pressKind: YmPressKind.solid),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    addTearDown(tester.view.reset);
    await pumpWithFocus(0);
    final barCenter = tester.getCenter(find.byType(YmHScrollFade)).dx;

    // 选中第 3 颗（0 基 = 「同人漫画」）：两头都还有余量，应当真正落在中心
    await pumpWithFocus(3);
    expect(
      tester.getCenter(find.text('同人漫画')).dx,
      closeTo(barCenter, 2),
      reason: '选中项要落在可视区中心',
    );

    // 选中最后一颗：居中所需的滚动量超过末端，只能停在最右（由滚动边界钳住）
    await pumpWithFocus(7);
    expect(
      tester.getCenter(find.text('长篇')).dx,
      greaterThan(barCenter),
      reason: '末端项贴右，不能为了居中把内容拖出左边界',
    );
    expect(find.byKey(YmHScrollFade.fadeKey), findsNothing, reason: '已到最右 ⇒ 渐隐收起');

    // 选中第一颗：真居中会让滚动量变负数，只能停在起点
    await pumpWithFocus(0);
    await tester.pumpAndSettle();
    expect(find.byKey(YmHScrollFade.fadeKey), findsOneWidget, reason: '停在起点 ⇒ 右边还有内容');
    expect(
      tester.getTopLeft(find.text('原创小说')).dx,
      lessThan(barCenter),
      reason: '首项贴左，不会被推出左边界',
    );
  });

  testWidgets('内容没溢出：不出现渐隐', (tester) async {
    await pumpBar(tester, labels: few);
    expect(find.byKey(YmHScrollFade.fadeKey), findsNothing);
  });

  testWidgets('渐隐层不吃手势：被它盖住的胶囊照样能点', (tester) async {
    var tapped = '';
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final colors = ymPalette(YmThemeId.yamibo, Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildYmTheme(colors, Brightness.light),
        builder: (context, child) => YmScope(
          colors: colors,
          themeId: YmThemeId.yamibo,
          onThemeChanged: (_) {},
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: YmHScrollFade(
              spacing: 7,
              children: [
                for (final t in many) YmChip(label: t, style: YmChipStyle.pill, pressKind: YmPressKind.row, onTap: () => tapped = t),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(YmHScrollFade.fadeKey), findsOneWidget);

    // 右缘那颗胶囊一半在渐隐层下面：点它应当照常命中
    await tester.tap(find.text('百合漫画'));
    await tester.pump();
    expect(tapped, '百合漫画');
  });

  // 首开定位（0.1.22 查看器胶卷反馈）：focusOnMount + focusIndex 时，
  // 首帧后就把那一项滚到可视区中间；不传 focusOnMount 维持「首批渲染不滚」旧口径。
  testWidgets('focusOnMount：首开直接滚到 focusIndex 那项', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920); // 360×640 逻辑像素
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final colors = ymPalette(YmThemeId.yamibo, Brightness.light);
    final labels = [for (var i = 1; i <= 30; i++) '第$i张'];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildYmTheme(colors, Brightness.light),
        builder: (context, child) => YmScope(
          colors: colors,
          themeId: YmThemeId.yamibo,
          onThemeChanged: (_) {},
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: YmHScrollFade(
              focusIndex: 25,
              focusOnMount: true,
              children: [
                for (final t in labels)
                  YmChip(label: t, style: YmChipStyle.line, pressKind: YmPressKind.solid),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 第 26 项（下标 25）进了可视区——首帧时它本来在屏幕外
    expect(
      tester.getBottomRight(find.text('第26张')).dx,
      lessThanOrEqualTo(tester.view.physicalSize.width / tester.view.devicePixelRatio),
    );
  });
}
