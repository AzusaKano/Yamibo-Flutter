import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../pressable.dart';
import '../tokens.dart';
import 'glyph.dart';

/// T24 菜单：由现有按钮打开的 3~7 个短动作。
///
/// 照抄资产包 `rtgo_flutter` 的 `SlateMenu`（T24），不引整个包：壳/行/分组/
/// 触发器展开态是 A 类照抄，按压是 C 类照抄，两点字形（T18-09/10）是 B 类
/// 升级为 A 照抄进 `YmGlyphKind.more/moreDisc`。所有 Slate* 令牌换成工程 Ym*：
/// 圆角 `YmRadius.menu`、投影 `YmShadows.menu`、动效 `YmMotion.menu*`、
/// 字形 `YmGlyph`、按压 `YmPressable`、颜色 `YmScope`。
///
/// 位置由宿主**显式**给（top/right/bottom/left + origin），这里不做自动翻转、
/// 不做自动测量——与 CSS 侧 `--menu-*` 的口径一致。
///
/// 一个菜单只放当前上下文的短动作；危险动作放最后，点下去先关菜单，
/// 再由宿主接确认框。
///

/// 菜单从哪个角缩放。对应 CSS `transform-origin: var(--menu-origin)`。
enum YmMenuOrigin { topLeft, topRight, bottomLeft, bottomRight }

extension _YmMenuOriginAlignment on YmMenuOrigin {
  Alignment get alignment => switch (this) {
    YmMenuOrigin.topLeft => Alignment.topLeft,
    YmMenuOrigin.topRight => Alignment.topRight,
    YmMenuOrigin.bottomLeft => Alignment.bottomLeft,
    YmMenuOrigin.bottomRight => Alignment.bottomRight,
  };
}

/// 菜单的显式落点（相对整屏，含状态栏区域）。
///
/// 给哪条边就贴哪条边，另一条边留空。横向至少给一条边、纵向至少给一条边；
/// 不做自动翻转。
@immutable
class YmMenuPlacement {
  const YmMenuPlacement({
    this.top,
    this.right,
    this.bottom,
    this.left,
    this.origin = YmMenuOrigin.topRight,
  }) : assert(top != null || bottom != null, '纵向至少给 top 或 bottom'),
       assert(left != null || right != null, '横向至少给 left 或 right');

  final double? top;
  final double? right;
  final double? bottom;
  final double? left;
  final YmMenuOrigin origin;
}

/// 菜单尺寸与节奏（A 类，照抄资产 `SlateMenuMetrics`）。
class YmMenuMetrics {
  const YmMenuMetrics._();

  /// 面板内距。
  static const double panelPad = 6;

  /// 面板宽 208~280；`maxWidth` 还要被「屏宽 − 28」再夹一次。
  static const double minWidth = 208;
  static const double maxWidth = 280;
  static const double viewportInset = 28;

  /// 面板高上限：`min(70vh, 420)`。
  static const double maxHeight = 420;
  static const double maxHeightFactor = 0.70;

  /// 行：44 高；带描述 58；内距 12 / 10；行间 2；行圆角回 `YmRadius.ctrl`。
  static const double rowMinHeight = 44;
  static const double rowDescMinHeight = 58;
  static const double rowPadLeft = 12;
  static const double rowPadRight = 10;
  static const double rowPadVertical = 8;
  static const double rowGap = 10;
  static const double rowGapBetween = 2;

  /// 勾选槽 20。
  static const double checkSlot = 20;

  /// 分组标题：pad 8 12 4，12·650（Flutter snap 到 w700）。
  static const double groupPadTop = 8;
  static const double groupPadHorizontal = 12;
  static const double groupPadBottom = 4;

  /// 分隔线：1px `--border-weak`，margin 6 8。
  static const double separatorHeight = 1;
  static const double separatorMarginVertical = 6;
  static const double separatorMarginHorizontal = 8;

  /// 正文裸三点：视觉 20 / 热区 44；卡片右缘外扩 12。
  static const double dotsGlyph = 20;
  static const double dotsHit = YmLayout.hitMin;
  static const double dotsEdgeShift = 12;

  /// 正文文字触发器：44 高 / pad 0 4 / gap 4。
  static const double textTriggerHeight = YmLayout.hitMin;
  static const double textTriggerPad = 4;
  static const double textTriggerGap = 4;

  /// 顶栏中性圆钮 42。
  static const double iconButtonSize = 42;

  /// 顶栏圆钮里的三点：**24**（T18-10），与正文 / 底栏的 20（T18-09）是两档。
  static const double discDotsGlyph = 24;
}

/// 菜单行数据。`onTap` 只在 `enabled: false` 时允许为空（禁用态不是死控件）。
@immutable
class YmMenuItemData {
  const YmMenuItemData({
    required this.label,
    this.description,
    this.meta,
    this.checked = false,
    this.danger = false,
    this.enabled = true,
    this.onTap,
  }) : assert(!enabled || onTap != null, '可点的菜单行必须有回调；禁用态请传 enabled: false');

  final String label;
  final String? description;
  final String? meta;
  final bool checked;
  final bool danger;
  final bool enabled;
  final VoidCallback? onTap;
}

/// 菜单分组。`label` 为空时不出分组标题；`separatorAfter` 出 1px 分隔线。
@immutable
class YmMenuSection {
  const YmMenuSection({
    this.label,
    required this.items,
    this.separatorAfter = false,
  });

  final String? label;
  final List<YmMenuItemData> items;
  final bool separatorAfter;
}

/// 菜单打开/关闭的纯数值函数（C 类，照抄资产 `SlateMenuMotion`，数值走 `YmMotion`）。
class YmMenuMotion {
  const YmMenuMotion._();

  static double openScaleAt(double t) {
    final x = t.clamp(0.0, 1.0);
    if (x <= YmMotion.menuPeakAt) {
      final k = YmMotion.menuOpenCurve.transform(x / YmMotion.menuPeakAt);
      return YmMotion.menuOpenScale +
          (YmMotion.menuPeakScale - YmMotion.menuOpenScale) * k;
    }
    final k = YmMotion.menuOpenCurve.transform(
      (x - YmMotion.menuPeakAt) / (1 - YmMotion.menuPeakAt),
    );
    return YmMotion.menuPeakScale + (1 - YmMotion.menuPeakScale) * k;
  }

  static double openOpacityAt(double t) {
    final x = t.clamp(0.0, 1.0);
    if (x >= YmMotion.menuPeakAt) return 1;
    return YmMotion.menuOpenCurve.transform(x / YmMotion.menuPeakAt);
  }

  static double closeScaleAt(double t) {
    final x = t.clamp(0.0, 1.0);
    final k = YmMotion.menuOutCurve.transform(x);
    return 1 + (YmMotion.menuCloseScale - 1) * k;
  }

  static double closeOpacityAt(double t) {
    final x = t.clamp(0.0, 1.0);
    if (x <= YmMotion.menuFadeHold) return 1;
    return 1 - (x - YmMotion.menuFadeHold) / (1 - YmMotion.menuFadeHold);
  }
}

/// 菜单面板（A 类壳 + 行内容）。
class YmMenuPanel extends StatelessWidget {
  const YmMenuPanel({
    super.key,
    required this.sections,
    this.width,
    this.maxWidth = YmMenuMetrics.maxWidth,
    this.maxHeight = YmMenuMetrics.maxHeight,
    this.onActivate,
    this.semanticLabel,
  });

  final List<YmMenuSection> sections;
  final double? width;
  final double maxWidth;
  final double maxHeight;
  final ValueChanged<YmMenuItemData>? onActivate;
  final String? semanticLabel;

  void _activate(YmMenuItemData item) {
    if (!item.enabled) return;
    if (onActivate != null) {
      onActivate!(item);
    } else {
      item.onTap?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final minW = width ?? YmMenuMetrics.minWidth;
    final maxW = width ?? maxWidth;

    final rows = <Widget>[];
    for (final section in sections) {
      if (section.label != null) {
        rows.add(YmMenuGroupLabel(section.label!));
      }
      for (var i = 0; i < section.items.length; i++) {
        if (i > 0) {
          rows.add(const SizedBox(height: YmMenuMetrics.rowGapBetween));
        }
        final item = section.items[i];
        rows.add(
          YmMenuItem(
            label: item.label,
            description: item.description,
            meta: item.meta,
            checked: item.checked,
            danger: item.danger,
            enabled: item.enabled,
            onTap: () => _activate(item),
          ),
        );
      }
      if (section.separatorAfter) {
        rows.add(const YmMenuSeparator());
      }
    }

    final panel = Container(
      constraints: BoxConstraints(
        minWidth: minW,
        maxWidth: maxW,
        maxHeight: maxHeight,
      ),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(YmRadius.menu),
        boxShadow: YmShadows.menu,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(YmMenuMetrics.panelPad),
        physics: const ClampingScrollPhysics(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      ),
    );

    final sized = width == null ? IntrinsicWidth(child: panel) : panel;
    // 菜单是 PopupRoute，页面不在 Scaffold 的 Material 下。没有 Material 时
    // Text 会继承 Flutter 调试用的黄色双下划线；透明 Material 只补默认 TextStyle。
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        label: semanticLabel,
        explicitChildNodes: true,
        child: sized,
      ),
    );
  }
}

/// 一行菜单动作。44 高；有描述 58 高；按压只换底（`row`）。
class YmMenuItem extends StatelessWidget {
  const YmMenuItem({
    super.key,
    required this.label,
    this.description,
    this.meta,
    this.checked = false,
    this.danger = false,
    this.enabled = true,
    this.onTap,
  }) : assert(!enabled || onTap != null, '可点的菜单行必须有回调；禁用态请传 enabled: false');

  final String label;
  final String? description;
  final String? meta;
  final bool checked;
  final bool danger;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final hasDesc = description != null;
    final color = checked
        ? c.brandInk
        : danger
        ? c.danger
        : c.text;

    final row = YmPressable(
      kind: YmPressKind.row,
      // 不传 baseColor：交给 YmPressable 默认的「按压色 0 alpha」起点。
      // 写 Colors.transparent 是透明黑，lerp 会经过半透明灰（按下先灰一下）。
      pressedColor: danger ? c.errorBg : c.press,
      radius: BorderRadius.circular(YmRadius.ctrl),
      enabled: enabled,
      onTap: enabled ? onTap : null,
      semanticLabel: label,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: hasDesc
              ? YmMenuMetrics.rowDescMinHeight
              : YmMenuMetrics.rowMinHeight,
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            YmMenuMetrics.rowPadLeft,
            hasDesc ? YmMenuMetrics.rowPadVertical : 0,
            YmMenuMetrics.rowPadRight,
            hasDesc ? YmMenuMetrics.rowPadVertical : 0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: c.body15.copyWith(
                        height: 1.25,
                        color: color,
                        fontWeight: checked ? FontWeight.w700 : FontWeight.w600,
                      ),
                    ),
                    if (hasDesc) ...[
                      const SizedBox(height: 3),
                      Text(
                        description!,
                        style: c.small12.copyWith(
                          height: 1.45,
                          color: c.text2,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (meta != null) ...[
                const SizedBox(width: YmMenuMetrics.rowGap),
                Text(
                  meta!,
                  style: c.small12.copyWith(
                    color: c.text3,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
              if (checked) ...[
                const SizedBox(width: YmMenuMetrics.rowGap),
                SizedBox(
                  width: YmMenuMetrics.checkSlot,
                  height: YmMenuMetrics.checkSlot,
                  child: YmGlyph(
                    kind: YmGlyphKind.check,
                    size: YmMenuMetrics.checkSlot,
                    color: c.brand,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return Semantics(
      checked: checked,
      enabled: enabled,
      button: true,
      inMutuallyExclusiveGroup: checked,
      child: Opacity(opacity: enabled ? 1 : 0.4, child: row),
    );
  }
}

/// 分组标题：12·700 / `--text-2` / pad 8 12 4。
class YmMenuGroupLabel extends StatelessWidget {
  const YmMenuGroupLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        YmMenuMetrics.groupPadHorizontal,
        YmMenuMetrics.groupPadTop,
        YmMenuMetrics.groupPadHorizontal,
        YmMenuMetrics.groupPadBottom,
      ),
      child: Text(
        label,
        style: c.small12.copyWith(
          color: c.text2,
          height: 1.3,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 分组分隔线：1px `--border-weak`；margin 6 8。
class YmMenuSeparator extends StatelessWidget {
  const YmMenuSeparator({super.key});

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      height: YmMenuMetrics.separatorHeight,
      margin: const EdgeInsets.symmetric(
        horizontal: YmMenuMetrics.separatorMarginHorizontal,
        vertical: YmMenuMetrics.separatorMarginVertical,
      ),
      color: c.borderWeak,
    );
  }
}

/// 顶栏 42 圆钮触发器：card 底 + 1px 描边 + pop 投影；打开转 brand-tint + brand-ink。
class YmMenuIconTrigger extends StatelessWidget {
  const YmMenuIconTrigger({
    super.key,
    this.onTap,
    this.isOpen = false,
    this.semanticLabel = '更多操作',
  });

  final VoidCallback? onTap;
  final bool isOpen;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return YmPressable(
      kind: YmPressKind.neutral,
      baseColor: isOpen ? c.brandTint : c.card,
      radius: BorderRadius.circular(YmRadius.pill),
      border: Border.all(color: isOpen ? c.brandTint : c.border),
      boxShadow: YmShadows.pop,
      onTap: onTap,
      semanticLabel: semanticLabel,
      child: SizedBox(
        width: YmMenuMetrics.iconButtonSize,
        height: YmMenuMetrics.iconButtonSize,
        child: Center(
          // T18-10：圆钮里必须用「圆钮档」的三点（24），不是正文档（20）。
          child: YmGlyph(
            kind: YmGlyphKind.moreDisc,
            size: YmMenuMetrics.discDotsGlyph,
            color: isOpen ? c.brandInk : c.text,
          ),
        ),
      ),
    );
  }
}

/// 正文裸三点触发器：视觉 20 / 热区 44；无圆底、无边框；按压 dim .55。
///
/// [edge] 用于卡片右缘：把 44 热区向右侧外扩 12，让 20 点右缘与卡内文字对齐。
class YmMenuDots extends StatelessWidget {
  const YmMenuDots({
    super.key,
    this.onTap,
    this.isOpen = false,
    this.edge = false,
    this.semanticLabel = '更多操作',
  });

  final VoidCallback? onTap;
  final bool isOpen;
  final bool edge;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final button = YmPressable(
      kind: YmPressKind.dim,
      dimOpacity: 0.55,
      radius: BorderRadius.circular(YmRadius.ctrl),
      onTap: onTap,
      semanticLabel: semanticLabel,
      child: SizedBox(
        width: YmMenuMetrics.dotsHit,
        height: YmMenuMetrics.dotsHit,
        child: Center(
          child: YmGlyph(
            kind: YmGlyphKind.more,
            size: YmMenuMetrics.dotsGlyph,
            color: isOpen ? c.brandInk : c.text2,
          ),
        ),
      ),
    );

    if (!edge) return button;

    // CSS `.menu-dots.is-edge{margin:-11px -12px -11px 0}`：右侧负边距 12。
    // Flutter 没有负 margin，用 32 宽的外槽 + OverflowBox 让 44 热区向右溢出 12；
    // 溢出到父级外的 12 不参与命中，edge 变体实际可点区是 32×44。
    return SizedBox(
      width: YmMenuMetrics.dotsHit - YmMenuMetrics.dotsEdgeShift,
      height: YmMenuMetrics.dotsHit,
      child: OverflowBox(
        alignment: Alignment.centerLeft,
        minWidth: YmMenuMetrics.dotsHit,
        maxWidth: YmMenuMetrics.dotsHit,
        child: button,
      ),
    );
  }
}

/// 正文品牌文字触发器：14·700 + caretDown；按压 dim .6。
class YmMenuTextTrigger extends StatelessWidget {
  const YmMenuTextTrigger({
    super.key,
    required this.label,
    this.onTap,
    this.isOpen = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool isOpen;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return YmPressable(
      kind: YmPressKind.dim,
      dimOpacity: 0.6,
      radius: BorderRadius.circular(YmRadius.ctrl),
      onTap: onTap,
      semanticLabel: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: YmMenuMetrics.textTriggerHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: YmMenuMetrics.textTriggerPad,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: c.body14.copyWith(
                  color: isOpen ? c.brand : c.brandInk,
                  height: 1,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: YmMenuMetrics.textTriggerGap),
              YmGlyph(
                kind: YmGlyphKind.caretDown,
                size: 7,
                color: isOpen ? c.brand : c.brandInk,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 打开菜单。位置显式传入 [placement]；返回的 future 在菜单关闭后完成；
/// 行的 `onTap` 在关闭动画结束后才执行（危险动作先关菜单，再开确认框）。
Future<void> showYmMenu(
  BuildContext context, {
  required YmMenuPlacement placement,
  required List<YmMenuSection> sections,
  double? width,
  String? semanticLabel,
}) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    _YmMenuRoute(
      placement: placement,
      sections: sections,
      width: width,
      semanticLabel: semanticLabel,
    ),
  );
}

class _YmMenuRoute extends PopupRoute<void> {
  _YmMenuRoute({
    required this.placement,
    required this.sections,
    this.width,
    this.semanticLabel,
  });

  final YmMenuPlacement placement;
  final List<YmMenuSection> sections;
  final double? width;
  final String? semanticLabel;

  final Completer<void> _closed = Completer<void>();

  /// 关闭动画结束、路由被移除后完成。行回调等它，避免与关闭动画抢层。
  Future<void> get closed => _closed.future;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => semanticLabel ?? '关闭菜单';

  @override
  bool get opaque => false;

  @override
  bool get maintainState => false;

  @override
  Duration get transitionDuration => YmMotion.menuIn;

  @override
  Duration get reverseTransitionDuration => YmMotion.menuOut;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _YmMenuPage(
      route: this,
      animation: animation,
      placement: placement,
      sections: sections,
      width: width,
      semanticLabel: semanticLabel,
    );
  }

  @override
  void dispose() {
    if (!_closed.isCompleted) _closed.complete();
    super.dispose();
  }
}

class _YmMenuPage extends StatelessWidget {
  const _YmMenuPage({
    required this.route,
    required this.animation,
    required this.placement,
    required this.sections,
    this.width,
    this.semanticLabel,
  });

  final _YmMenuRoute route;
  final Animation<double> animation;
  final YmMenuPlacement placement;
  final List<YmMenuSection> sections;
  final double? width;
  final String? semanticLabel;

  void _activate(BuildContext context, YmMenuItemData item) {
    if (!item.enabled) return;
    Navigator.of(context).pop();
    route.closed.then((_) => item.onTap?.call());
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final maxWidth = math.max(
      YmMenuMetrics.minWidth,
      math.min(
        YmMenuMetrics.maxWidth,
        size.width - YmMenuMetrics.viewportInset,
      ),
    );
    final maxHeight = math.min(
      size.height * YmMenuMetrics.maxHeightFactor,
      YmMenuMetrics.maxHeight,
    );

    final panel = YmMenuPanel(
      sections: sections,
      width: width,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      onActivate: (item) => _activate(context, item),
      semanticLabel: semanticLabel,
    );

    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      label: semanticLabel ?? '菜单',
      explicitChildNodes: true,
      child: Stack(
        children: [
          Positioned(
            top: placement.top,
            right: placement.right,
            bottom: placement.bottom,
            left: placement.left,
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, child) {
                final reversing = animation.status == AnimationStatus.reverse;
                final t = animation.value;
                final scale = reversing
                    ? YmMenuMotion.closeScaleAt(1 - t)
                    : YmMenuMotion.openScaleAt(t);
                final opacity = reversing
                    ? YmMenuMotion.closeOpacityAt(1 - t)
                    : YmMenuMotion.openOpacityAt(t);
                return Opacity(
                  opacity: opacity,
                  child: Transform.scale(
                    scale: scale,
                    alignment: placement.origin.alignment,
                    child: child,
                  ),
                );
              },
              child: Focus(
                autofocus: true,
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.escape) {
                    Navigator.of(context).pop();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: panel,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
