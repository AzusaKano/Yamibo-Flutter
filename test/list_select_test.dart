import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/data/library.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/tokens.dart';
import 'package:yamibo_flutter/pages/history_page.dart';
import 'package:yamibo_flutter/pages/shelf_page.dart';

/// T22 列表管理（本地）：右上选择 / 长按进选择 / 底部条全选·删除 / 自绘确认框。
void main() {
  setUp(() {
    YmLibrary.resetForTest();
  });
  tearDown(() {
    YmLibrary.resetForTest();
  });

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    final colors = YmColors.yamiboLight;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildYmTheme(colors, Brightness.light),
        builder: (context, child) => YmScope(
          colors: colors,
          themeId: YmThemeId.yamibo,
          onThemeChanged: (_) {},
          child: child ?? const SizedBox.shrink(),
        ),
        home: page,
      ),
    );
    await tester.pump();
  }

  testWidgets('书架本地：长按进选择 → 全选 → 移出', (tester) async {
    YmLibrary.instance
      ..toggleShelf('1', title: '测试书一', author: '甲', kind: 'novel')
      ..toggleShelf('2', title: '测试书二', author: '乙', kind: 'manga');

    await pumpPage(tester, const Scaffold(body: ShelfPage()));
    expect(find.text('选择'), findsOneWidget);

    await tester.longPress(find.text('测试书一'));
    await tester.pump();
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    // 选择模式下不该出现单条删除的旧入口文案
    expect(find.text('移出'), findsOneWidget);

    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(find.text('已选 2 项'), findsOneWidget);

    await tester.tap(find.text('移出'));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    expect(find.text('移出书架'), findsOneWidget);

    await tester.tap(find.text('移出').last);
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    expect(YmLibrary.instance.shelfEntries, isEmpty);
    expect(find.text('书架是空的'), findsOneWidget);
  });

  testWidgets('历史：长按进选择 → 全选 → 删除', (tester) async {
    YmLibrary.instance
      ..recordRead(
        id: '1',
        title: '记录一',
        author: '',
        cat: '',
        kind: 'novel',
        chapterTitle: '第1章',
        percent: 0.1,
      )
      ..recordRead(
        id: '2',
        title: '记录二',
        author: '',
        cat: '',
        kind: 'novel',
        chapterTitle: '第2章',
        percent: 0.2,
      );

    await pumpPage(tester, const HistoryPage());
    expect(find.text('选择'), findsOneWidget);

    await tester.longPress(find.text('记录一'));
    await tester.pump();
    expect(find.text('已选 1 条'), findsOneWidget);

    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(find.text('已选 2 条'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    expect(find.text('删除记录'), findsOneWidget);

    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    expect(YmLibrary.instance.history, isEmpty);
    expect(find.text('还没有阅读记录'), findsOneWidget);
  });
}
