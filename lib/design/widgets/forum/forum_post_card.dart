import 'package:flutter/material.dart';

import '../../../data/forum/forum_models.dart';
import '../../pressable.dart';
import '../../text_scale.dart';
import '../../theme.dart';
import '../../tokens.dart';
import 'forum_body.dart';
import 'forum_image.dart' show YmForumImage, forumAvatarUrl;
import 'forum_poll_block.dart';

/// 楼层卡（草稿 `yf-post`）：32px 圆头像 + 昵称 + 时间 + 右上楼层号，
/// 正文交给 [YmForumBody]（0.1.35 起：段落内联样式、原位图、分割线、折叠块、
/// 附件行、引用块都按 `ForumPost.blocks` 的顺序铺），
/// 点评折叠成一行条、评分摘要一条、首楼投票块。
/// 正文后不再平铺 `post.images`（图片只在块流里出现；字段保留给图片查看器）。
///
/// 组件不取数：评论展开与否由调用方声明（[commentsExpanded]），
/// 「还有 N 条」展开 / 楼层动作 / 链接与引用头跳转都走回调。
class YmForumPostCard extends StatelessWidget {
  const YmForumPostCard({
    super.key,
    required this.post,
    required this.isOp,
    required this.commentsExpanded,
    required this.onToggleComments,
    required this.onReply,
    this.onOpenPoll,
    this.onOpenImage,
    this.onOpenLink,
  });

  final ForumPost post;

  /// 是否楼主（首楼）：草稿给更重的一档投影。
  final bool isOp;

  /// 点评是否已展开（草稿口径：默认折叠，只铺 1–2 条 + 「还有 N 条」）。
  final bool commentsExpanded;
  final VoidCallback onToggleComments;

  /// 楼层「回复」动作（页面层决定去向：网页壳开到这一楼所在的页码）。
  /// 带上楼层：0.1.22 反馈——连读多页后点旧页楼层的回复，网页要落到那一楼，
  /// 不能落在最后加载的页。
  final void Function(ForumPost post) onReply;

  /// 首楼投票块「去网页版投票」的出口（0.1.38 新增，**与 [onReply] 分开**）：
  /// 页面层注入「打开帖页网页」，投票提交仍在网页里完成。
  /// 为什么不复用 [onReply]：0.1.38 起回复出口改成直开**回帖表单页**，
  /// 投票若还挂在它上面，「去网页版投票」会误开成回帖表单。
  /// null = 该块不可点（本卡在生产上只有帖子页一处调用，且必传）。
  final VoidCallback? onOpenPoll;

  /// 正文图点击（页面层打开 H 查看器，同帖多图连看）。null = 不可点（阶段 1 行为）。
  final void Function(String url)? onOpenImage;

  /// 正文链接 / 引用头点击（页面层路由：findpost 精准跳楼、站内原生、外站网页壳）。
  /// null = 链接按纯文字渲染，不可点。
  final void Function(String href)? onOpenLink;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final visibleComments = commentsExpanded
        ? post.comments
        : post.comments.take(2).toList();
    final hidden = post.comments.length - visibleComments.length;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      // 卡内横向 14（造件规则 §7 零例外，拆件表 V-1）
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(YmRadius.card),
        boxShadow: isOp ? YmShadows.card : YmShadows.pop,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              YmForumImage(
                url: _avatarUrl(post.authorUid),
                width: 32,
                height: 32,
                fallbackText: post.author.isEmpty ? '楼' : post.author.characters.first,
                borderRadius: BorderRadius.circular(16),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      post.author,
                      style: TextStyle(
                        fontSize: YmFont.sub13,
                        fontWeight: FontWeight.w700,
                        color: c.text,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (post.time.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        post.time,
                        style: TextStyle(fontSize: YmFont.micro11, color: c.text3),
                      ),
                    ],
                  ],
                ),
              ),
              Text(
                '${post.floor}#',
                style: TextStyle(
                  fontSize: YmFont.small12,
                  fontWeight: FontWeight.w700,
                  color: c.text3,
                ),
              ),
            ],
          ),
          if (post.blocks.isNotEmpty) ...[
            const SizedBox(height: 11),
            YmForumBody(
              blocks: post.blocks,
              pid: post.pid,
              onOpenLink: onOpenLink,
              onOpenImage: onOpenImage,
            ),
          ],
          if (post.poll != null)
            YmForumPollBlock(
              poll: post.poll!,
              // 独立出口（0.1.38）：不传就不可点，**不退回复出口**——
              // 复用回复出口会把「去网页版投票」误开成回帖表单
              onOpenWeb: onOpenPoll ?? () {},
            ),
          if (visibleComments.isNotEmpty) ...[
            const SizedBox(height: 2),
            YmForumCommentsBox(
              comments: visibleComments,
              moreCount: hidden,
              onMore: hidden > 0 ? onToggleComments : null,
            ),
          ],
          if (post.rate != null) YmForumRateLine(rate: post.rate!),
          const SizedBox(height: 11),
          Container(
            padding: const EdgeInsets.only(top: 9),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.borderWeak))),
            child: Row(
              children: [
                YmPressable(
                  kind: YmPressKind.dim,
                  dimOpacity: 0.6,
                  radius: BorderRadius.circular(YmRadius.chip),
                  onTap: () => onReply(post),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Text(
                      '回复',
                      style: TextStyle(
                        fontSize: YmFont.small12,
                        fontWeight: FontWeight.w700,
                        color: c.brand,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  isOp ? '楼主' : '',
                  style: TextStyle(fontSize: YmFont.small12, color: c.text3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 头像地址：uc_server 规则提成公共的 [forumAvatarUrl]（顶栏 / 我的页同用）。
  static String _avatarUrl(String uid) => forumAvatarUrl(uid);
}

/// 楼层点评条（fill 底 inner 圆角，一行一条）。
///
/// 0.1.36 从楼层卡里提升为公开件：帖子页折叠态用它，阅读器章末用它
/// （那里 `moreCount = 0`，全部点评直接铺开）。
class YmForumCommentsBox extends StatelessWidget {
  const YmForumCommentsBox({
    super.key,
    required this.comments,
    this.moreCount = 0,
    this.onMore,
  });

  final List<ForumComment> comments;
  final int moreCount;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        // 卡内嵌块取 fill（fillPlain 是弹层底，不跨层借底——拆件表 C-03）
        color: c.fill,
        borderRadius: BorderRadius.circular(YmRadius.inner),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final cm in comments) ...[
            Text.rich(
              TextSpan(
                style: TextStyle(fontSize: YmFont.small12, height: 1.62, color: c.text2),
                children: [
                  TextSpan(
                    text: cm.author,
                    style: TextStyle(fontWeight: FontWeight.w700, color: c.text),
                  ),
                  if (cm.time.isNotEmpty)
                    TextSpan(
                      text: '  ${cm.time}',
                      style: TextStyle(fontSize: YmFont.small12, color: c.text3),
                    ),
                  const TextSpan(text: '  '),
                  TextSpan(text: cm.text),
                ],
              ),
            ),
            const SizedBox(height: 5),
          ],
          if (moreCount > 0 && onMore != null)
            YmPressable(
              kind: YmPressKind.dim,
              dimOpacity: 0.6,
              radius: BorderRadius.circular(YmRadius.chip),
              onTap: onMore,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '还有 $moreCount 条点评 ›',
                  style: TextStyle(
                    fontSize: YmFont.small12,
                    fontWeight: FontWeight.w700,
                    color: c.brand,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 楼层评分（brandTint 底一行条）。
///
/// 0.1.36 起从楼层卡里提升为公开件，并把 [ForumRateItem.reason] 显示出来：
/// 汇总行保留原样（`评分 +N · M 人`），明细改成**每条一行**——
/// `用户名 +N 理由`；理由为空只留名字和分，不留空行。
/// 明细超过 [collapsedCount] 条时默认收起 3 条 + 「展开全部 N 条」，
/// 免得一楼被评分撑太长（可调；阅读器章末用同一个件）。
class YmForumRateLine extends StatefulWidget {
  const YmForumRateLine({
    super.key,
    required this.rate,
    this.collapsedCount = 3,
  });

  final ForumRate rate;

  /// 超过这个条数才折叠（≤ 这个数全展开）。
  final int collapsedCount;

  @override
  State<YmForumRateLine> createState() => _YmForumRateLineState();
}

class _YmForumRateLineState extends State<YmForumRateLine> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final rate = widget.rate;
    final items = rate.items;
    final fold = items.length > widget.collapsedCount;
    final visible =
        (!fold || _expanded) ? items : items.take(widget.collapsedCount).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.brandTint,
          borderRadius: BorderRadius.circular(YmRadius.inner),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: YmTextScale.clampFixed(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(
                style: TextStyle(fontSize: YmFont.small12, color: c.tint2Text),
                children: [
                  const TextSpan(text: '评分 '),
                  TextSpan(
                    text: '+${rate.score}',
                    style: TextStyle(fontWeight: FontWeight.w800, color: c.brand),
                  ),
                  TextSpan(text: ' · ${rate.people} 人'),
                ],
              ),
            ),
            for (final e in visible)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(
                      fontSize: YmFont.small12,
                      height: 1.5,
                      color: c.tint2Text,
                    ),
                    children: [
                      TextSpan(
                        text: e.name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(
                        text: ' +${e.delta}',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: c.brand,
                        ),
                      ),
                      // 理由为空时不追加任何占位（不留尾随空格 / 分隔符）
                      if (e.reason.isNotEmpty) TextSpan(text: '  ${e.reason}'),
                    ],
                  ),
                ),
              ),
            if (fold)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: YmPressable(
                  kind: YmPressKind.dim,
                  dimOpacity: 0.6,
                  radius: BorderRadius.circular(YmRadius.chip),
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      _expanded ? '收起' : '展开全部 ${items.length} 条',
                      style: TextStyle(
                        fontSize: YmFont.small12,
                        fontWeight: FontWeight.w700,
                        color: c.brand,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }
}
