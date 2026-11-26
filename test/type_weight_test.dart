import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/widgets/lists.dart';

/// 看守：行标题 / 按钮标签必须是 w700，**不能靠"看起来像是 preset"**。
///
/// 2026-11-10 踩过的坑：`TextStyle(fontSize: YmFont.body14)` 是**裸样式**，
/// `YmFont` 只是字号常量，不带字重；删掉显式 `fontWeight` 之后落的是 Flutter 默认
/// 的 **w400**，而不是 `c.body14` 那个 preset 的 700。
/// 结果「展开全部 N 章」按钮与目录章节名一起变细了 —— 看上去像"改对了口径"，
/// 实际是把标签和说明文字拉到了同一档。这个错误不会编译报错，只能靠断言或肉眼发现。
/// 下面的断言直接读渲染出来的 `TextStyle.fontWeight`，钉住这两处。
void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    final colors = ymPalette(YmThemeId.yamibo, Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildYmTheme(colors, Brightness.light),
        builder: (context, inner) => YmScope(
          colors: colors,
          themeId: YmThemeId.yamibo,
          onThemeChanged: (_) {},
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: child),
      ),
    );
  }

  FontWeight? weightOf(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style?.fontWeight;

  testWidgets('目录章节名：当前章与非当前章都是 w700（选中只换字色）', (tester) async {
    await pump(tester, const YmTocRow(title: '第1章 未读的章', index: 1));
    expect(weightOf(tester, '第1章 未读的章'), FontWeight.w700);

    await pump(tester, const YmTocRow(title: '第2章 正在读的章', index: 2, current: true));
    expect(weightOf(tester, '第2章 正在读的章'), FontWeight.w700);
  });

  testWidgets('「展开全部 N 章」按钮文字是 w700（按钮标签档，不是 400）', (tester) async {
    await pump(tester, const YmMoreButton(label: '查看全部 46 章'));
    expect(weightOf(tester, '查看全部 46 章'), FontWeight.w700);
  });
}
