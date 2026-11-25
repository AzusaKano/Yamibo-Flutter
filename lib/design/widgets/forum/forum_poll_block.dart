import 'package:flutter/material.dart';

import '../../../data/forum/forum_models.dart';
import '../../pressable.dart';
import '../../theme.dart';
import '../../tokens.dart';
import '../button.dart';

/// 首楼投票块（草稿 `yf-poll`，未投态）：说明行 + 截止行 + 空心圈选项列表。
///
/// 阶段口径：**不做原生投票**（写操作一律开网页）。选项行不可点（none 档），
/// 提交入口由页面层给（打开站内网页）。票数百分比游客拿不到，不编。
/// 底色取 **fill**：本块是卡内嵌块，fillPlain 是弹层次要底，不跨层借底（拆件表 C-05）。
class YmForumPollBlock extends StatelessWidget {
  const YmForumPollBlock({
    super.key,
    required this.poll,
    required this.onOpenWeb,
  });

  final ForumPoll poll;

  /// 「去网页版投票」的出口（页面层注入）。
  final VoidCallback onOpenWeb;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(YmRadius.box),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (poll.info.isNotEmpty)
            Text(
              poll.info,
              style: TextStyle(fontSize: YmFont.small12, height: 1.55, color: c.text2),
            ),
          if (poll.end.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(poll.end, style: TextStyle(fontSize: YmFont.micro11, color: c.text3)),
          ],
          for (var i = 0; i < poll.options.length; i++)
            _OptionRow(index: i + 1, name: poll.options[i]),
          const SizedBox(height: 8),
          // 主操作档：YmButton 默认 48（拆件表 C-05，草稿 40 不在触控四档）
          YmButton(
            label: '去网页版投票',
            kind: YmButtonKind.primary,
            onTap: onOpenWeb,
            fontSize: YmFont.sub13,
          ),
          if (poll.guestNote.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              poll.guestNote,
              style: TextStyle(fontSize: YmFont.small12, color: c.text3),
            ),
          ],
        ],
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.index, required this.name});

  final int index;
  final String name;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return YmPressable(
      kind: YmPressKind.none,
      radius: BorderRadius.circular(YmRadius.inner),
      onTap: null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$index.$name',
                style: TextStyle(fontSize: YmFont.body14, color: c.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.card,
                border: Border.all(color: c.border, width: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
