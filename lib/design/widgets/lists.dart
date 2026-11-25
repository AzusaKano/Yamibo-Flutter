import 'dart:io' show File;

import 'package:flutter/material.dart';

import '../pressable.dart';
import '../theme.dart';
import '../tokens.dart';
import 'cover.dart';
import 'selection.dart';
import 'top_bar.dart';
import '../text_scale.dart';

/// 卡片列表容器，对齐 uni 的 `.list`：左右 14px、`--card` 底、24px 圆角，
/// 行间用 `--border-weak` 分隔（最后一行没有分隔线）。
///
/// ⚠ `Column` 必须 `stretch`：默认的 `center` 会让「内部是 `Column` 的行」
/// （如 `YmRcmdRow`，文字是松约束 ⇒ 宽度等于最长那行的自然宽）整块被居中，
/// 看起来像页面内容居中了。`Row` 打底的行自带 `Expanded` 撑满，掩盖了这个坑。
class YmCardList extends StatelessWidget {
  const YmCardList({
    super.key,
    required this.children,
    this.margin = const EdgeInsets.symmetric(horizontal: 14),
  });

  final List<Widget> children;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Container(height: 1, color: c.borderWeak));
      }
      rows.add(children[i]);
    }
    return Container(
      margin: margin,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.card,
        // 16 = 页内嵌入块档（造件规则 §2）。宿主口径登记（2026-11-09 拍板）：
        // 本件对的是 uni `.list`；资产包同类件的设置列表壳（T23 SlateSettingsList，
        // listRadius = SlateRadius.box）同样是 16，不是 24。
        borderRadius: BorderRadius.circular(YmRadius.box),
      ),
      // 行一律撑满卡片宽（uni 里 `.list` 的子项都是块级元素）
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
    );
  }
}

/// 提示条，对齐 uni 的 `.tip`。
class YmTip extends StatelessWidget {
  const YmTip(this.text, {super.key, this.margin = const EdgeInsets.fromLTRB(14, 0, 14, 12)});

  final String text;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(YmRadius.inner),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: YmFont.micro11,
          height: 1.5,
          color: c.text2,
        ),
      ),
    );
  }
}

/// 列表尾部「加载更多 / 已全部加载 / 正在加载…」，对齐 `.load-more`。
class YmLoadMore extends StatelessWidget {
  const YmLoadMore({
    super.key,
    required this.loading,
    required this.hasMore,
    required this.doneText,
    this.onTap,
  });

  final bool loading;
  final bool hasMore;
  final String doneText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    Widget child;
    if (loading) {
      // 状态文字（说明类）：继承 sub13 的 400，不写字重。
      // 原先显式 w600，与本件「已全部加载」态的 400 自相矛盾。
      child = Text(
        '正在加载…',
        style: TextStyle(fontSize: YmFont.sub13, color: c.brandInk),
      );
    } else if (hasMore) {
      child = YmPressable(
        kind: YmPressKind.row,
        radius: BorderRadius.circular(YmRadius.ctrl),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            height: 44,
            child: Center(
              child: YmTextScale.clampFixed(
                child: Text(
                  '加载更多',
                  // 文字动作＝控件标签：资产包按钮/文字动作档 15·w700（T06-06、
                  // T22-04 SlateTopBarAction），12~13px 落 w700。原 w600 不是声明值。
                  style: TextStyle(
                    fontSize: YmFont.sub13,
                    fontWeight: FontWeight.w700,
                    color: c.brandInk,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } else {
      child = Text(
        doneText,
        style: TextStyle(fontSize: YmFont.sub13, color: c.text3),
      );
    }

    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      margin: const EdgeInsets.fromLTRB(14, 6, 14, 0),
      alignment: Alignment.center,
      child: child,
    );
  }
}

/// 小封面 + 主信息的两段行（uni 的 `.book-row`）：
/// 漫画首页「最近更新」、书架、历史共用这一形态。
class YmBookRow extends StatelessWidget {
  const YmBookRow({
    super.key,
    required this.title,
    this.cover = '',
    this.coverLocal,
    this.line,
    this.trailing,
    this.progress,
    this.footTag,
    this.footText,
    this.onTap,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
  });

  final String title;
  final String cover;

  /// 本机封面（离线保存时落的那张）：传了就走 `Image.file`，
  /// 断网 / 封面 URL 签名过期也出图（缓存第三期补丁）。
  final File? coverLocal;

  final String? line;
  final Widget? trailing;
  final double? progress;
  final String? footTag;
  final String? footText;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// T23-04 多选口径：选择模式下行尾勾槽常显；选中铺 brand-tint（列表行属于列表类，
  /// 不用卡级选中的 draw 边 + ring）。
  final bool selectionMode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final hasFoot = (footTag != null && footTag!.isNotEmpty) ||
        (footText != null && footText!.isNotEmpty);

    return YmPressable(
      kind: YmPressKind.row,
      // T23-04：多选行选中时整行铺 brand-tint（SlateSettingsRow 的 picked 口径）。
      baseColor: selected ? c.brandTint : null,
      radius: BorderRadius.zero,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              YmCover(
                title: title,
                url: cover,
                local: coverLocal,
                width: 46,
                height: 62,
                radius: YmRadius.inner,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: YmFont.body14,
                              fontWeight: FontWeight.w700,
                              height: 1.4,
                              color: c.text,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
                      ],
                    ),
                    if (line != null && line!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        line!,
                        style: TextStyle(
                          fontSize: YmFont.small12,
                          height: 1.5,
                          color: c.text2,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (progress != null) ...[
                      const SizedBox(height: 8),
                      _ShelfProgress(value: progress!),
                    ],
                    if (hasFoot) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          if (footTag != null && footTag!.isNotEmpty) ...[
                            YmTag(footTag!, brand: true),
                            const SizedBox(width: 6),
                          ],
                          if (footText != null && footText!.isNotEmpty)
                            Flexible(
                              child: Text(
                                footText!,
                                style: TextStyle(fontSize: YmFont.micro11, color: c.text3),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (selectionMode) ...[
                const SizedBox(width: 10),
                SizedBox(
                  height: 62,
                  child: Center(child: YmSelectionCheck(selected: selected)),
                ),
              ],
            ],
          ),
      ),
    );
  }
}

class YmBookmarkRow extends StatelessWidget {
  const YmBookmarkRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.tag,
    this.onTap,
    this.onLongPress,
  });

  /// 章节名（`第1章 一切的开始` / `001 月味之吻`）。
  final String title;

  /// `作品名 · 作者`。
  final String subtitle;

  /// 类型标签（小说 / 漫画）。
  final String tag;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return YmPressable(
      kind: YmPressKind.row,
      radius: BorderRadius.zero,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: YmFont.body14,
                      fontWeight: FontWeight.w700,
                      height: 1.4,
                      color: c.text,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: YmFont.small12,
                      height: 1.4,
                      color: c.text2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            YmTag(tag, brand: true),
          ],
        ),
      ),
    );
  }
}

class _ShelfProgress extends StatelessWidget {
  const _ShelfProgress({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Stack(
              children: [
                Container(height: 3, color: c.border),
                FractionallySizedBox(
                  widthFactor: value.clamp(0.0, 1.0),
                  child: Container(height: 3, color: c.accent),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${(value * 100).round()}%',
          style: TextStyle(fontSize: YmFont.micro11, color: c.text3),
        ),
      ],
    );
  }
}

/// 详情页目录行（uni 的 `.toc-row`）：可选的序号 + 名称 + 「读到这里」。
class YmTocRow extends StatelessWidget {
  const YmTocRow({
    super.key,
    required this.title,
    this.index,
    this.current = false,
    this.onTap,
    this.trailing,
  });

  final String title;
  final int? index;
  final bool current;
  final VoidCallback? onTap;

  /// 行尾可选的动作位（缓存第一期 1E：章节行右端的下载图标 / 进度环）。
  ///
  /// **默认 null ⇒ 现有全部调用逐字节不变**。热区由调用方给（44×44，与工程其他
  /// 行内动作同规格），行内不自己加内距 —— 这样「整行点击 = 阅读」与「图标区独立
  /// 响应」两件事不会互相抢宽度。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      color: current ? c.brandTint : null,
      child: YmPressable(
        kind: YmPressKind.row,
        radius: BorderRadius.zero,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              if (index != null) ...[
                SizedBox(
                  width: 28,
                  child: Text(
                    '$index',
                    textAlign: TextAlign.right,
                    // 序号列＝辅助信息（text3 三级文本）：不写字重，落回 small12 的 400。
                    // 原先显式 w700，属「把 12px 一律写粗」的旧口径。
                    style: TextStyle(
                      fontSize: YmFont.small12,
                      color: c.text3,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // ⚠ 这里必须显式写 w700：`TextStyle(fontSize: …)` 是**裸样式**，
                  // 不写 fontWeight 会落到 Flutter 默认的 400，而**不会**继承
                  // `c.body14` 那个 preset（preset 只是 getter，不是 TextStyle 的默认值）。
                  // 行标题按资产 SlateSettingsRow / SlateStopRow 的声明取 w700；
                  // 选中态只换字色（brandInk），不改字重——与 SlateChip 选中同做法。
                  style: TextStyle(
                    fontSize: YmFont.body14,
                    fontWeight: FontWeight.w700,
                    color: current ? c.brandInk : c.text,
                    height: 1.4,
                  ),
                ),
              ),
              if (current) ...[
                const SizedBox(width: 8),
                Text(
                  '读到这里',
                  // 状态标记（accent 色）：资产包同类标记声明加粗——
                  // 「已过出发」小标签 micro11·w700（saved_route_card.dart）。
                  style: TextStyle(
                    fontSize: YmFont.micro11,
                    fontWeight: FontWeight.w700,
                    color: c.accentInk,
                  ),
                ),
              ],
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// 详情页「展开全部 N 章」条，对齐 `.more-btn`。
class YmMoreButton extends StatelessWidget {
  const YmMoreButton({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      child: YmPressable(
        kind: YmPressKind.neutral,
        baseColor: c.fill,
        radius: BorderRadius.circular(YmRadius.ctrl),
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Center(
            child: YmTextScale.clampFixed(
              child: Text(
                label,
                // 按钮标签取 w700（资产包 SlateButton 的内容字重）。
                // ⚠ 裸 TextStyle 不写 fontWeight 会在 400，绝不会"落回 preset"。
                style: TextStyle(
                  fontSize: YmFont.body14,
                  fontWeight: FontWeight.w700,
                  color: c.brandInk,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
