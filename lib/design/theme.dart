import 'package:flutter/material.dart';

import 'tokens.dart';
import 'ym_route.dart';

/// 两套配色，只有颜色不同；字号 / 圆角 / 动效与资产包一致。
enum YmThemeId { yamibo, rail }

extension YmThemeIdLabel on YmThemeId {
  String get label => switch (this) {
        YmThemeId.yamibo => '百合会',
        YmThemeId.rail => '轨交速查',
      };
}

YmColors ymPalette(YmThemeId id, Brightness brightness) => switch (id) {
      YmThemeId.yamibo =>
        brightness == Brightness.dark ? YmColors.yamiboDark : YmColors.yamiboLight,
      YmThemeId.rail =>
        brightness == Brightness.dark ? YmColors.railDark : YmColors.railLight,
    };

/// 把当前配色与切换入口交给整棵树。组件只从 [YmScope.of] 取颜色。
class YmScope extends InheritedWidget {
  const YmScope({
    super.key,
    required this.colors,
    required this.themeId,
    required this.onThemeChanged,
    required super.child,
  });

  final YmColors colors;
  final YmThemeId themeId;
  final ValueChanged<YmThemeId> onThemeChanged;

  static YmScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<YmScope>();
    assert(scope != null, 'YmScope is missing above this widget');
    return scope!;
  }

  @override
  bool updateShouldNotify(YmScope oldWidget) =>
      oldWidget.colors != colors || oldWidget.themeId != themeId;
}

ThemeData buildYmTheme(YmColors c, Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: c.brand,
    brightness: brightness,
  ).copyWith(
    primary: c.brand,
    onPrimary: Colors.white,
    secondary: c.accent,
    surface: c.card,
    onSurface: c.text,
    error: c.danger,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    cardColor: c.card,
    dividerColor: c.border,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.brandInk,
      selectionColor: c.brandTint,
    ),
    // 层级横推 + 预测式返回（ym_route.dart 的 YmPushTransitionsBuilder）：
    // MaterialPageRoute 全走这里，ymRoute 改一处全工程生效。
    // 模态路由（ymModalRoute）自己覆写 buildTransitions，不吃这份装配。
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: YmPushTransitionsBuilder(),
      TargetPlatform.iOS: YmPushTransitionsBuilder(),
      TargetPlatform.windows: YmPushTransitionsBuilder(),
      TargetPlatform.macOS: YmPushTransitionsBuilder(),
      TargetPlatform.linux: YmPushTransitionsBuilder(),
    }),
  );
}

/// 字号与行高按资产包的档位取，行高在 app.css 的对应类上抄来。
///
/// ⚠ 字重是「类属性」，不是「档属性」（资产包 2026-11-09 口径，rtgo_flutter v0.7.2）：
/// 同一个字号档在母本里对应多个字重。下面四档小字（sub13 / small12 / micro11 / tag10）
/// **默认取该档多数派 w400**，加粗由组件按母本那个类的声明显式覆盖
/// （`copyWith(fontWeight: FontWeight.w700 / w800)`，或直接用 [sub13Strong]）。
/// 判据永远是「母本/资产包里那个类有没有声明字重」，不是「这个字号在别处长什么样」。
extension YmTypography on YmColors {
  TextStyle get title24 =>
      TextStyle(fontSize: YmFont.title24, fontWeight: FontWeight.w800, height: 1.15, color: text);

  TextStyle get hero27 =>
      TextStyle(fontSize: YmFont.hero27, fontWeight: FontWeight.w800, height: 1.15, color: text);

  TextStyle get title21 =>
      TextStyle(fontSize: YmFont.title21, fontWeight: FontWeight.w800, height: 1.2, color: text);

  TextStyle get strong18 =>
      // 母本 .tt-section-title 是 850 → snap 到 w800（资产包同档）。
      TextStyle(fontSize: YmFont.strong18, fontWeight: FontWeight.w800, height: 1.3, color: text);

  TextStyle get strong16 =>
      TextStyle(fontSize: YmFont.strong16, fontWeight: FontWeight.w700, height: 1.35, color: text);

  TextStyle get body15 =>
      TextStyle(fontSize: YmFont.body15, fontWeight: FontWeight.w500, height: 1.5, color: text);

  TextStyle get body14 =>
      TextStyle(fontSize: YmFont.body14, fontWeight: FontWeight.w700, height: 1.45, color: text);

  TextStyle get body14Regular =>
      // 母本 .fact view 是 450 → snap 到 w400（资产包同档）。
      TextStyle(fontSize: YmFont.body14, fontWeight: FontWeight.w400, height: 1.45, color: text);

  TextStyle get sub13 =>
      TextStyle(fontSize: YmFont.sub13, fontWeight: FontWeight.w400, height: 1.5, color: text);

  TextStyle get sub13Strong =>
      // 加粗档：13px 里母本声明了加粗的那一小撮（分组标题、文字动作）显式取它。
      TextStyle(fontSize: YmFont.sub13, fontWeight: FontWeight.w700, height: 1.5, color: text);

  TextStyle get small12 =>
      TextStyle(fontSize: YmFont.small12, fontWeight: FontWeight.w400, height: 1.5, color: text2);

  TextStyle get micro11 =>
      // 默认取该档多数派 w400。原先写 700，依据是「母本 11px 字重都在 700~800」，
      // 但那句只数到了声明加粗的 8/32 条（`.tt-query-label` / `.station-slot-label` /
      // `.dt-label` 这类表格标签），漏掉继承 400 的 24 条（`.tl-stop` / `.ig-foot` /
      // `.sd-sub` / `.ex-meta` 这类说明文字）。母本 app.wxss 根级就是 400。
      // 加粗的那几处由组件显式写（如 YmTag 的 brand 档）。
      TextStyle(fontSize: YmFont.micro11, fontWeight: FontWeight.w400, height: 1.4, color: text3);

  TextStyle get tag10 =>
      // 同上：10px 档 7/23 条声明加粗，多数派仍是继承 400。
      TextStyle(fontSize: YmFont.tag10, fontWeight: FontWeight.w400, height: 1.2, color: text2);
}
