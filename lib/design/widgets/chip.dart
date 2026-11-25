import 'package:flutter/material.dart';

import '../pressable.dart';
import '../theme.dart';
import '../tokens.dart';
import '../text_scale.dart';

/// 两种胶囊，对应资产包里的两个类，**不要混用**：
///
/// | 样式 | 资产包 | 底色 | 描边 | 字 | 用在哪 |
/// |---|---|---|---|---|---|
/// | [YmChipStyle.pill] | `.chip` | `--pills-bg` | 透明 | 13/500，选中白字 | 排序、状态、分类、字号… |
/// | [YmChipStyle.line] | `.station-line-chip` | `--card-lift` | 1px `--border` | 12/650 `--text-strong` | 搜索页类别条 / 类别网格 |
///
/// ⚠ 不要把 `line` 退化成 `pill`：类别条与选站弹层的线路条是同一套语言（浅底 + 细描边），
/// 与排序那排实底胶囊不是一回事（2026-10-23 用户反馈「被统一了底色」）。
enum YmChipStyle { pill, line }

/// 胶囊。按压档由调用点声明（规范要求），不按选中态推断。
class YmChip extends StatelessWidget {
  const YmChip({
    super.key,
    required this.label,
    this.active = false,
    this.onTap,
    this.trailing,
    this.expanded = false,
    this.compact = false,
    required this.style,
    required this.pressKind,
  });

  final String label;
  final bool active;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// 撑满父级（= 资产包 `.font-row .chip { flex: 1 1 0 }`）。
  final bool expanded;

  /// 34px 紧凑胶囊（`pill` 档专用；`line` 档本身就是 34px）。
  final bool compact;

  /// 外观档（必填，无默认）：pill = 排序/状态实底胶囊；line = 浅底细描边的线路/类别胶囊。
  final YmChipStyle style;

  /// 按压档（必填，无默认）。资产包 T07-01/02：胶囊不是统一档位，
  /// 由调用点按件声明；规范明确禁止 `selected ? solid : neutral` 这类回落。
  /// 本工程约定：大胶囊（排序/筛选/页内 tab）一律 solid（只缩，不换底）——资产包排序条/类别条同档。
  final YmPressKind pressKind;

  @override
  Widget build(BuildContext context) {
    final colors = YmScope.of(context).colors;
    final line = style == YmChipStyle.line;

    final fg = active ? Colors.white : (line ? colors.textStrong : colors.text);
    final bg = active ? colors.brand : (line ? colors.cardLift : colors.pillsBg);
    final edge = line
        ? (active ? colors.brand : colors.border)
        : Colors.transparent;
    final height = line ? 34.0 : (compact ? 34.0 : 44.0);
    final fs = line
        ? YmFont.small12
        : (compact ? YmFont.small12 : YmFont.sub13);

    return YmPressable(
      kind: pressKind,
      baseColor: bg,
      radius: BorderRadius.circular(YmRadius.pill),
      onTap: onTap,
      // ⚠ 不能用 `Container(alignment: ...)`：它在**有界**约束下会撑满可用宽度，
      // 而 `Wrap` 的子项拿到的正是有界 maxWidth ⇒ 里面的胶囊会全变成整行宽。
      // 居中交给 Row 的 mainAxisAlignment。
      // 定高件：字号放大上限钳到 1.5（资产包 D1）。
      child: YmTextScale.clampFixed(
        child: Container(
          width: expanded ? double.infinity : null,
          height: height,
          decoration: BoxDecoration(
            border: Border.all(color: edge),
            borderRadius: BorderRadius.circular(YmRadius.pill),
          ),
          padding: EdgeInsets.symmetric(
            horizontal: line ? 11 : (compact ? 11 : 14),
          ),
          child: Row(
            mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: colors.sub13.copyWith(
                  color: fg,
                  fontWeight: line ? FontWeight.w700 : FontWeight.w500,
                  fontSize: fs,
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 4), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}
