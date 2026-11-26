// 评分备注渲染。
//
// 数据层早已解析理由（ForumRateItem.reason），这里只管渲染：
// 汇总行保留，明细每条一行「用户名 +N 理由」；理由为空只留名字和分。
// 只断言文字内容与折叠行为，色值 / 像素留给真机。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/forum/forum_models.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/widgets/forum/forum_post_card.dart';

void main() {
  final colors = ymPalette(YmThemeId.yamibo, Brightness.light);

  Future<void> pumpRate(WidgetTester tester, ForumRate rate) async {
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
        home: Scaffold(
          body: SingleChildScrollView(
            child: YmForumRateLine(rate: rate),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 渲染树里含 [needle] 的那段富文本的纯文本。
  String? plainTextOf(WidgetTester tester, String needle) {
    for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
      final text = rt.text.toPlainText();
      if (text.contains(needle)) return text;
    }
    return null;
  }

  testWidgets('有理由的条目：用户名 + 加分 + 理由文本都在', (tester) async {
    const rate = ForumRate(people: 2, score: 3, items: [
      ForumRateItem(name: '阿甲', delta: 2, reason: '写得真好'),
      ForumRateItem(name: '阿乙', delta: 1, reason: ''),
    ]);
    await pumpRate(tester, rate);

    final summary = plainTextOf(tester, '评分');
    expect(summary, contains('评分 +3'));
    expect(summary, contains('2 人'));

    final first = plainTextOf(tester, '写得真好');
    expect(first, contains('阿甲'));
    expect(first, contains('+2'));
  });

  testWidgets('理由为空的条目：只有名字和分，不留空占位', (tester) async {
    const rate = ForumRate(people: 2, score: 3, items: [
      ForumRateItem(name: '阿甲', delta: 2, reason: '写得真好'),
      ForumRateItem(name: '阿乙', delta: 1, reason: ''),
    ]);
    await pumpRate(tester, rate);

    final second = plainTextOf(tester, '阿乙');
    expect(second, '阿乙 +1', reason: '没有理由就不该多出空格或分隔符');
  });

  testWidgets('超过 3 条先收 3 条，点「展开全部」看得到剩下的', (tester) async {
    const rate = ForumRate(people: 5, score: 9, items: [
      ForumRateItem(name: '甲', delta: 2, reason: '一'),
      ForumRateItem(name: '乙', delta: 2, reason: '二'),
      ForumRateItem(name: '丙', delta: 2, reason: '三'),
      ForumRateItem(name: '丁', delta: 2, reason: '四'),
      ForumRateItem(name: '戊', delta: 1, reason: '五'),
    ]);
    await pumpRate(tester, rate);

    expect(plainTextOf(tester, '丁'), isNull, reason: '第 4 条默认收起');
    expect(find.text('展开全部 5 条'), findsOneWidget);

    await tester.tap(find.text('展开全部 5 条'));
    await tester.pumpAndSettle();

    expect(plainTextOf(tester, '丁'), isNotNull);
    expect(plainTextOf(tester, '戊 +1'), isNotNull);
    expect(find.text('收起'), findsOneWidget);
  });
}
