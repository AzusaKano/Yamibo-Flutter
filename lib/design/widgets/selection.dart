import 'package:flutter/material.dart';

import '../pressable.dart';
import '../theme.dart';
import '../tokens.dart';
import 'glyph.dart';

/// T22 列表管理：管理底栏、顶栏文字动作、选中勾槽。
///
/// 与底栏导航并列：导航切页，本族管理当前列表。三段位都是裸文字，
/// 不挂 press 三档，只做 `:active` 透明度 .6（资产包 T22 口径）。

/// T22-01/02 的尺寸与节奏（A 类，资产包 SlateSelectMetrics 同值）。
class YmSelectMetrics {
  const YmSelectMetrics._();

  static const double barPadVertical = 8;
  static const double barPadHorizontal = YmLayout.pagePad;
  static const double barGap = 8;

  static const double actionMinHeight = 40;
  static const double actionPadHorizontal = 4;
  static const double actionEdgeShift = 4;

  static const double countFontSize = YmFont.small12;

  /// 选择模式页面让位：96 = 底栏 56 + 40 呼吸位。
  static const double pageBottomInset = 96;

  /// 勾槽：槽 20 / 空环 18 / 环 1.5 / 选中 scale 1.04 / 160ms。
  static const double checkSlot = 20;
  static const double checkRing = 18;
  static const double checkRingStroke = 1.5;
  static const double checkSelectedScale = 1.04;
  static const Duration checkTransition = Duration(milliseconds: 160);

  static const double topBarActionMinHeight = 40;
  static const double topBarActionPadHorizontal = 6;
}

/// 三段位的角色：左「全选」/ 右「删除」/ 右「普通动作（完成等）」。
enum YmSelectActionKind { selectAll, delete, action }

/// 底栏裸文字动作。按压只降透明度到 .6；禁用 .5 且真的点不动。
class YmSelectAction extends StatelessWidget {
  const YmSelectAction({
    super.key,
    required this.label,
    required this.kind,
    this.onTap,
    this.enabled = true,
  });

  final String label;
  final YmSelectActionKind kind;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final color = kind == YmSelectActionKind.delete ? c.danger : c.brand;

    final action = YmPressable(
      kind: YmPressKind.dim,
      dimOpacity: 0.6,
      enabled: enabled,
      onTap: onTap,
      semanticLabel: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: YmSelectMetrics.actionMinHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: YmSelectMetrics.actionPadHorizontal,
          ),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              label,
              maxLines: 1,
              style: c.body14.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );

    final shifted = switch (kind) {
      YmSelectActionKind.selectAll => Transform.translate(
        offset: const Offset(-YmSelectMetrics.actionEdgeShift, 0),
        child: action,
      ),
      YmSelectActionKind.delete || YmSelectActionKind.action =>
        Transform.translate(
          offset: const Offset(YmSelectMetrics.actionEdgeShift, 0),
          child: action,
        ),
    };

    return Opacity(opacity: enabled ? 1 : 0.5, child: shifted);
  }
}

/// 管理底栏外壳：宽 100%、上限 780、card 底、1px 顶边、safe bottom 内距。
class YmSelectBar extends StatelessWidget {
  const YmSelectBar({
    super.key,
    required this.countText,
    this.leading,
    this.trailing,
  });

  final String countText;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    return Align(
      alignment: Alignment.bottomCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: YmLayout.pageMax),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(
            YmSelectMetrics.barPadHorizontal,
            YmSelectMetrics.barPadVertical,
            YmSelectMetrics.barPadHorizontal,
            YmSelectMetrics.barPadVertical + safeBottom,
          ),
          decoration: BoxDecoration(
            color: c.card,
            border: Border(top: BorderSide(color: c.border)),
          ),
          child: Row(
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: YmSelectMetrics.barGap),
              ],
              Expanded(
                child: Text(
                  countText,
                  textAlign: TextAlign.center,
                  style: c.small12.copyWith(
                    color: c.text2,
                    fontSize: YmSelectMetrics.countFontSize,
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: YmSelectMetrics.barGap),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// T22-04 顶栏文字动作：40 高 / pad 0 6 / 15·w700 / brand；按压 .6。
class YmTopBarAction extends StatelessWidget {
  const YmTopBarAction({
    super.key,
    required this.label,
    this.onTap,
    this.enabled = true,
  });

  final String label;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return YmPressable(
      kind: YmPressKind.dim,
      dimOpacity: 0.6,
      enabled: enabled,
      onTap: onTap,
      semanticLabel: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: YmSelectMetrics.topBarActionMinHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: YmSelectMetrics.topBarActionPadHorizontal,
          ),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              label,
              maxLines: 1,
              style: c.body15.copyWith(
                color: c.brand,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// T12-06b / T22-03 选中勾槽：槽 20 常显；未选中画 18 空环，选中换成勾并 scale 1.04。
///
/// 它是**状态显示**，不是独立按钮；点击由外层整行负责。
class YmSelectionCheck extends StatelessWidget {
  const YmSelectionCheck({super.key, required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return ExcludeSemantics(
      child: AnimatedScale(
        scale: selected ? YmSelectMetrics.checkSelectedScale : 1,
        duration: YmSelectMetrics.checkTransition,
        curve: Curves.ease,
        child: SizedBox(
          width: YmSelectMetrics.checkSlot,
          height: YmSelectMetrics.checkSlot,
          child: selected
              ? YmGlyph(
                  kind: YmGlyphKind.check,
                  size: YmSelectMetrics.checkSlot,
                  color: c.brand,
                )
              : Center(
                  child: Container(
                    width: YmSelectMetrics.checkRing,
                    height: YmSelectMetrics.checkRing,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: c.text3,
                        width: YmSelectMetrics.checkRingStroke,
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
