import 'package:flutter/material.dart';

import '../../../data/forum/forum_models.dart';
import '../../pressable.dart';
import '../../theme.dart';
import '../../tokens.dart';
import 'forum_mark.dart';

/// 帖子行（草稿 `yf-thread`）：角标 + 标题（16/700 最多两行）+ 元信息行
/// （作者 · 时间 · #分类，右对齐「N 回 · M 阅」）。
///
/// [compact] = 板块页置顶行（草稿 B 屏置顶条）：单行 15 号、角标内联、无元信息。
/// 行的可点回调必传；置顶公告没有 tid 时页面层传 null 并自行给「去网页看」的出口。
class YmForumThreadRow extends StatelessWidget {
  const YmForumThreadRow({
    super.key,
    required this.thread,
    required this.onTap,
    this.compact = false,
  });

  final ForumThreadSummary thread;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;

    final mark = thread.badge.isEmpty
        ? null
        : YmForumMark(thread.badge, style: _markStyle(thread.badge));

    if (compact) {
      return YmPressable(
        kind: YmPressKind.row,
        radius: BorderRadius.zero,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              if (mark != null) ...[mark, const SizedBox(width: 6)],
              Expanded(
                child: Text(
                  thread.title,
                  style: TextStyle(
                    fontSize: YmFont.body15,
                    fontWeight: FontWeight.w700,
                    height: 1.4,
                    color: c.text,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return YmPressable(
      kind: YmPressKind.row,
      radius: BorderRadius.zero,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (mark != null) ...[mark, const SizedBox(height: 5)],
            Text(
              thread.title,
              style: TextStyle(
                fontSize: YmFont.strong16,
                fontWeight: FontWeight.w700,
                height: 1.42,
                color: c.text,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                // 元信息「站点给什么印什么」：热点推荐条目只有标题 + 日期，
                // 作者 / 计数拿不到就安静不印（不编 0；0.1.23 热区换站方
                // 热点推荐数据源时加的口径，板块列表行不受影响——字段都有）
                if (thread.author.isNotEmpty) ...[
                  Flexible(
                    child: Text(
                      thread.author,
                      style: TextStyle(
                        fontSize: YmFont.small12,
                        fontWeight: FontWeight.w700,
                        color: c.text2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _dot(c),
                ],
                if (thread.time.isNotEmpty)
                  Flexible(
                    child: Text(
                      thread.time,
                      style: TextStyle(fontSize: YmFont.small12, color: c.text3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (thread.typeTag.isNotEmpty) ...[
                  _dot(c),
                  Flexible(
                    child: Text(
                      '#${thread.typeTag}',
                      style: TextStyle(fontSize: YmFont.small12, color: c.text3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                const Spacer(),
                if (thread.replies > 0 || thread.views > 0)
                  Text(
                    '${_fmt(thread.replies)} 回 · ${_fmt(thread.views)} 阅',
                    style: TextStyle(
                      fontSize: YmFont.small12,
                      fontWeight: FontWeight.w700,
                      color: c.text2,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dot(YmColors c) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Container(
        width: 2,
        height: 2,
        decoration: BoxDecoration(color: c.text3, shape: BoxShape.circle),
      ),
    );
  }

  static ForumMarkStyle _markStyle(String badge) {
    if (badge.contains('精华')) return ForumMarkStyle.digest;
    if (badge.contains('投票')) return ForumMarkStyle.vote;
    return ForumMarkStyle.top;
  }
}

/// 计数缩写：≥1 万折成「N 万」（草稿同一口径）。
String _fmt(int n) {
  if (n >= 10000) {
    final v = (n / 10000).toStringAsFixed(1);
    return '${v.endsWith('.0') ? v.substring(0, v.length - 2) : v}万';
  }
  return '$n';
}
