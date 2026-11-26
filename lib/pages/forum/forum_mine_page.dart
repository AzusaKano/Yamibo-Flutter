import 'package:flutter/material.dart';

import '../../data/forum/forum_auth.dart';
import '../../data/forum/forum_track.dart';
import '../../design/theme.dart';
import '../../design/tokens.dart';
import '../../design/pressable.dart';
import '../../design/widgets/button.dart';
import '../../design/widgets/forum/forum_image.dart';
import '../../design/widgets/lists.dart' show YmCardList;
import '../../design/widgets/rows.dart';
import '../../design/widgets/sheet.dart' show showYmConfirm;
import '../../design/widgets/toast.dart';
import '../../design/widgets/top_bar.dart';
import '../../design/ym_route.dart';
import 'forum_history_page.dart' show ForumHistoryPage;
import 'forum_login_page.dart';
import 'forum_profile_page.dart' show ForumProfilePage;
import 'forum_web.dart';
import '../routes.dart' show ymPush;

/// F 我的论坛（草稿 F 屏）：账号卡 / 签到卡 / 收藏入口 / 提醒，从论坛首页顶栏进。
/// 受限态（未登录）按 G 屏同一口径：YmStateView / YmLoginRequired 的样子给一句人话。
///
/// 收藏列表与提醒是「登录后才有内容」的站内页：客户端只留入口，
/// 点进去开网页壳（登录态跟着走）；账号卡与签到卡是原生件。
class ForumMinePage extends StatefulWidget {
  const ForumMinePage({super.key});

  @override
  State<ForumMinePage> createState() => _ForumMinePageState();
}

class _ForumMinePageState extends State<ForumMinePage> {
  Future<void> _openLogin() async {
    await Navigator.of(context).push(ymRoute(const ForumLoginPage(), snapshot: false));
    if (!mounted) return;
    // 登录页成功会自己落盘并 pop；这里无条件刷一次账号视图
    setState(() {});
  }

  /// 退出论坛登录（与阅读侧账号互不影响）：站内注销 + 清论坛罐 + WebView bbs 域 Cookie。
  Future<void> _logoutForum() async {
    final ok = await showYmConfirm(
      context,
      title: '退出论坛登录',
      content: '确认退出论坛登录？阅读侧登录不受影响',
      confirmText: '退出',
      danger: true,
    );
    if (ok != true) return;
    await ForumAuth.logout();
    if (!mounted) return;
    showYmToast(context, '已退出论坛登录。');
  }

  void _openWeb(String path, String title) {
    if (!ForumSession.loggedIn) return;
    // 网页壳里的帖子 / 板块链接路由回原生页（forum_web.dart）
    openForumWeb(context, path: path, title: title);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ValueListenableBuilder<ForumAccount>(
        valueListenable: ForumSession.account,
        builder: (context, acc, _) {
          return Column(
            children: [
              YmTopBar(leading: const YmBackButton(), title: '我的论坛'),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
                  children: [
                    _AccountCard(
                      account: acc,
                      onLogin: _openLogin,
                      // 已登录才可点：未登录时那张卡上的动作是「登录论坛」按钮
                      onTap: acc.loggedIn
                          ? () => ymPush(context, const ForumProfilePage())
                          : null,
                    ),
                    const SizedBox(height: 14),
                    _SignCard(
                      signedIn: ForumSession.loggedIn,
                      onSign: () => _openWeb('/plugin.php?id=zqlj_sign&mobile=2', '每日打卡'),
                    ),
                    const SizedBox(height: 14),
                    YmCardList(
                      margin: EdgeInsets.zero,
                      children: [
                        // 阅读历史不需要登录：游客也能进，数字随 store 变。
                        AnimatedBuilder(
                          animation: ForumTrackStore.instance,
                          builder: (context, _) {
                            final n = ForumTrackStore.instance.recordCount;
                            return YmActionRow(
                              title: '阅读历史',
                              value: n > 0 ? '$n 条' : '还没有记录',
                              onTap: () =>
                                  ymPush(context, const ForumHistoryPage()),
                            );
                          },
                        ),
                        YmActionRow(
                          title: '我的空间',
                          value: acc.loggedIn ? '个人资料' : '登录后可用',
                          onTap: acc.loggedIn
                              ? () => ymPush(context, const ForumProfilePage())
                              : null,
                        ),
                        YmActionRow(
                          title: '我的收藏',
                          value: acc.loggedIn ? '收藏的帖子' : '登录后可用',
                          onTap: acc.loggedIn
                              ? () => _openWeb(
                                  '/home.php?mod=space&do=favorite&type=thread&mobile=2',
                                  '我的收藏')
                              : null,
                        ),
                        YmActionRow(
                          title: '提醒',
                          value: acc.loggedIn ? '站内提醒' : '登录后可用',
                          onTap: acc.loggedIn
                              ? () => _openWeb('/home.php?mod=space&do=notice&mobile=2', '提醒')
                              : null,
                        ),
                        if (acc.loggedIn)
                          YmActionRow(
                            title: '退出论坛登录',
                            onTap: _logoutForum,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 账号卡（草稿 `yf-me`）：头像 34（顶栏动作圆同档升 42 不适用卡内，卡内头像 34
/// 与草稿一致）+ 名字 + UID + 主按钮。
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account, required this.onLogin, this.onTap});

  final ForumAccount account;
  final VoidCallback onLogin;

  /// 点整张卡进自己的资料页（未登录时为空 = 不可点）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final loggedIn = account.loggedIn;
    final name = loggedIn ? (account.name.isNotEmpty ? account.name : '已登录') : '未登录论坛';
    // 底色 / 圆角 / 投影都挂在按压件上（不再套一层带装饰的 Container）：
    // 这样按下时的底色变化看得见，外观与原来逐字一致。
    return YmPressable(
      kind: YmPressKind.row,
      baseColor: c.card,
      radius: BorderRadius.circular(YmRadius.box),
      boxShadow: YmShadows.card,
      onTap: onTap,
      enabled: onTap != null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            YmForumImage(
              url: loggedIn ? forumAvatarUrl(account.uid) : '',
              width: 34,
              height: 34,
              fallbackText: loggedIn ? name.characters.first : '论',
              borderRadius: BorderRadius.circular(17),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: YmFont.strong16,
                      fontWeight: FontWeight.w800,
                      color: c.text,
                    ),
                  ),
                  if (loggedIn && account.uid.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      'UID ${account.uid}',
                      style: TextStyle(fontSize: YmFont.small12, color: c.text3),
                    ),
                  ],
                ],
              ),
            ),
            YmButton(
              label: loggedIn ? '已登录' : '登录论坛',
              kind: loggedIn ? YmButtonKind.tint : YmButtonKind.primary,
              onTap: loggedIn ? null : onLogin,
            ),
          ],
        ),
      ),
    );
  }
}

/// 打卡卡（草稿 `yf-sign`；打卡钮 36→42 档，拆件表 F-01 / V-8）。
///
/// 打卡**只走网页壳**（0.1.16 用户拍板）：站点防护层拦原生请求
/// （网页里的 WebView 能自动完成验证），且打卡页带「已连续打卡 N 天」等
/// 统计文案，原生判「已打卡」会误报——App 级尝试整条撤销。
class _SignCard extends StatelessWidget {
  const _SignCard({required this.signedIn, required this.onSign});

  final bool signedIn;
  final VoidCallback onSign;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final desc = signedIn ? '点右侧按钮，在网页里完成今日打卡。' : '登录论坛账号后，每天可以打一次卡。';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(YmRadius.box),
        boxShadow: YmShadows.pop,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '每日打卡',
                  style: TextStyle(
                    fontSize: YmFont.body15,
                    fontWeight: FontWeight.w700,
                    color: c.text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(desc, style: TextStyle(fontSize: YmFont.small12, color: c.text3)),
              ],
            ),
          ),
          YmButton(
            // 42 触控档（草稿 36 红线，拆件表 V-8）
            label: '打卡',
            kind: YmButtonKind.primary,
            onTap: signedIn ? onSign : null,
            height: 42,
          ),
        ],
      ),
    );
  }
}
