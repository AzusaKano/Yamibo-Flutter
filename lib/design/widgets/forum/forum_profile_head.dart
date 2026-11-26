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
                          style: TextStyle(
                            fontSize: YmFont.micro11,
                            color: Colors.white.withValues(alpha: 0.72),
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
class _HeadChip extends StatelessWidget {
  const _HeadChip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(YmRadius.pill),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: YmFont.tag10,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}
