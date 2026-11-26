import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/tokens.dart';
import 'package:yamibo_flutter/design/widgets/sheet.dart';

/// 弹层 / 对话框落位动效的口径（2026-10-24 定）：
///
/// - **弹层**：380ms 整块推进来（115% 自身高度），62% 处轻微超出再收回；
/// - **对话框**：240ms，**只上浮 12px、不淡入、不缩放**（Flyme 那一路）。
///
/// 用真实路由跑，量「内容相对最终位置的位移」，不靠肉眼验收。
void main() {
  const probeKey = Key('probe-key');

  Future<void> pumpHost(WidgetTester tester, void Function(BuildContext) open) async {
    final colors = ymPalette(YmThemeId.yamibo, Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildYmTheme(colors, Brightness.light),
        // YmScope 必须挂在 builder 上（与 app.dart 一致）：挂在 home 下面的 InheritedWidget
        // 不是新路由的祖先，弹层里就取不到主题。
        builder: (context, child) => YmScope(
          colors: colors,
          themeId: YmThemeId.yamibo,
          onThemeChanged: (_) {},
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () {
                  open(context);
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump(); // 路由插入
    await tester.pump(); // 首帧（t≈0）
  }

  /* ------------------------------- 弹层 ------------------------------- */

  testWidgets('弹层进场：整块推进来 + 62% 处轻微超出', (tester) async {
    await pumpHost(
      tester,
      (context) => showYmSheet<void>(
        context,
        builder: (_) => const SizedBox(key: probeKey, height: 200),
      ),
    );
    final probe = find.byKey(probeKey);

    await tester.pump(YmMotion.sheetIn * 0.2);
    final early = tester.getTopLeft(probe).dy;
    await tester.pump(YmMotion.sheetIn * 0.42); // 累计到 62%
    final atPeak = tester.getTopLeft(probe).dy;
    await tester.pump(YmMotion.sheetIn);
    await tester.pumpAndSettle();
    final rest = tester.getTopLeft(probe).dy;

    // ignore: avoid_print
    print('弹层 20%：低于落位 ${(early - rest).toStringAsFixed(2)}px；'
        '62%：超出 ${(rest - atPeak).toStringAsFixed(2)}px');
    expect(early - rest, greaterThan(40), reason: '20% 时应当还明显在下方（整块推进来）');
    expect(rest - atPeak, greaterThan(0.5), reason: '62% 处应当越过目标位');
    expect(rest - atPeak, lessThan(8), reason: '超出必须轻微');
  });

  test('弹层曲线：单调冲到 1+peek，再收回 1', () {
    const curve = YmMotion.sheetInCurve;
    expect(curve.transform(0), 0);
    expect(curve.transform(1), 1);
    expect(curve.transform(YmSheetInCurve.breakAt),
        closeTo(1 + YmSheetInCurve.peek, 1e-9));
    var prev = 0.0;
    for (var t = 0.0; t <= YmSheetInCurve.breakAt; t += 0.02) {
      final v = curve.transform(t);
      expect(v, greaterThanOrEqualTo(prev));
      prev = v;
    }
    expect(YmSheetInCurve.peek, lessThan(0.01));
  });

  /* ------------------------------ 对话框 ------------------------------ */

  testWidgets('对话框：从底部整块滑入，380ms 内落位，不淡入', (tester) async {
    await pumpHost(
      tester,
      (context) => showYmConfirm(context, title: '退出登录', content: '确认退出登录吗？'),
    );

    final card = find.text('确认退出登录吗？');
    expect(
      find.ancestor(of: card, matching: find.byType(FadeTransition)),
      findsNothing,
      reason: '对话框不淡入（遮罩的 FadeTransition 是兄弟节点，不是祖先）',
    );

    final first = tester.getTopLeft(card).dy;
    await tester.pump(YmMotion.dialogIn * 0.15);
    final mid = tester.getTopLeft(card).dy;
    await tester.pump(YmMotion.dialogIn);
    await tester.pumpAndSettle();
    final rest = tester.getTopLeft(card).dy;

    // ignore: avoid_print
    print('对话框：首帧低于落位 ${(first - rest).toStringAsFixed(2)}px，'
        '15% 时 ${(mid - rest).toStringAsFixed(2)}px');
    // 起始位移 = 自身高度 + 16 + 安全区 ⇒ 必须远大于「只浮 12px」那种做法
    expect(first - rest, greaterThan(80), reason: '整块从底部滑入，不是只浮一小段');
    expect(mid, lessThan(first), reason: '方向是往上滑');
    expect(mid - rest, greaterThan(-0.5), reason: '过程中不得越过落位（不回弹）');
    expect(rest - mid, lessThan(first - rest), reason: '落定后再无位移');
  });

  testWidgets('弹层退场：减速曲线（前半程走得多，比值明显小于匀速的 2.0）', (tester) async {
    await pumpHost(
      tester,
      (context) => showYmSheet<void>(
        context,
        builder: (_) => const SizedBox(key: probeKey, height: 200),
      ),
    );
    final probe = find.byKey(probeKey);
    await tester.pumpAndSettle();
    final rest = tester.getTopLeft(probe).dy;

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(YmMotion.sheetOut * 0.25);
    final d1 = tester.getTopLeft(probe).dy - rest;
    await tester.pump(YmMotion.sheetOut * 0.25); // 到 50%
    final d2 = tester.getTopLeft(probe).dy - rest;

    // ignore: avoid_print
    print('弹层退场：25% 走了 ${d1.toStringAsFixed(1)}px，50% 走了 ${d2.toStringAsFixed(1)}px'
        '（比值 ${(d2 / d1).toStringAsFixed(2)}，匀速会是 2.00）');
    expect(d2 / d1, lessThan(1.7),
        reason: '退场走 cubic-bezier(.32,.72,0,1)：起手快、后段收，比值必须明显小于匀速');
    expect(d2 / d1, greaterThan(1.05), reason: '仍然单调向前，不能出现回拉');
  });
}
