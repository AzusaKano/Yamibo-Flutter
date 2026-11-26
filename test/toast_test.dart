import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yamibo_flutter/design/theme.dart';
import 'package:yamibo_flutter/design/tokens.dart';
import 'package:yamibo_flutter/design/widgets/toast.dart';

/// toast 挂在根 Overlay 上，不在 Scaffold 的 Material 之下：
/// 必须自带透明 Material，否则 Text 会落到 WidgetsApp 的错误样式（黄字 + 双下划线）。
void main() {
  testWidgets('toast 带 Material 祖先，文字不带 debug 下划线', (tester) async {
    final colors = YmColors.yamiboLight;
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildYmTheme(colors, Brightness.light),
        builder: (context, child) => YmScope(
          colors: colors,
          themeId: YmThemeId.yamibo,
          onThemeChanged: (_) {},
          child: child ?? const SizedBox.shrink(),
        ),
        home: Builder(
          builder: (context) {
            ctx = context;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );

    showYmToast(ctx, '已保存');
    await tester.pump();

    expect(find.text('已保存'), findsOneWidget);
    expect(
      find.ancestor(of: find.text('已保存'), matching: find.byType(Material)),
      findsWidgets,
    );

    // 走完停留与淡出，别留下 pending timer
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });
}
