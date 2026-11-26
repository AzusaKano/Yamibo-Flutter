// 正文跟随阅读偏好（字号 / 行距）。
//
// 只断言结构：段落基样式、内联三档的倍率关系、次要件等比换算。
// 观感（多大多高好不好看）留给真机。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/forum/forum_models.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/tokens.dart';
import 'package:yamibo_flutter/design/widgets/forum/forum_body.dart';

void main() {
  final colors = ymPalette(YmThemeId.yamibo, Brightness.light);

  Future<void> pumpBody(WidgetTester tester, Widget body) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildYmTheme(colors, Brightness.light),
        builder: (context, child) => YmScope(
          colors: colors,
          themeId: YmThemeId.yamibo,
          onThemeChanged: (_) {},
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: SingleChildScrollView(child: body)),
      ),
    );
    await tester.pumpAndSettle();
  }

  TextSpan? findSpan(WidgetTester tester, bool Function(TextSpan) test) {
    TextSpan? hit;
    void walk(InlineSpan span) {
      if (span is TextSpan) {
        if (hit == null && test(span)) hit = span;
        span.children?.forEach(walk);
      }
    }

    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      walk(rt.text);
    }
    return hit;
  }

  /// 段落根 span：那一层带 children、且直接挂着 [marker] 片段
  /// （正文基样式挂在它上面；按标记片段定位，免得撞上页面里别的富文本）。
  TextSpan? paraRoot(WidgetTester tester, String marker) => findSpan(
        tester,
        (s) =>
            s.text == null &&
            (s.children ?? const <InlineSpan>[])
                .any((c) => c is TextSpan && c.text == marker),
      );

  const blocks = <ForumBlock>[
    ForumParaBlock(<ForumInline>[
      ForumInline.text('正文'),
      ForumInline.text('大字', style: ForumInlineStyle(sizeStep: 1)),
      ForumInline.text('小字', style: ForumInlineStyle(sizeStep: -1)),
    ]),
    ForumQuoteBlock(
      ForumQuote(author: '某人', time: '昨天', text: '引用的话'),
    ),
    ForumCollapseBlock(
      title: '折叠标题',
      blocks: <ForumBlock>[
        ForumParaBlock(<ForumInline>[
          ForumInline.text('块内大字', style: ForumInlineStyle(sizeStep: 1)),
        ]),
      ],
    ),
  ];

  testWidgets('不传参数：正文仍是 body15 + 1.72，三档仍是 17 / 13', (tester) async {
    await pumpBody(tester, const YmForumBody(blocks: blocks, pid: 'p1'));

    final root = paraRoot(tester, '正文');
    expect(root?.style?.fontSize, YmFont.body15, reason: '帖子页口径不许变');
    expect(root?.style?.height, 1.72);
    expect(findSpan(tester, (s) => s.text == '大字')?.style?.fontSize, 17,
        reason: '15 × 17 / 15');
    expect(findSpan(tester, (s) => s.text == '小字')?.style?.fontSize, 13,
        reason: '15 × 13 / 15');
  });

  testWidgets('传字号：正文跟上，三档按基准等比（不是写死 17 / 13）', (tester) async {
    await pumpBody(
      tester,
      const YmForumBody(
        blocks: blocks,
        pid: 'p1',
        fontSize: 22,
        lineHeight: 2.1,
      ),
    );

    final root = paraRoot(tester, '正文');
    expect(root?.style?.fontSize, 22);
    expect(root?.style?.height, 2.1);

    final big = findSpan(tester, (s) => s.text == '大字')?.style?.fontSize;
    final small = findSpan(tester, (s) => s.text == '小字')?.style?.fontSize;
    expect(big, closeTo(22 * 17 / 15, 1e-9));
    expect(small, closeTo(22 * 13 / 15, 1e-9));
    // 比例关系与 15 基准时一致：大 / 正文 = 17/15，小 / 正文 = 13/15
    expect(big! / 22, closeTo(17 / 15, 1e-9));
    expect(small! / 22, closeTo(13 / 15, 1e-9));
    expect(small, greaterThan(13), reason: '基准抬到 22 后，小字不许留在 13');
  });

  testWidgets('次要件（引用 / 折叠标题）跟着基准等比换算', (tester) async {
    await pumpBody(
      tester,
      const YmForumBody(blocks: blocks, pid: 'p1', fontSize: 22),
    );

    final quote = findSpan(tester, (s) => s.text == '引用的话')?.style?.fontSize;
    final collapseTitle =
        findSpan(tester, (s) => s.text == '折叠标题')?.style?.fontSize;
    expect(quote, closeTo(22 * 12 / 15, 1e-9));
    expect(collapseTitle, closeTo(22 * 12 / 15, 1e-9));
  });

  testWidgets('折叠块内容递归时也带上基准字号', (tester) async {
    await pumpBody(
      tester,
      const YmForumBody(blocks: blocks, pid: 'p1', fontSize: 22),
    );

    final inner = findSpan(tester, (s) => s.text == '块内大字')?.style?.fontSize;
    expect(inner, closeTo(22 * 17 / 15, 1e-9),
        reason: '嵌套正文不许回到 17 的绝对值上');
  });
}
