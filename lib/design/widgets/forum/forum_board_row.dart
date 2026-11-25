import 'package:flutter/material.dart';

import '../../../data/forum/forum_models.dart';
import '../../pressable.dart';
import '../../theme.dart';
import '../../tokens.dart';

/// 论坛首页分区卡里的板块行（草稿 `yf-forum-row`）：
/// 34px 首字方牌（fill 底 + brand 首字，inner 圆角）+ 板块名（15/700）+
/// 一句话简介（small12，单行截断）+ 右侧「今日 N」。
///
/// 「今日 —」= 站点没印今日数（游客态常见），按草稿口径显式给「—」，不编数。
class YmForumBoardRow extends StatelessWidget {
  const YmForumBoardRow({super.key, required this.board, required this.onTap});

  final ForumBoardRef board;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return YmPressable(
      kind: YmPressKind.row,
      radius: BorderRadius.zero,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.fill,
                borderRadius: BorderRadius.circular(YmRadius.inner),
              ),
              child: Text(
                board.name.isEmpty ? '版' : board.name.characters.first,
                style: TextStyle(
                  fontSize: YmFont.sub13,
                  fontWeight: FontWeight.w700,
                  color: c.brand,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    board.name,
                    style: TextStyle(
                      fontSize: YmFont.body15,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                      color: c.text,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (board.desc.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      board.desc,
                      style: TextStyle(fontSize: YmFont.small12, color: c.text3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              board.today == null ? '今日 —' : '今日 ${board.today}',
              style: TextStyle(
                fontSize: YmFont.small12,
                fontWeight: board.today == null ? FontWeight.w500 : FontWeight.w700,
                color: board.today == null ? c.text3 : c.accentInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
