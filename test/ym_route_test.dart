import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/tokens.dart';
import 'package:yamibo_flutter/design/ym_route.dart';

void main() {
  // ---- 令牌钉值（动效参数的定稿值，改动需同步改断言）----

  test('层级横推令牌：420ms / 旧页 −50% + 12% 黑纱', () {
    expect(YmMotion.push, const Duration(milliseconds: 420));
    expect(YmMotion.pushOldShift, 0.5);
    expect(YmMotion.pushShade, 0.12);
    expect(YmMotion.pushStyle, YmPushStyle.parallax);
  });

  test('方案 B 备选令牌：微缩 0.96 + 16% 黑纱', () {
    expect(YmMotion.pushAltScale, 0.96);
    expect(YmMotion.pushAltShade, 0.16);
  });

  test('曲线真值：推入 open_f12 / 返回 close_f12（Flyme framework-res）', () {
    expect(YmMotion.pushInCurve, const Cubic(0.25, 0.88, 0.08, 1));
    expect(YmMotion.pushOutCurve, const Cubic(0.2, 1.02, 0.38, 1));
  });

  test('模态令牌：0.92 缩放起点 + 220ms screen 口径', () {
    expect(YmMotion.modalScale, 0.92);
    expect(YmMotion.screen, const Duration(milliseconds: 220));
    expect(YmMotion.pushUnderlay, const Color(0xFF1C1C1E));
  });

  // ---- 路由类型与主题装配 ----

  test('ymRoute 出层级路由、ymModalRoute 出模态路由', () {
    expect(ymRoute(const SizedBox.shrink()), isA<YmPageRoute<dynamic>>());
    expect(ymRoute(const SizedBox.shrink()), isNot(isA<YmModalRoute<dynamic>>()));
    expect(
        ymModalRoute(const SizedBox.shrink()), isA<YmModalRoute<dynamic>>());
  });

  test('时长：层级 420ms / 模态 220ms；模态不吃预测式返回手势', () {
    expect(ymRoute(const SizedBox.shrink()).transitionDuration,
        const Duration(milliseconds: 420));
    expect(ymModalRoute(const SizedBox.shrink()).transitionDuration,
        const Duration(milliseconds: 220));
    // 反向不能落到 theme builder 的 420（那会让查看器"关得比开慢一倍"）
    expect(ymModalRoute(const SizedBox.shrink()).reverseTransitionDuration,
        const Duration(milliseconds: 220));
    expect(ymModalRoute<dynamic>(const SizedBox.shrink()).popGestureEnabled,
        isFalse);
  });

  test('旧页跟随判定：层级盖层级跟着动，模态盖顶旧页不动', () {
    final push = ymRoute(const SizedBox.shrink());
    expect(push.canTransitionTo(ymRoute(const SizedBox.shrink())),
        isTrue); // 页→页：旧页横推
    expect(push.canTransitionTo(ymModalRoute(const SizedBox.shrink())),
        isFalse); // 查看器盖顶：旧页静止（浮层语义）
    expect(
        push.canTransitionTo(ModalBottomSheetRoute<dynamic>(
          isScrollControlled: false,
          builder: (_) => const SizedBox.shrink(),
        )),
        isFalse); // 底部弹层盖顶：底页必须静止
  });

  test('pageTransitionsTheme 全平台挂 YmPushTransitionsBuilder', () {
    final theme =
        buildYmTheme(YmColors.yamiboLight, Brightness.light).pageTransitionsTheme;
    // fuchsia 不装配：App 从不跑在 fuchsia 上（theme.dart 只挂安卓/iOS/桌面）。
    const platforms = {
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    };
    for (final platform in platforms) {
      expect(theme.builders[platform], isA<YmPushTransitionsBuilder>(),
          reason: '$platform 也必须是横推 builder');
    }
  });

  // ---- 行为冒烟：推入 / 模态 / 返回全程无异常，旧页跟随位移在动 ----

  Widget harness() {
    final colors = YmColors.yamiboLight;
    return MaterialApp(
      theme: buildYmTheme(colors, Brightness.light),
      builder: (context, child) => YmScope(
        colors: colors,
        themeId: YmThemeId.yamibo,
        onThemeChanged: (_) {},
        child: child ?? const SizedBox.shrink(),
      ),
      home: const Scaffold(body: SizedBox.shrink()),
    );
  }

  testWidgets('层级推入 → 模态 → 逐级返回，动画全程无异常', (tester) async {
    await tester.pumpWidget(harness());
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));

    navigator.push(ymRoute(const Scaffold(body: Text('页A'))));
    await tester.pumpAndSettle();
    expect(find.text('页A'), findsOneWidget);

    navigator.push(ymRoute(const Scaffold(body: Text('页B'))));
    await tester.pump(const Duration(milliseconds: 100)); // 转场中段
    await tester.pumpAndSettle();
    expect(find.text('页B'), findsOneWidget);

    navigator.push(ymModalRoute(const Scaffold(body: Text('查看器'))));
    await tester.pump(const Duration(milliseconds: 80)); // 淡入中段
    await tester.pumpAndSettle();
    expect(find.text('查看器'), findsOneWidget);

    navigator.pop(); // 关模态：镜像淡出
    await tester.pumpAndSettle();
    expect(find.text('查看器'), findsNothing);
    expect(find.text('页B'), findsOneWidget);

    navigator.pop(); // 页B 退出：旧页（页A）横推回位
    await tester.pumpAndSettle();
    expect(find.text('页B'), findsNothing);
    expect(find.text('页A'), findsOneWidget);
  });

  testWidgets('推入转场中段：旧页在动（A 方案位移非零）、深底垫色不穿帮', (tester) async {
    await tester.pumpWidget(harness());
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));

    navigator.push(ymRoute(const Scaffold(body: Text('新页'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180)); // 420ms 的中段

    // 旧页的退移不抛异常即可；断言新页已在屏幕上（位移中段也该可见）。
    expect(find.text('新页'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  // ---- 贴图闸门：快照只在转场期间开（0.1.26「新页被冻住」回归）----
  //
  // SnapshotWidget 的贴图是静态照片，只在控制器广播 / 尺寸变化 / detach 时重拍。
  // 若常开（0.1.25 的写法），转场结束后页面就一直被那张照片盖着——数据回来、
  // 加载态换正文都看不见，表现为「新页冻住，直到再触发一次转场才更新」。

  List<SnapshotWidget> snapshots(WidgetTester tester) =>
      tester.widgetList<SnapshotWidget>(find.byType(SnapshotWidget)).toList();

  testWidgets('层级：转场中贴图、转场结束关掉（新页与旧页都一样）', (tester) async {
    await tester.pumpWidget(harness());
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));

    navigator.push(ymRoute(const Scaffold(body: Text('页A'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(snapshots(tester), isNotEmpty);
    for (final SnapshotWidget s in snapshots(tester)) {
      expect(s.controller.allowSnapshotting, isTrue,
          reason: '转场中必须贴图，否则光栅每帧重画整页');
    }

    await tester.pumpAndSettle();
    expect(snapshots(tester), isNotEmpty, reason: '路由还在，闸门也该在');
    for (final SnapshotWidget s in snapshots(tester)) {
      expect(s.controller.allowSnapshotting, isFalse,
          reason: '转场结束必须恢复逐帧实时绘制，否则页面内容被贴图冻住');
    }

    // 再推一页：被盖住的旧页也在动（secondaryAnimation），同样要贴图。
    navigator.push(ymRoute(const Scaffold(body: Text('页B'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(snapshots(tester).length, 2);
    for (final SnapshotWidget s in snapshots(tester)) {
      expect(s.controller.allowSnapshotting, isTrue, reason: '新旧两页都在动');
    }
    await tester.pumpAndSettle();
    for (final SnapshotWidget s in snapshots(tester)) {
      expect(s.controller.allowSnapshotting, isFalse);
    }
  });

  testWidgets('模态：淡入结束也关掉贴图', (tester) async {
    await tester.pumpWidget(harness());
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));

    navigator.push(ymModalRoute(const Scaffold(body: Text('查看器'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    for (final SnapshotWidget s in snapshots(tester)) {
      expect(s.controller.allowSnapshotting, isTrue);
    }

    await tester.pumpAndSettle();
    for (final SnapshotWidget s in snapshots(tester)) {
      expect(s.controller.allowSnapshotting, isFalse);
    }
  });

  testWidgets('snapshot: false 的页面（内嵌 WebView）整条路都不拍贴图', (tester) async {
    await tester.pumpWidget(harness());
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));

    navigator.push(ymRoute(const Scaffold(body: Text('网页')), snapshot: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(snapshots(tester), isEmpty);
    await tester.pumpAndSettle();
    expect(snapshots(tester), isEmpty);
  });

  // ---- 产品契约：转场结束后新页面必须还能更新（0.1.26「新页冻住」回归）----
  //
  // 这条只能用像素判：widget 树里的颜色/文字早就更新了，只是被那张贴图盖着，
  // finder 断言全都会过。所以整棵树外面套一层 RepaintBoundary 拍图比对中心像素。
  // 旧写法（贴图常开）在这条上会停在「改色前」的那个值。

  Future<int> centerPixel(WidgetTester tester, GlobalKey rootKey) async {
    int out = 0;
    await tester.runAsync(() async {
      final boundary =
          rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final ui.Image image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final int w = image.width;
      final int i = ((image.height ~/ 2) * w + w ~/ 2) * 4;
      out = (data!.getUint8(i) << 16) |
          (data.getUint8(i + 1) << 8) |
          data.getUint8(i + 2);
      image.dispose();
    });
    return out;
  }

  testWidgets('转场收尾后新页照样能更新：改内容不改尺寸也看得见', (tester) async {
    final color = ValueNotifier<Color>(const Color(0xFFFF0000));
    final rootKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: rootKey, child: harness()));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));

    navigator.push(ymRoute(ValueListenableBuilder<Color>(
      valueListenable: color,
      builder: (_, Color c, _) =>
          ColoredBox(color: c, child: const SizedBox.expand()),
    )));
    await tester.pumpAndSettle();
    expect(await centerPixel(tester, rootKey), 0xFF0000);

    // 「数据回来了」的最小形态：同一块区域换颜色，尺寸一点没变
    // —— 正是快照的 autoresize 救不到、只能靠闸门关掉的那一类。
    color.value = const Color(0xFF0000FF);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(await centerPixel(tester, rootKey), 0x0000FF,
        reason: '转场结束必须关贴图，否则页面被冻在打开那一帧（用户看到的「新页冻住」）');
  });

  // ---- 预测手势的口径：只认左边、纯平移 ----

  test('预测手势令牌：默认只认左边起手', () {
    expect(YmMotion.predictiveEdge, YmPredictiveBackEdge.left);
  });

  /// 伪造一次平台侧返回手势事件（走真实通道，和真机同一条路径）。
  Future<void> sendBack(String method, [Map<String, Object?>? args]) async {
    final ByteData data =
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(SystemChannels.backGesture.name, data, (_) {});
  }

  testWidgets('右边起手不认领（页面不动），左边起手跟手', (tester) async {
    await tester.pumpWidget(harness());
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));

    final PageRoute<void> route = ymRoute(const Scaffold(body: Text('页')));
    navigator.push(route);
    await tester.pumpAndSettle();

    // 右边缘起手：不认领 ⇒ 页面停在满屏，手势状态保持 none。
    await sendBack('startBackGesture',
        {'progress': 0.3, 'swipeEdge': 1, 'touchOffset': <double>[1200, 800]});
    await tester.pump();
    expect(route.animation!.value, 1.0, reason: '右边起手不许动页面');
    expect(YmPredictiveBackWatcher.gestureState.value.active, isFalse);

    // 左边缘起手：认领 ⇒ 动画值跟进度走（1 - progress = 0.7）。
    await sendBack('startBackGesture',
        {'progress': 0.3, 'swipeEdge': 0, 'touchOffset': <double>[60, 800]});
    await tester.pump();
    expect(route.animation!.value, closeTo(0.7, 1e-6));
    expect(YmPredictiveBackWatcher.gestureState.value.active, isTrue);

    await sendBack('commitBackGesture');
    await tester.pumpAndSettle();
  });

  // ---- 两层同步（同时开始、同时结束，速度比 1:0.5）----
  //
  // 不变量：旧页左移量 + 0.5 × 新页右移量 == 0.5 × 屏宽，且与进度无关。
  // 只要两层共用同一个 p（新页 W(1−p)、旧页 0.5W·p），这条恒等式在每一帧都成立；
  // 一旦某一层换回自己的曲线，这里立刻红。

  List<double> translateXs(WidgetTester tester) {
    final xs = <double>[];
    for (final Transform t in tester.widgetList<Transform>(find.byType(Transform))) {
      final m = t.transform.storage;
      if (m[1] != 0 || m[3] != 0 || m[13] != 0) continue; // 只取纯横移
      xs.add(m[12]);
    }
    return xs;
  }

  testWidgets('两层同步：旧页位移 + 0.5×新页位移 恒等于半屏（推入与返回）', (tester) async {
    await tester.pumpWidget(harness());
    final double w = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final route = ymRoute(const Scaffold(body: Text('页')));

    final samples = <String>[];
    void check(String phase) {
      final xs = translateXs(tester);
      if (xs.isEmpty) return;
      final front = xs.reduce((a, b) => a > b ? a : b); // 新页右移（0→W）
      final old = xs.reduce((a, b) => a < b ? a : b); // 旧页左移（0→−0.5W）
      if (front < 1 && old > -1) return; // 没在转场
      final got = -old + 0.5 * front;
      samples.add('$phase front=${front.toStringAsFixed(1)} old=${old.toStringAsFixed(1)}');
      expect(got, closeTo(0.5 * w, 2.0),
          reason: '两层必须在同一进度上：旧页位移 + 0.5×新页位移 应为半屏（$phase）');
    }

    navigator.push(route);
    for (int i = 0; i < 34; i++) {
      await tester.pump(const Duration(milliseconds: 14));
      check('push#$i');
    }
    await tester.pumpAndSettle();
    expect(samples, isNotEmpty, reason: '采样为空说明这段没在转场，断言等于没写');

    samples.clear();
    navigator.pop();
    for (int i = 0; i < 34; i++) {
      await tester.pump(const Duration(milliseconds: 14));
      check('pop#$i');
    }
    await tester.pumpAndSettle();
    expect(samples, isNotEmpty);
  });

  // ---- 取消回弹被返回打断 ----

  testWidgets('预测手势取消后立刻返回：退出仍走返回曲线，位移不跳、速度不变慢', (tester) async {
    await tester.pumpWidget(harness());
    final double w = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));

    double front() {
      final xs = translateXs(tester);
      return xs.isEmpty ? 0 : xs.reduce((a, b) => a > b ? a : b);
    }

    final route = ymRoute(const Scaffold(body: Text('页')));
    navigator.push(route);
    await tester.pumpAndSettle();

    // 触发预测手势 → 取消（回弹还没走完就返回）
    await sendBack('startBackGesture',
        {'progress': 0.4, 'swipeEdge': 0, 'touchOffset': <double>[60, 800]});
    await tester.pump(const Duration(milliseconds: 16));
    await sendBack('cancelBackGesture');
    await tester.pump(const Duration(milliseconds: 120));

    final before = front();
    expect(before, greaterThan(0.2 * w), reason: '前提：取消时页面确实被拖出去了一段');

    navigator.pop();
    await tester.pump(const Duration(milliseconds: 10));
    final first = front();
    expect(first, closeTo(before, 0.05 * w),
        reason: '返回第一帧不许跳（锚点没接上就会从 40% 直接跳到 87%）');

    expect(YmPredictiveBackWatcher.gestureState.value.active, isFalse,
        reason: '取消回弹被打断后，手势状态必须清掉，否则返回会退化成线性映射（变慢）');

    await tester.pump(const Duration(milliseconds: 50));
    final after = front();
    final remaining = w - before;
    expect(after - before, greaterThan(0.45 * remaining),
        reason: '剩下的路程必须前加载（close 曲线），线性映射在大约 1/4 时间只走 25%');
    await tester.pumpAndSettle();
  });
}
