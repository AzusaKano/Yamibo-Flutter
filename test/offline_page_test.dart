import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/cache/ym_cache_store.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/widgets/offline_controls.dart';
import 'package:yamibo_flutter/pages/offline_detail_page.dart';
import 'package:yamibo_flutter/pages/offline_page.dart';

/// 离线内容管理页：列表、删除与空态。
/// 空态文案只有「还没有内容」。
///
/// ⚠ widget 测试跑在 fake-async 里，**真实文件 I/O 的 Future 不会完成**：
/// 造数据与「点删除后等落盘」都必须走 `tester.runAsync`，否则测试会静默挂住。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('ym_offline_page_test');
    YmCache.resetForTest(dir: tempDir);
    await YmCache.load();
  });

  tearDown(() async {
    YmCache.resetForTest();
    for (var i = 0; i < 6; i++) {
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
  });

  /// 真异步放行：让 runAsync 里的 I/O 跑完再继续。
  ///
  /// 假异步里的 `await File…` 每一步都要「真实时间往前走一帧 + pump 抽干微任务」，
  /// 所以是循环，不是一次性 sleep（一次 sleep 只推进一步）。
  Future<void> flushIo(WidgetTester tester, {int rounds = 15}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  /// 5s 上限：真卡在不停帧上时要在 5 秒内红，而不是等默认的 10 分钟。
  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
    const Duration(milliseconds: 50),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );

  Future<void> pumpPage(WidgetTester tester) async {
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
        home: const OfflinePage(),
      ),
    );
    await settle(tester);
  }

  Future<void> seed(
    WidgetTester tester, {
    String source = 'novel',
    String parent = '267',
    String parentTitle = '测试作品',
    required List<String> ids,
    int total = 0,
  }) {
    return tester.runAsync(() async {
      for (var i = 0; i < ids.length; i++) {
        await YmCache.instance.upsert(
          YmCacheEntry(
            key: '$source:${ids[i]}',
            source: source,
            parent: parent,
            parentTitle: parentTitle,
            title: '第${i + 1}章',
            order: i + 1,
            total: total,
            state: YmCacheState.done,
            bytes: 1024 * 1024,
            at: 100 + i,
          ),
        );
      }
    });
  }

  testWidgets('空态只有一句「还没有内容」', (tester) async {
    await pumpPage(tester);
    expect(find.text('还没有内容'), findsOneWidget);
    // 三枚分类胶囊仍然在（三枚都出现）
    expect(find.text('小说'), findsOneWidget);
    expect(find.text('漫画'), findsOneWidget);
    expect(find.text('论坛'), findsOneWidget);
  });

  testWidgets('页面自带 Scaffold：文字不落回「错误样式」（红字 + 黄色双下划线）', (tester) async {
    await pumpPage(tester);
    expect(find.byType(Scaffold), findsOneWidget);
    // 没有 Material 祖先时文本继承的是 DefaultTextStyle.fallback，
    // 它就是「黄色 + 双下划线」的 debug 样式 —— 界面上看到的「黄线」即此。
    // 有 Scaffold 之后继承的是主题正文（decoration 为 none，不是 underline）。
    final style = DefaultTextStyle.of(tester.element(find.text('还没有内容'))).style;
    expect(style.decoration, isNot(TextDecoration.underline));
  });

  testWidgets('点进作品子页：列表与顶栏之间留 14 的间距', (tester) async {
    await seed(tester, ids: ['1', '2'], total: 5);
    await pumpPage(tester);

    await tester.tap(find.text('测试作品'));
    await settle(tester);
    expect(find.byType(OfflineDetailPage), findsOneWidget);

    final list = tester.widget<ListView>(
      find.descendant(
        of: find.byType(OfflineDetailPage),
        matching: find.byType(ListView),
      ),
    );
    expect((list.padding as EdgeInsets).top, 14);
  });

  testWidgets('有内容：一本一行，副行是「已存 2 / 5 章 · 体积」', (tester) async {
    await seed(tester, ids: ['1', '2'], total: 5);
    await pumpPage(tester);

    expect(find.text('还没有内容'), findsNothing);
    expect(find.text('测试作品'), findsOneWidget);
    expect(find.textContaining('已存 2 / 5 章'), findsOneWidget);
    expect(find.textContaining('共 1 本'), findsOneWidget);
    // 顶栏出现「选择」
    expect(find.text('选择'), findsOneWidget);
  });

  testWidgets('按类型筛选：选中「漫画」时空态仍是同一句', (tester) async {
    await seed(tester, ids: ['1'], total: 3);
    await pumpPage(tester);

    await tester.tap(find.text('漫画'));
    await settle(tester);
    expect(find.text('还没有内容'), findsOneWidget);
    expect(find.text('测试作品'), findsNothing);
  });

  testWidgets('选择模式批量删：全选 → 删除 → 确认后回到空态', (tester) async {
    await seed(tester, ids: ['1', '2'], total: 5);
    await pumpPage(tester);

    await tester.tap(find.text('选择'));
    await settle(tester);
    await tester.tap(find.text('全选'));
    await settle(tester);
    expect(find.text('已选 1 项'), findsOneWidget);

    await tester.tap(find.text('删除').last);
    await settle(tester);
    // 确认框里的「共 X」得是真的数字，不能是 0 B（2026-11-24 第二轮统一措辞）
    expect(find.textContaining('共 2 MB'), findsOneWidget);

    await tester.tap(find.text('删除').last);
    await settle(tester);
    // 删除的落盘是真实 I/O，让它在真异步里跑完
    await flushIo(tester);
    await settle(tester);

    expect(YmCache.instance.peek('novel:1'), isNull);
    expect(YmCache.instance.peek('novel:2'), isNull);
    expect(find.text('还没有内容'), findsOneWidget);
  });

  test('体积文案：整数去掉 .0，KB / MB / GB 分级', () {
    expect(ymBytes(0), '0 B');
    expect(ymBytes(500), '500 B');
    expect(ymBytes(120 * 1024), '120 KB');
    expect(ymBytes(43 * 1024 * 1024), '43 MB');
    expect(ymBytes(4 * 1024 * 1024 + 200 * 1024), '4.2 MB');
    expect(ymBytes(3 * 1024 * 1024 * 1024), '3 GB');
  });
}
