import 'package:flutter/material.dart';

import '../../../data/forum/forum_track.dart';
import '../../pressable.dart';
import '../../theme.dart';
import '../../tokens.dart';

/// 追帖 / 阅读历史行：标题最多两行 + 「板块 · 作者」+ 进度一行，右侧最近阅读时间。
///
/// 进度只到楼层：读到 128 楼 · 第 7/12 页。
/// [ForumTrackRecord.totalPages] 为 0（单页帖 / 站点没给总页数）时只写「读到 N 楼」，
/// 不编页数。不写死高度，让内容自然长高；按压档沿用整宽行 `row`。
@immutable
class YmForumTrackRow extends StatelessWidget {
  const YmForumTrackRow({
    super.key,
    required this.record,
    required this.onTap,
    this.onLongPress,
  });

  final ForumTrackRecord record;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;

    final where = <String>[
      if (record.boardName.isNotEmpty) record.boardName,
      if (record.author.isNotEmpty) record.author,
    ].join(' · ');

    final progress = record.lastFloor > 0
        ? (record.totalPages > 0
            ? '读到 ${record.lastFloor} 楼 · 第 ${record.lastPage}/${record.totalPages} 页'
            : '读到 ${record.lastFloor} 楼')
        : (record.title.isNotEmpty ? '还没开始读' : '');

    return YmPressable(
      kind: YmPressKind.row,
      radius: BorderRadius.zero,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.title.isNotEmpty ? record.title : '（无标题）',
                    style: TextStyle(
                      fontSize: YmFont.strong16,
                      fontWeight: FontWeight.w700,
                      height: 1.42,
                      color: c.text,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (where.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      where,
                      style: TextStyle(
                        fontSize: YmFont.small12,
                        height: 1.4,
                        color: c.text2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (progress.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      progress,
                      style: TextStyle(
                        fontSize: YmFont.small12,
                        height: 1.4,
                        color: c.text3,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (record.lastReadAt > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  _recentTime(record.lastReadAt),
                  style: TextStyle(fontSize: YmFont.micro11, color: c.text3),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 最近阅读时间：今天出时刻，昨天出「昨天」，更早出「M/D」。
/// 纯本地展示用，站点原文时间不进这里（追帖记录是毫秒时间戳）。
String _recentTime(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  String dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';
  if (dayKey(dt) == dayKey(now)) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
  final yesterday = now.subtract(const Duration(days: 1));
  if (dayKey(dt) == dayKey(yesterday)) return '昨天';
  return '${dt.month}/${dt.day}';
}
