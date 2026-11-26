// 图片查看器的组件测试。
// 手势在测试里不真实缩放（测试环境没有平台指针合成捏合），这里钉的是结构：
// 计数、缩略条数量、跳图与轻拖回弹的判定路径。
// 取图请求头的正确性只能在真机上确认，不在测试环境验。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/pages/forum/forum_image_viewer.dart';

Future<void> pumpViewer(WidgetTester tester, Widget page) async {
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
      home: Scaffold(body: page),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const images = <String>['a.jpg', 'b.jpg', 'c.jpg'];

  testWidgets('打开：计数 N/M 正确（initial 定位生效）；缩略条 3 枚', (tester) async {
    await pumpViewer(
      tester,
      const ForumImageViewer(images: images, initial: 1),
    );
    expect(find.text('2 / 3'), findsOneWidget, reason: '计数从 1 起算，落在 initial');
    expect(find.bySemanticsLabel('第1张缩略图'), findsOneWidget);
    expect(find.bySemanticsLabel('第2张缩略图'), findsOneWidget);
    expect(find.bySemanticsLabel('第3张缩略图'), findsOneWidget);
  });

  testWidgets('缩略条跳图：点第 3 枚 → 计数切到 3 / 3', (tester) async {
    await pumpViewer(tester, const ForumImageViewer(images: images));
    expect(find.text('1 / 3'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('第3张缩略图'));
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);
  });

  testWidgets('单图不显示缩略条（只有正片一张图）', (tester) async {
    await pumpViewer(tester, const ForumImageViewer(images: <String>['only.jpg']));
    expect(find.text('1 / 1'), findsOneWidget);
    expect(find.bySemanticsLabel('第1张缩略图'), findsNothing);
  });

  testWidgets('轻拖向下没过阈值：弹回不关闭（查看器还在）', (tester) async {
    await pumpViewer(tester, const ForumImageViewer(images: images));
    final stage = find.byType(ForumImageViewer);
    // 轻拖 60px（阈值 0.18 × 舞台高 ≈ 144px），松手应回弹
    final gesture = await tester.startGesture(tester.getCenter(stage));
    await gesture.moveBy(const Offset(0, 60));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget, reason: '查看器未关闭，计数原样');
  });

  testWidgets('单击切换沉浸：顶栏收起再呼出（0.1.22 补，与漫画阅读器同款）', (tester) async {
    await pumpViewer(tester, const ForumImageViewer(images: images));
    double counterOpacity(WidgetTester t) => t
        .widget<AnimatedOpacity>(
          find.ancestor(of: find.text('1 / 3'), matching: find.byType(AnimatedOpacity)).first,
        )
        .opacity;
    expect(counterOpacity(tester), 1);
    // 单击舞台中部：工具栏收起（onTapUp 被双击识别的 300ms 裁判窗口压着，
    // 测试里要把假时钟推过窗口才触发）
    await tester.tap(find.byType(ForumImageViewer));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(counterOpacity(tester), 0, reason: '收起进沉浸（计数随顶栏一起淡出）');
    // 再单击：呼出
    await tester.tap(find.byType(ForumImageViewer));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(counterOpacity(tester), 1);
  });
}
