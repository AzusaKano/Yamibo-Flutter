// 页码滑杆共用件（YmReaderPageSlider）。
//
// 口径全在母本（manga_reader_page._PageSlider，提共用件时逐字节搬运）：
// 拖动只预览 + 品牌底白字气泡「x / n」、松手 onDone 才提交、点轨道（onTapDown）
// 直跳。value / onDone 都是 1 基页码。像素与色值留给真机，这里钉交互语义。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/widgets/reader_page_slider.dart';

/// 底栏里滑杆的真实宽度：视口 360 − 两侧 pagePad 14。
const double _barWidth = 332;

Future<void> pumpSlider(
  WidgetTester tester, {
  required double value,
  required int total,
  required ValueChanged<int> onDone,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
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
        body: Center(
          child: SizedBox(
            width: _barWidth,
            child: YmReaderPageSlider(
              value: value,
              total: total,
              onDone: onDone,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('点轨道直跳：点哪回调哪（tap 赢下手势 arena，onTapDown 提交目标页）', (tester) async {
    final done = <int>[];
    await pumpSlider(tester, value: 1, total: 5, onDone: done.add);
    final box = tester.getRect(find.byType(YmReaderPageSlider));
    // 80% 处：0.8 × 5 = 4 → 直接跳第 4 页
    await tester.tapAt(Offset(box.left + box.width * 0.8, box.center.dy));
    expect(done, [4], reason: '点轨道直跳是母本口径：无拖动竞争，tap 回调目标页');
    expect(find.text('4 / 5'), findsNothing, reason: '气泡只在拖动时出现');
  });

  testWidgets('拖动只预览：拖动全程不提交跳页、气泡跟手，松手才回调预览页', (tester) async {
    final done = <int>[];
    await pumpSlider(tester, value: 1, total: 5, onDone: done.add);
    final box = tester.getRect(find.byType(YmReaderPageSlider));
    // 拖动手势赢下手势 arena 后 tap 不再触发（SDK 3.47：onTapDown 只在
    // arena 赢家 / deadline 发）⇒ 拖动全程 onDone 一次都不调，真「只预览」。
    final gesture = await tester.startGesture(
      Offset(box.left + box.width * 0.2, box.center.dy),
    );
    expect(done, isEmpty, reason: '拖动起手不提交（drag 赢了 arena，onTapDown 不发）');
    await gesture.moveBy(Offset(box.width * 0.4, 0));
    await tester.pump();
    expect(done, isEmpty, reason: '拖动过程只预览，不许跳页');
    expect(find.text('3 / 5'), findsOneWidget, reason: '品牌底白字气泡显示预览页码');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(done, [3], reason: '松手才提交预览页');
    expect(find.text('3 / 5'), findsNothing, reason: '松手后气泡收场');
  });

  testWidgets('松手回调四舍五入的页码：停在半路上取整提交', (tester) async {
    final done = <int>[];
    await pumpSlider(tester, value: 1, total: 4, onDone: done.add);
    final box = tester.getRect(find.byType(YmReaderPageSlider));
    final gesture = await tester.startGesture(
      Offset(box.left + box.width * 0.25, box.center.dy),
    );
    await gesture.moveBy(Offset(box.width * 0.45, 0)); // 0.7 × 4 = 2.8
    await tester.pump();
    expect(find.text('3 / 4'), findsOneWidget, reason: '2.8 取整预览第 3 页');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(done.last, 3, reason: '松手提交取整后的页码');
  });
}
