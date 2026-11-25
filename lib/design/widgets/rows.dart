import 'dart:io' show File;

import 'package:flutter/material.dart';

import '../../data/library.dart';
import '../../data/models.dart';
import '../pressable.dart';
import '../theme.dart';
import '../tokens.dart';
import 'lists.dart';
import 'top_bar.dart' show YmTag;

/// 排行行，对齐 uni `.work-row.rank-row`：
/// 名次（前三名品牌色）+ 书名 + 状态标签 / 作者 / 分类与授权标签。
class YmRankRow extends StatelessWidget {
  const YmRankRow({super.key, required this.item, this.onTap});

  final YmRankItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final top = item.rank <= 3;
    final license = item.license.isNotEmpty && item.license != '普通' ? item.license : '';

    return YmPressable(
      kind: YmPressKind.row,
      radius: BorderRadius.zero,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 22,
              child: Text(
                '${item.rank}',
                textAlign: TextAlign.center,
                // ⚠ 例外（书面）：名次是排行件的**等级标记**，不是说明文字——
                // 前三名还给 accent 色。16px 档不在本次四档小字口径内，
                // w800 与本列「前三名更醒目」的意图一致，故保留强于 strong16 默认的 700。
                style: TextStyle(
                  fontSize: YmFont.strong16,
                  fontWeight: FontWeight.w800,
                  color: top ? c.accentInk : c.text3,
                  height: 1.3,
                ),
              ),
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
                          item.title,
                          style: TextStyle(
                            fontSize: YmFont.body14,
                            fontWeight: FontWeight.w700,
                            height: 1.45,
                            color: c.text,
                          ),
                        ),
                      ),
                      if (item.status.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        YmTag(item.status, brand: item.status == '连载中'),
                      ],
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    item.author.isEmpty ? '佚名' : item.author,
                    style: TextStyle(
                      fontSize: YmFont.small12,
                      height: 1.5,
                      color: c.text2,
                    ),
                  ),
                  if (item.cat.isNotEmpty || license.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (item.cat.isNotEmpty) ...[
                          YmTag(item.cat),
                          const SizedBox(width: 6),
                        ],
                        if (license.isNotEmpty) YmTag(license),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 编辑推荐行：书名 + 推荐语（原文等于书名时不重复显示）+ 推荐时间。
class YmRcmdRow extends StatelessWidget {
  const YmRcmdRow({super.key, required this.item, this.onTap});

  final YmRcmdItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final intro = item.intro == item.title ? '' : item.intro;

    return YmPressable(
      kind: YmPressKind.row,
      radius: BorderRadius.zero,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.title,
              style: TextStyle(
                fontSize: YmFont.body14,
                fontWeight: FontWeight.w700,
                height: 1.45,
                color: c.text,
              ),
            ),
            if (intro.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                intro,
                style: TextStyle(
                  fontSize: YmFont.small12,
                  height: 1.55,
                  color: c.text2,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 7),
            Text(
              item.createdAt,
              style: TextStyle(fontSize: YmFont.micro11, color: c.text3),
            ),
          ],
        ),
      ),
    );
  }
}

/// 历史记录行（uni 的 `.book-row.shelf-row`）：小封面 + 书名 + 读到哪 + 进度 + 类型/作者。
class YmHistoryRow extends StatelessWidget {
  const YmHistoryRow({
    super.key,
    required this.entry,
    this.cover,
    this.coverLocal,
    this.onTap,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
  });

  final YmHistoryEntry entry;

  /// 本机封面（离线保存过的那本才有）：与书架行走同一条封面链路。
  final File? coverLocal;

  /// 行内封面地址；不传就用记录自带的（页面可按 id 兜底后传进来）。
  final String? cover;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selectionMode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return YmBookRow(
      title: entry.title,
      cover: cover ?? entry.cover,
      coverLocal: coverLocal,
      line: entry.chapterTitle.isEmpty ? '还没开始读' : '读到 ${entry.chapterTitle}',
      progress: entry.percent,
      footTag: entry.kind == 'manga' ? '漫画' : '小说',
      footText: entry.author,
      onTap: onTap,
      onLongPress: onLongPress,
      selectionMode: selectionMode,
      selected: selected,
    );
  }
}

class YmInfoRow extends StatelessWidget {
  const YmInfoRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 76, child: Text(label, style: c.small12.copyWith(color: c.text2))),
          Expanded(child: Text(value, style: c.small12.copyWith(color: c.text))),
        ],
      ),
    );
  }
}

class YmFactGrid extends StatelessWidget {
  const YmFactGrid({super.key, required this.facts});

  final List<(String, String)> facts;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < facts.length; i += 2) {
      final a = facts[i];
      final b = i + 1 < facts.length ? facts[i + 1] : null;
      rows.add(
        Row(
          children: [
            Expanded(child: YmInfoRow(label: a.$1, value: a.$2)),
            const SizedBox(width: 12),
            if (b != null) Expanded(child: YmInfoRow(label: b.$1, value: b.$2)),
          ],
        ),
      );
    }
    return Column(children: rows);
  }
}

/// 「我的」页的入口行，对齐 uni 的 `.book-row`（名称 + 副行 + 右箭头）。
class YmActionRow extends StatelessWidget {
  const YmActionRow({
    super.key,
    required this.title,
    this.value,
    this.onTap,
  });

  final String title;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return YmPressable(
      kind: YmPressKind.row,
      radius: BorderRadius.zero,
      onTap: onTap,
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
                    style: TextStyle(
                      fontSize: YmFont.body14,
                      fontWeight: FontWeight.w700,
                      height: 1.4,
                      color: c.text,
                    ),
                  ),
                  if (value != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      value!,
                      style: TextStyle(
                        fontSize: YmFont.small12,
                        height: 1.5,
                        color: c.text2,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Text('›', style: TextStyle(fontSize: YmFont.micro11, color: c.text3)),
          ],
        ),
      ),
    );
  }
}

/// 详情页的三项指标（点击 / 收藏 / 评分）：纯文字，不加底色块。
class YmFact extends StatelessWidget {
  const YmFact({super.key, required this.k, required this.v});

  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          Text(
            k,
            style: TextStyle(fontSize: YmFont.micro11, color: c.text2),
          ),
          const SizedBox(height: 3),
          Text(
            v.isEmpty ? '—' : v,
            style: TextStyle(
              fontSize: YmFont.body14,
              fontWeight: FontWeight.w700,
              color: c.text,
            ),
          ),
        ],
      ),
    );
  }
}
