import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../tokens.dart';

/// 论坛角标（置顶 / 精华 / 投票 / 公告），对应草稿 `yf-mark`。
/// 尺寸字阶**对齐现成 YmTag**（22 高 / pill / tag10·w700 / padding 8，拆件表 B-04），
/// 差别只有语义色：YmTag 只有 brand/普通两档，投票需要第三色（例外 E-2，色取令牌既有角色）。
///  - [ForumMarkStyle.top] 置顶 / 公告：fill 底 + text2（草稿 `.yf-mark.top`）
///  - [ForumMarkStyle.digest] 精华：brandTint 底 + brand（`.yf-mark.digest`）
///  - [ForumMarkStyle.vote] 投票：fill 底 + markBlueText + 1px 描边（`.yf-mark.vote`）
///
/// 文本一律站点原文，样式档由调用点按语义给，组件不猜。
enum ForumMarkStyle { top, digest, vote }

class YmForumMark extends StatelessWidget {
  const YmForumMark(this.text, {super.key, required this.style});

  final String text;
  final ForumMarkStyle style;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final (bg, fg, edge) = switch (style) {
      ForumMarkStyle.top => (c.fill, c.text2, null),
      ForumMarkStyle.digest => (c.brandTint, c.brand, null),
      ForumMarkStyle.vote => (c.fill, c.markBlueText, c.border),
    };
    return Container(
      // ⚠ 与 YmTag 同构：**不给 height、不给 alignment** —— Container(alignment:)
      // 在有界约束下会撑满整行宽度（帖子行里角标变全宽就是这个坑，chip.dart 头注同款）。
      // 定形全靠 padding（8/3）+ 文字本身；竖直居中由文字行高 1.2 自然给出。
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(YmRadius.pill),
        border: edge == null ? null : Border.all(color: edge),
      ),
      child: Text(
        text,
        // 与 YmTag 同字阶：micro11（草稿写的 tag10 与 YmTag 差一档，判类时归到 YmTag 规格）
        style: TextStyle(
          fontSize: YmFont.micro11,
          fontWeight: FontWeight.w700,
          height: 1.4,
          color: fg,
        ),
      ),
    );
  }
}
