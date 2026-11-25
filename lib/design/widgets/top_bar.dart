import 'package:flutter/material.dart';

import '../pressable.dart';
import 'glyph.dart';
import '../theme.dart';
import '../tokens.dart';

/// 顶栏：72px 是**状态栏以下**的栏高，所以最小高度要把状态栏加上。
/// 这正好对应 uni 工程里「顶栏 72px 保底被状态栏吃掉」那个问题。
class YmTopBar extends StatelessWidget {
  const YmTopBar({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = YmScope.of(context).colors;
    final statusBar = MediaQuery.paddingOf(context).top;

    return Container(
      constraints: BoxConstraints(minHeight: statusBar + YmLayout.topBarMin),
      // 内距 statusBar / 0（资产包 2026-10-28 复原：母本 .ios-fixed-topbar padding:statusBar 14 0）。
      padding: EdgeInsets.only(
        top: statusBar,
        left: YmLayout.pagePad,
        right: YmLayout.pagePad,
        bottom: 0,
      ),
      decoration: BoxDecoration(
        // 半透明档 + 投影（资产包 T03-02b）：滚动内容从底下微微透出，顶栏有分离层。
        color: colors.topbarBg,
        border: Border(bottom: BorderSide(color: colors.topbarBd)),
        boxShadow: YmShadows.topbar,
      ),
      // 内距是 statusBar/0，72 的余量靠对齐居中吃掉（资产包同构）。
      alignment: Alignment.center,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 10)],
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  // 宽屏（>430）母本是 27/800（--fs-hero-27），手机档 24/800。
                  style: MediaQuery.sizeOf(context).width > YmLayout.bpNarrow
                      ? colors.hero27.copyWith(height: 1.12)
                      : colors.title24.copyWith(height: 1.12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: colors.small12,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 42×42 圆形返回钮，与资产包 .back 同尺寸。
class YmBackButton extends StatelessWidget {
  const YmBackButton({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return YmCircleButton(
      // 资产包 SlateBackButton：19 盒 / 2px。竖向墨迹 = 14·(19/24) + 2 ≈ 13.1px，
      // 与 26 字号的箭头墨迹同高；原来按 26 盒画会大一圈。
      icon: YmGlyph(kind: YmGlyphKind.back, size: 19, strokeWidth: 2, color: c.textStrong),
      onTap: onTap ?? () => Navigator.of(context).maybePop(),
    );
  }
}

/// 42×42 圆形图标钮 —— 与返回钮、弹层关闭钮同一套外观（card 底 + 1px 描边 + pop 投影）。
/// 顶栏右侧的动作（如「在网页里打开」）用它，别另外造一种按钮。
class YmCircleButton extends StatelessWidget {
  const YmCircleButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.semanticLabel,
  });

  final Widget icon;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = YmScope.of(context).colors;
    // 与 SlateCloseButton 同构：外层 SizedBox(42) 硬约束尺寸，描边/投影走
    // YmPressable 的 border/boxShadow（缩放层内），按下时整个 42 圆一起下沉。
    // 不能不给约束——带 border 的 Container 会按「child + border 宽」定尺寸，
    // 42 的图标盒会撑成 44×44，radius 21 在 44 的盒里就不是正圆了。
    final button = SizedBox(
      width: 42,
      height: 42,
      child: YmPressable(
        kind: YmPressKind.neutral,
        baseColor: colors.card,
        radius: BorderRadius.circular(21),
        border: Border.all(color: colors.border),
        boxShadow: YmShadows.pop,
        onTap: onTap,
        child: Center(child: icon),
      ),
    );
    if (semanticLabel == null) return button;
    return Semantics(label: semanticLabel, button: true, child: button);
  }
}

class YmSectionHeader extends StatelessWidget {
  const YmSectionHeader({
    super.key,
    required this.title,
    this.action,
    this.onAction,
    this.padding = const EdgeInsets.symmetric(horizontal: 14),
  });

  final String title;
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = YmScope.of(context).colors;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(child: Text(title, style: colors.sub13Strong)),
          if (action != null)
            // 文字动作：资产包 T22-04 / T24-06 走 dim .6，不挂换底。
            YmPressable(
              kind: YmPressKind.dim,
              dimOpacity: 0.6,
              radius: BorderRadius.circular(YmRadius.chip),
              onTap: onAction,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  action!,
                  style: colors.sub13Strong.copyWith(color: colors.text2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 22 定高小标签（数据角标：分类 / 连载状态 / 授权）。
///
/// 对应资产包 T17-12 `SlateTag`（controls/chips.dart），声明与它逐字一致：
/// `brand` 档＝第二宿主（百合会）`.tag.brand` 的 650 → snap **w700**，
/// 普通档**没有字重声明、继承 400**。原先普通档写 w500 是自己加的，比母本重一档。
class YmTag extends StatelessWidget {
  const YmTag(this.text, {super.key, this.brand = false});

  final String text;
  final bool brand;

  @override
  Widget build(BuildContext context) {
    final colors = YmScope.of(context).colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: brand ? colors.brandTint : colors.fill,
        borderRadius: BorderRadius.circular(YmRadius.pill),
      ),
      child: Text(
        text,
        style: colors.micro11.copyWith(
          color: brand ? colors.brandInk : colors.text2,
          fontWeight: brand ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
    );
  }
}

/// 顶栏右侧的文字动作（排行 / 详情）。
class YmTextAction extends StatelessWidget {
  const YmTextAction({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return YmPressable(
      kind: YmPressKind.row,
      radius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
        child: Text(label, style: c.sub13Strong.copyWith(color: c.text2)),
      ),
    );
  }
}

/// 样本数据必须显式标注时间点，不伪装成实时数据。
class YmSampleTip extends StatelessWidget {
  const YmSampleTip({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = YmScope.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 22),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: colors.micro11.copyWith(color: colors.text3),
      ),
    );
  }
}
