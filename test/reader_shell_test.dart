import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/models.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/widgets/reader_shell.dart';
import 'package:yamibo_flutter/design/widgets/sheet.dart';

/// 阅读器壳的回归闸门：只钉结构与边界 —— 顶栏、进度条、工具栏格数、
/// 章末四句文案的四种组合。像素与色值一律留给真机，不在这里断言。
void main() {
  const prev = YmChapterRef(id: 'c1', title: '第一章 起点', volume: '');
  const current = YmChapterRef(id: 'c2', title: '第二章 路上', volume: '');
  const next = YmChapterRef(id: 'c3', title: '第三章 归途', volume: '');

  const defaultTools = [
    YmReaderTool(label: '目录', onTap: _noop),
    YmReaderTool(label: '阅读设置', onTap: _noop),
    YmReaderTool(label: '加书签', onTap: _noop, active: true),
  ];

  Future<void> pumpShell(
    WidgetTester tester, {
    YmChapterRef? prevChapter,
    YmChapterRef? nextChapter,
    List<YmReaderTool> tools = defaultTools,
    Widget body = const Text('正文第一段'),
    bool chrome = true,
    ValueChanged<bool>? onChromeChanged,
    VoidCallback? onScrollEnd,
    VoidCallback? onPrevTap,
    VoidCallback? onNextTap,
    Widget? barSlider,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
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
        home: YmReaderShell(
          controller: ScrollController(),
          progress: ValueNotifier<double>(0),
          title: '某部小说',
          subtitle: current.title,
          body: body,
          footer: YmReaderEndBlock(
            prev: prevChapter,
            next: nextChapter,
            onPrev: onPrevTap ?? () {},
            onNext: onNextTap ?? () {},
            onBack: () {},
          ),
          tools: tools,
          chrome: chrome,
          onChromeChanged: onChromeChanged ?? (_) {},
          onScrollEnd: onScrollEnd,
          barSlider: barSlider,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('骨架：顶栏标题 / 副标题、进度条、工具栏按调用方的列表渲染', (tester) async {
    await pumpShell(tester, prevChapter: prev, nextChapter: next);

    expect(find.text('某部小说'), findsOneWidget, reason: '顶栏标题取壳的 title');
    expect(find.text(current.title), findsOneWidget, reason: '顶栏副标题取壳的 subtitle');
    expect(find.byType(YmReaderProgressBar), findsOneWidget, reason: '顶栏下方那条 2px 进度条');
    expect(find.byType(YmReaderToolCell), findsNWidgets(3), reason: '三格由传入的列表决定');
    expect(find.text('目录'), findsOneWidget);
    expect(find.text('阅读设置'), findsOneWidget);
    expect(find.text('加书签'), findsOneWidget);
  });

  testWidgets('工具栏不写死格数：传两格就渲染两格', (tester) async {
    await pumpShell(
      tester,
      prevChapter: prev,
      nextChapter: next,
      tools: const [
        YmReaderTool(label: '目录', onTap: _noop),
        YmReaderTool(label: '阅读设置', onTap: _noop),
      ],
    );

    expect(find.byType(YmReaderToolCell), findsNWidgets(2));
    expect(find.text('加书签'), findsNothing);
  });

  testWidgets('info 格：页码读数渲染成说明文字格，不产生按压件', (tester) async {
    await pumpShell(
      tester,
      prevChapter: prev,
      nextChapter: next,
      tools: const [
        YmReaderTool(label: '目录', onTap: _noop),
        YmReaderTool(label: '3 / 8', onTap: _noop, info: true),
        YmReaderTool(label: '加书签', onTap: _noop),
      ],
    );

    expect(find.text('3 / 8'), findsOneWidget);
    expect(
      find.byType(YmReaderToolCell),
      findsNWidgets(2),
      reason: 'info 格不是按钮：不包 YmReaderToolCell（无按压反馈、不写字重）',
    );
  });

  testWidgets('barSlider：传了就在工具格上方渲染滑杆行（漫画面板结构）', (tester) async {
    await pumpShell(
      tester,
      prevChapter: prev,
      nextChapter: next,
      barSlider: const Text('滑杆行'),
    );

    expect(find.text('滑杆行'), findsOneWidget);
    final sliderTop = tester.getTopLeft(find.text('滑杆行')).dy;
    final toolsTop = tester.getTopLeft(find.text('目录')).dy;
    expect(sliderTop, lessThan(toolsTop), reason: '滑杆行在功能格 Row 上方');
  });

  testWidgets('barSlider：不传 = 单行工具格，底栏预留常量不动', (tester) async {
    await pumpShell(tester, prevChapter: prev, nextChapter: next);

    expect(find.text('滑杆行'), findsNothing);
    // chromeBottomExtent 是滚动模式 ListView padding 与分页预算的地板常量
    // （已冻结的口径），滑杆行纯覆盖，不许吃掉它。
    expect(YmReaderShell.chromeBottomExtent, 58.0);
  });

  testWidgets('章末 · 中间章：上一章 / 下一章都可点', (tester) async {
    var prevTaps = 0;
    var nextTaps = 0;
    await pumpShell(
      tester,
      prevChapter: prev,
      nextChapter: next,
      onPrevTap: () => prevTaps++,
      onNextTap: () => nextTaps++,
    );

    expect(find.text('‹ 上一章'), findsOneWidget);
    expect(find.text('下一章 ›'), findsOneWidget);
    expect(find.text('已经是第一章'), findsNothing);
    expect(find.text('已经是最后一章'), findsNothing);

    await tester.tap(find.text('‹ 上一章'));
    await tester.tap(find.text('下一章 ›'));
    expect(prevTaps, 1);
    expect(nextTaps, 1);
  });

  testWidgets('章末 · 第一章：左边是「已经是第一章」且点不动，右边可点', (tester) async {
    var prevTaps = 0;
    var nextTaps = 0;
    await pumpShell(
      tester,
      nextChapter: next,
      onPrevTap: () => prevTaps++,
      onNextTap: () => nextTaps++,
    );

    expect(find.text('已经是第一章'), findsOneWidget);
    expect(find.text('‹ 上一章'), findsNothing);
    expect(find.text('下一章 ›'), findsOneWidget);

    await tester.tap(find.text('已经是第一章'), warnIfMissed: false);
    await tester.tap(find.text('下一章 ›'));
    expect(prevTaps, 0, reason: '第一章的「上一章」是禁用件，不响应点击');
    expect(nextTaps, 1);
  });

  testWidgets('章末 · 最后一章：右边是「已经是最后一章」且点不动，左边可点', (tester) async {
    var prevTaps = 0;
    var nextTaps = 0;
    await pumpShell(
      tester,
      prevChapter: prev,
      onPrevTap: () => prevTaps++,
      onNextTap: () => nextTaps++,
    );

    expect(find.text('已经是最后一章'), findsOneWidget);
    expect(find.text('下一章 ›'), findsNothing);
    expect(find.text('‹ 上一章'), findsOneWidget);

    await tester.tap(find.text('已经是最后一章'), warnIfMissed: false);
    await tester.tap(find.text('‹ 上一章'));
    expect(nextTaps, 0, reason: '最后一章的「下一章」是禁用件，不响应点击');
    expect(prevTaps, 1);
  });

  testWidgets('章末 · 只有一章：两边都是禁用文案，点哪边都不触发', (tester) async {
    var prevTaps = 0;
    var nextTaps = 0;
    await pumpShell(
      tester,
      onPrevTap: () => prevTaps++,
      onNextTap: () => nextTaps++,
    );

    expect(find.text('已经是第一章'), findsOneWidget);
    expect(find.text('已经是最后一章'), findsOneWidget);
    expect(find.text('‹ 上一章'), findsNothing);
    expect(find.text('下一章 ›'), findsNothing);

    await tester.tap(find.text('已经是第一章'), warnIfMissed: false);
    await tester.tap(find.text('已经是最后一章'), warnIfMissed: false);
    expect(prevTaps, 0);
    expect(nextTaps, 0);
  });

  testWidgets('点正文空白处：壳把目标态抛给调用方（开 → 关 → 开）', (tester) async {
    bool? seen;
    var chrome = true;
    await pumpShell(
      tester,
      prevChapter: prev,
      nextChapter: next,
      onChromeChanged: (v) => seen = v,
    );

    await tester.tap(find.text('正文第一段'));
    expect(seen, isFalse, reason: 'chrome 开着时点正文应要求收起');

    // 按回调把状态落回去再点一次：壳的状态由调用方驱动
    chrome = false;
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpShell(
      tester,
      prevChapter: prev,
      nextChapter: next,
      chrome: chrome,
      onChromeChanged: (v) => seen = v,
    );
    await tester.tap(find.text('正文第一段'));
    expect(seen, isTrue, reason: 'chrome 收起时点正文应要求展开');
  });

  testWidgets('正文滚动停下：onScrollEnd 被回调（记进度挂在这里）', (tester) async {
    var ends = 0;
    await pumpShell(
      tester,
      prevChapter: prev,
      nextChapter: next,
      body: Column(
        children: [
          for (var i = 0; i < 80; i++) Text('第 $i 段正文内容，用来把滚动区撑长。'),
        ],
      ),
      onScrollEnd: () => ends++,
    );

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(ends, greaterThan(0), reason: '滚动停下要能通知调用方记进度');
  });

  testWidgets('阅读设置面板：默认给字形（小说用），传 false 时不给（论坛用）', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final colors = ymPalette(YmThemeId.yamibo, Brightness.light);

    Future<void> pumpSheet(Widget sheet) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildYmTheme(colors, Brightness.light),
          builder: (context, child) => YmScope(
            colors: colors,
            themeId: YmThemeId.yamibo,
            onThemeChanged: (_) {},
            child: child ?? const SizedBox.shrink(),
          ),
          home: Scaffold(body: SingleChildScrollView(child: sheet)),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpSheet(const YmReaderSettingsSheet());
    expect(find.text('字号'), findsOneWidget);
    expect(find.text('行距'), findsOneWidget);
    expect(find.text('字形'), findsOneWidget, reason: '小说侧口径不变');

    await pumpSheet(const YmReaderSettingsSheet(showTraditional: false));
    expect(find.text('字号'), findsOneWidget);
    expect(find.text('行距'), findsOneWidget);
    expect(find.text('字形'), findsNothing);
    expect(find.text('繁體'), findsNothing);
  });
}

void _noop() {}
