import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/models.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/widgets/lists.dart';
import 'package:yamibo_flutter/design/widgets/rows.dart';

/// 卡片列表的行必须**撑满卡片宽**、左内距 14px（曾出现整块内容被居中、
/// 没落在卡片容器里的问题）。
///
/// 根因是 `YmCardList` 的 `Column` 默认 `crossAxisAlignment.center`：
/// 行内部是 `Row`（带 `Expanded`）时自动撑满，看不出问题；行内部是 `Column`
/// 时宽度只等于最长那行文字的自然宽，整块就被居中了 —— `YmRcmdRow` 正是这种。
/// 断言量几何关系（相对卡片左上角），不写死像素常量。
void main() {
  const pad = 14.0; // 卡片外边距 / 行内左右内距，对齐 uni `.list` 的 14px

  // `YmCardList` 的 margin 在盒外，所以卡片自己的 rect 含边距；可用区要再内缩一层。
  Rect inner(Rect card) =>
      Rect.fromLTRB(card.left + pad, card.top, card.right - pad, card.bottom);

  Future<void> pumpCard(WidgetTester tester, Widget row) async {
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
          body: ListView(children: [YmCardList(children: [row])]),
        ),
      ),
    );
  }

  testWidgets('编辑推荐行：贴卡片左边缘、撑满卡片宽', (tester) async {
    const item = YmRcmdItem(
      id: 'n1',
      title: '短书名',
      intro: '一句推荐语',
      createdAt: '2026-10-20',
    );
    await pumpCard(tester, const YmRcmdRow(item: item));

    final card = inner(tester.getRect(find.byType(YmCardList)));
    final row = tester.getRect(find.byType(YmRcmdRow));
    final title = tester.getRect(find.text('短书名'));

    // 夹具非空：行确实被画出来了，否则下面几条断言会恒真
    expect(find.text('短书名'), findsOneWidget);

    expect(row.left, closeTo(card.left, 0.5), reason: '行要撑满卡片，不该被居中');
    expect(row.right, closeTo(card.right, 0.5), reason: '行要撑满卡片可用宽');
    expect(title.left, closeTo(card.left + pad, 0.5), reason: '文字落在卡片内距上，不该居中');
  });

  testWidgets('对照：YM 作品行本来就撑满（防止改容器后反而内缩）', (tester) async {
    await pumpCard(
      tester,
      YmActionRow(title: '我的书架', value: '3 本'),
    );

    final card = inner(tester.getRect(find.byType(YmCardList)));
    final row = tester.getRect(find.byType(YmActionRow));
    expect(row.left, closeTo(card.left, 0.5));
    expect(row.right, closeTo(card.right, 0.5));
  });
}
