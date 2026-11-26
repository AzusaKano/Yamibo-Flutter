// 章内位置恢复（两个阅读器共用）。
//
// 只断言「什么时候跳、跳到哪、什么时候不跳」：像素值按 percent × maxScrollExtent 算，
// 不写死某一段正文的实际高度。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/design/widgets/reader_restore.dart';

void main() {
  /// 测试台：一条可增长的纵向列表（`extra` 模拟「图片解码完把正文撑高」）。
  /// 只有一个子项 —— 与真实阅读器同构（壳里也是 `body` 一整坨），
  /// 多子项时列表首帧的 `maxScrollExtent` 是估算值，量出来的东西不对。
  Widget host(ScrollController c, ValueNotifier<double> extra, double base) {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          controller: c,
          children: [
            Column(
              children: [
                SizedBox(height: base),
                ValueListenableBuilder<double>(
                  valueListenable: extra,
                  builder: (_, v, child) => SizedBox(height: v),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> pumpUntilDone(
    WidgetTester tester,
    Future<bool> future, {
    int frames = 60,
  }) async {
    bool? result;
    future.then((v) => result = v);
    for (var i = 0; i < frames && result == null; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(result, isNotNull, reason: '恢复流程没有在预期帧内结束');
    return result!;
  }

  testWidgets('正文还没布局完（maxScrollExtent == 0）：不跳，也不报错', (tester) async {
    final c = ScrollController();
    addTearDown(c.dispose);
    final extra = ValueNotifier<double>(0);
    addTearDown(extra.dispose);

    await tester.pumpWidget(host(c, extra, 100)); // 不满一屏 ⇒ max = 0
    expect(c.position.maxScrollExtent, 0);

    final ok = await pumpUntilDone(tester, restoreReaderScroll(c, 0.5));

    expect(ok, isFalse, reason: '没有可滚的高度就不许动位置');
    expect(c.position.pixels, 0);
  });

  testWidgets('有高度时按 percent 落到对应位置', (tester) async {
    final c = ScrollController();
    addTearDown(c.dispose);
    final extra = ValueNotifier<double>(0);
    addTearDown(extra.dispose);

    await tester.pumpWidget(host(c, extra, 4000));
    await tester.pump(); // 首帧的 maxScrollExtent 还是估算值，布局一轮之后再读
    final max = c.position.maxScrollExtent;
    expect(max, greaterThan(0));

    final ok = await pumpUntilDone(tester, restoreReaderScroll(c, 0.4));

    expect(ok, isTrue);
    expect(c.position.pixels, closeTo(max * 0.4, 1));
  });

  testWidgets('边界：0.001 以下、非有限值回顶部；读到章末照样恢复', (tester) async {
    expect(readerRestoreTarget(null), isNull);
    for (final p in <double>[0.001, 0, double.nan, double.infinity]) {
      expect(readerRestoreTarget(p), isNull, reason: 'percent = $p 不该恢复');
    }
    expect(readerRestoreTarget(0.5), 0.5);
    expect(readerRestoreTarget(0.99), 0.99);
    expect(readerRestoreTarget(1), 1, reason: '读到章末也要恢复到底部，不回顶');

    final c = ScrollController();
    addTearDown(c.dispose);
    final extra = ValueNotifier<double>(0);
    addTearDown(extra.dispose);
    await tester.pumpWidget(host(c, extra, 4000));

    for (final p in <double>[0.0005, double.nan]) {
      final ok = await pumpUntilDone(tester, restoreReaderScroll(c, p));
      expect(ok, isFalse, reason: 'percent = $p 不恢复');
      expect(c.position.pixels, 0, reason: 'percent = $p 留在顶部');
    }
  });

  testWidgets('读到章末（0.995）：落到接近底部，不甩回顶部', (tester) async {
    final c = ScrollController();
    addTearDown(c.dispose);
    final extra = ValueNotifier<double>(0);
    addTearDown(extra.dispose);

    await tester.pumpWidget(host(c, extra, 4000));
    await tester.pump();
    final max = c.position.maxScrollExtent;

    final ok = await pumpUntilDone(tester, restoreReaderScroll(c, 0.995));

    expect(ok, isTrue);
    expect(c.position.pixels, closeTo(max * 0.995, 1));
    expect(c.position.pixels, greaterThan(max * 0.9), reason: '不许回顶');
  });

  testWidgets('正文变高（图片加载）：按新高度补一次校正', (tester) async {
    final c = ScrollController();
    addTearDown(c.dispose);
    final extra = ValueNotifier<double>(0);
    addTearDown(extra.dispose);

    await tester.pumpWidget(host(c, extra, 4000));
    await tester.pump(); // 同上：布局一轮后再读，首帧是估算值
    final max0 = c.position.maxScrollExtent;

    final done = restoreReaderScroll(
      c,
      0.5,
      watch: const Duration(milliseconds: 400),
    );
    await tester.pump();
    await tester.pump();
    expect(c.position.pixels, closeTo(max0 * 0.5, 1), reason: '先按当时高度落位');

    // 图片解码完，正文被撑高
    extra.value = 3000;
    await tester.pump();
    await tester.pump();
    final max1 = c.position.maxScrollExtent;
    expect(max1, greaterThan(max0));

    await pumpUntilDone(tester, done);
    expect(c.position.pixels, closeTo(max1 * 0.5, 1),
        reason: '高度变了要按同一个 percent 重算，不能偏在前面');
  });
}
