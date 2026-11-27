import 'package:flutter/material.dart';

import '../../../data/forum/forum_user.dart';
import '../../theme.dart';
import '../../tokens.dart';
import 'forum_image.dart' show YmForumImage, forumAvatarUrl;

/// 资料页头卡（F-22）：品牌色块打底 + 64pt 头像 + 名字 + 用户组 + 最后访问。
///
/// 站点这份资料页**没有**背景图（两份真实样本各 0 处 `background-image`），
/// 所以不取页面图：用品牌色块 + 一点低透明度装饰圆给层次，取不到的是图不画，
/// 不是拿别的东西冒充。
///
/// 圆角取**大档** [YmRadius.card]（24）：这是 2026-11-27 用户真机确认后明确要求的
/// **单点例外**——头卡是全页最上、最大的一块，视觉上更像「页首主视觉」而不是
/// 页内平铺块，取大档才压得住下面那几张 16 的同层卡。所以同页的三格条、动作格、
/// 签名卡、资料表仍是 [YmRadius.box]（16），**只头卡是 24**；不要为了「统一」把
/// 下面几张也拉到 24，也不要反向把这一处判回 16。登记见 `docs/forum-components.md` F-22。
///
/// 头像不信页面给的 `_avatar_middle`（120px，铺到 64pt×3x 会糊）：
/// 自己按 uid 拼 `_avatar_big`（200px）。
class YmForumProfileHead extends StatelessWidget {
  const YmForumProfileHead({super.key, required this.profile});

  final ForumProfile profile;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.brand,
        borderRadius: BorderRadius.circular(YmRadius.card),
      ),
      child: Stack(
        children: [
          // 装饰圆：只是让整块平色有个光位，不承载任何信息
          Positioned(
            right: -30,
            top: -38,
            child: Container(
              width: 132,
              height: 132,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.accent.withValues(alpha: 0.18),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                YmForumImage(
                  url: _avatarBig(profile.uid),
                  width: 64,
                  height: 64,
                  fallbackText:
                      profile.name.isEmpty ? '会' : profile.name.characters.first,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: YmFont.strong17,
                          fontWeight: FontWeight.w800,
                          height: 1.3,
                          color: Colors.white,
                        ),
                      ),
                      if (profile.group.isNotEmpty ||
                          profile.adminGroup.isNotEmpty) ...[
                        const SizedBox(height: 7),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (profile.group.isNotEmpty)
                              _HeadChip(profile.group),
                            if (profile.adminGroup.isNotEmpty)
                              _HeadChip(profile.adminGroup),
                          ],
                        ),
                      ],
                      if (profile.lastVisit.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          '最后访问 ${profile.lastVisit}',
                          // 11px 白 72% 压在深色主题的 brand（#C0501A）上只有 3.2:1，
                          // 小字读不清。改成 12px 纯白：对比度 4.77:1（浅色 14.19:1）。
                          // 0.92 只有 4.28:1，仍差一点，所以这里不再压透明度。
                          style: const TextStyle(
                            fontSize: YmFont.small12,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 头像大图：路径规则沿用 [forumAvatarUrl]，只换文件名后缀。
  static String _avatarBig(String uid) {
    final small = forumAvatarUrl(uid);
    if (small.isEmpty) return '';
    return small.replaceFirst('_avatar_small.jpg', '_avatar_big.jpg');
  }
}

/// 头卡上的用户组标签（色块底上的白字小胶囊，不参与全局 YmChip 的两档体系）。
///
/// 底不再用「白 18%」：深色主题的 brand 本身偏亮（#C0501A），白 18% 覆层会把
/// 胶囊底推到 3.5:1（白 10% 也还有 4.05:1），12px 小字过不了 4.5。改成品牌淡色
/// 覆层（[YmColors.brandTint] 24%）后，深色 6.34:1、浅色 7.39:1，两套主题
/// 胶囊都还看得见形状——仍然只有令牌 + 透明度，没有 isDark 分支。
class _HeadChip extends StatelessWidget {
  const _HeadChip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.brandTint.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(YmRadius.pill),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: YmFont.small12,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}
