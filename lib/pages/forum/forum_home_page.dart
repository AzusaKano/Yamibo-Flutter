import 'package:flutter/material.dart';

import '../../data/app_state.dart';
import '../../data/forum/forum_api.dart';
import '../../data/forum/forum_auth.dart';
import '../../data/forum/forum_models.dart';
import '../../design/pressable.dart';
import '../../design/theme.dart';
import '../../design/tokens.dart';
import '../../design/widgets/async_view.dart';
import '../../design/widgets/chip.dart';
import '../../design/widgets/hscroll_fade.dart';
import '../../design/widgets/forum/forum_board_row.dart';
import '../../design/widgets/forum/forum_image.dart' show YmForumImage, forumAvatarUrl;
import '../../design/widgets/forum/forum_thread_row.dart';
import '../../design/widgets/lists.dart';
import '../../design/widgets/nav_icon.dart';
import '../../design/widgets/state_view.dart';
import '../../design/widgets/top_bar.dart';
import '../../design/ym_route.dart' show ymRoute;
import '../routes.dart';
import 'forum_board_page.dart';
import 'forum_login_page.dart';
import 'forum_mine_page.dart';
import 'forum_recent.dart';
import 'forum_web.dart';
import 'forum_thread_page.dart' show openForumThread;

/// A 论坛首页：分区卡（进板块）+ 热门讨论（看当下最热的帖子）。
/// 热门讨论取動漫區列表（fid=5）的前几条 —— 一期不追「最新主题」流（落地方案口径）。
///
/// **首次切到论坛 tab 才开始取数**：IndexedStack 会把五个 tab 全部建出来，
/// 启动就连 bbs 既浪费请求，也会在测试（没 stub 论坛通道）里发真实网络。
class ForumHomePage extends StatefulWidget {
  const ForumHomePage({super.key});

  @override
  State<ForumHomePage> createState() => _ForumHomePageState();
}

class _ForumHomePageState extends State<ForumHomePage> {
  bool _activated = false;

  @override
  void initState() {
    super.initState();
    if (rootTab.value == 3) _activated = true;
    rootTab.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    rootTab.removeListener(_onTabChanged);
    super.dispose();
  }

  void _onTabChanged() {
    if (rootTab.value == 3 && !_activated) {
      setState(() => _activated = true);
    }
  }

  Future<(ForumHome, List<ForumThreadSummary>)> _load() async {
    final home = await fetchForumHome();
    // 热点推荐：站方 PC 版 DIY 模块的全站热点（0.1.23 用户拍板，替代原
    // 「取動漫區列表前几条」的权宜口径——那不是全站热门，只是動漫區）。
    // 取失败 / 站方清空都不拖垮首页（分区卡照常出，热区安静隐藏）
    List<ForumThreadSummary> hot = const <ForumThreadSummary>[];
    try {
      hot = await fetchForumHot();
    } catch (_) {
      // 热点推荐拿不到就整个不显示，不让首页报错
    }
    return (home, hot);
  }

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Scaffold(
      body: Column(
        children: [
          YmTopBar(
            title: '论坛',
            // 顶栏动作圆 42（拆件表 A-01：草稿 34 头像圆升档）；放大镜 = 搜索入口
            //（E2 独立页），进了是 F 屏。两枚圆钮 8 间距（元素间 8 口径）。
            trailing: ValueListenableBuilder<ForumAccount>(
              valueListenable: ForumSession.account,
              builder: (context, acc, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  YmCircleButton(
                    semanticLabel: '搜索论坛',
                    // 混合形态退场、改为网页壳直跳（2026-11-15 拍板）：WAF 对原生取
                    // 结果持续硬拦（见 forum_web / 探针留档），搜索整体交给网页——
                    // 与打卡同款口径。游客先过原生登录门，避免在网页壳里登录后
                    // Cookie 落在 WebView 而不同步进论坛罐。
                    onTap: () async {
                      if (!ForumSession.loggedIn) {
                        await Navigator.of(context).push(ymRoute(const ForumLoginPage(), snapshot: false));
                        if (!ForumSession.loggedIn) return;
                      }
                      if (!context.mounted) return;
                      openForumWeb(context, path: '/search.php?mod=forum&mobile=2', title: '论坛搜索');
                    },
                    icon: YmNavIcon(name: 'search', color: c.textStrong, size: 19),
                  ),
                  const SizedBox(width: 8),
                  YmCircleButton(
                    semanticLabel: '我的论坛',
                    onTap: () => ymPush(context, const ForumMinePage()),
                    icon: acc.loggedIn && acc.uid.isNotEmpty
                        ? YmForumImage(
                            url: forumAvatarUrl(acc.uid),
                            width: 30,
                            height: 30,
                            fallbackText: acc.name.isEmpty ? '论' : acc.name.characters.first,
                            borderRadius: BorderRadius.circular(15),
                          )
                        : Text(
                            '我',
                            style: TextStyle(
                              fontSize: YmFont.sub13,
                              fontWeight: FontWeight.w700,
                              color: c.text2,
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _activated
                ? ValueListenableBuilder<ForumAccount>(
                    valueListenable: ForumSession.account,
                    builder: (context, acc, _) => YmAsync<(ForumHome, List<ForumThreadSummary>)>(
                        // 登录态是论坛首页的取数前提：部分板块登录后才可见。
                        // YmAsync 自带的「登录变化重取」盯的是阅读侧账号，
                        // 论坛罐是独立一份——用 key 在登录 / 退出时重建并重取。
                        key: ValueKey<bool>(acc.loggedIn),
                        load: _load,
                        errorTitle: '论坛加载失败',
                        // WAF 被拦：单按钮「去验证」收束——打开网页壳，WebView
                        // 拿到新通行证自动关页，返回后自动重试
                        //（借证与自动关页原理见 forum_web.openForumWafVerifyPage）
                        onWaf: (context, reload) async {
                          await openForumWafVerifyPage(context);
                          if (context.mounted) reload();
                        },
                        builder: (context, data, reload) {
                          final (home, hot) = data;
                          return _Body(home: home, hot: hot);
                        },
                      ),
                  )
                : const SizedBox.expand(),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.home, required this.hot});

  final ForumHome home;
  final List<ForumThreadSummary> hot;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 8),
      children: [
        // 游客提示条（拆件表 A-02：YmTip 口径）；登录后整条收掉
        ValueListenableBuilder<ForumAccount>(
          valueListenable: ForumSession.account,
          builder: (context, acc, _) => acc.loggedIn
              ? const SizedBox.shrink()
              : const YmTip('论坛未登录：仅可查看公开板块。'),
        ),
        if (forumRecentBoards.value.isNotEmpty)
          ValueListenableBuilder<List<ForumBoardRef>>(
            valueListenable: forumRecentBoards,
            builder: (context, recent, _) => _RecentBar(recent: recent),
          ),
        for (final cat in home.cats) ...[
          _CatCard(cat: cat),
          const SizedBox(height: 14),
        ],
        if (hot.isNotEmpty) ...[
          // 站方口径的名字（PC 版 DIY 模块就叫「热点推荐」）；条目跨板块，
          // 没有单一出处板块，不挂「動漫區 ›」跳转
          const YmSectionHeader(title: '热点推荐'),
          const SizedBox(height: 9),
          YmCardList(
            children: [
              for (final t in hot)
                YmForumThreadRow(
                  thread: t,
                  onTap: () => openForumThread(context, t),
                ),
            ],
          ),
        ],
        if (home.cats.isEmpty && hot.isEmpty)
          const YmStateView(
            title: '论坛没能打开',
            desc: '站点没有返回任何板块',
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// 「最近访问」胶囊条（草稿 A 屏）。一期内存态，重启清空。
/// 复用 YmChip（compact 34，拆件表 A-03），横滚带渐隐用现成 YmHScrollFade。
class _RecentBar extends StatelessWidget {
  const _RecentBar({required this.recent});

  final List<ForumBoardRef> recent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: YmHScrollFade(
        children: [
          for (final b in recent)
            YmChip(
              style: YmChipStyle.pill,
              pressKind: YmPressKind.solid,
              label: b.name,
              compact: true,
              onTap: () {
                rememberForumBoardVisit(b);
                ymPush(context, ForumBoardPage(fid: b.fid, name: b.name));
              },
            ),
        ],
      ),
    );
  }
}

/// 分区卡：卡面 + 组头（3px 品牌竖条 + 组名 + N 个板块）+ 板块行。
class _CatCard extends StatelessWidget {
  const _CatCard({required this.cat});

  final ForumCat cat;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(YmRadius.card),
        boxShadow: YmShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 9),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 12,
                  decoration: BoxDecoration(
                    color: c.brand,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  cat.name,
                  style: TextStyle(
                    fontSize: YmFont.sub13,
                    fontWeight: FontWeight.w800,
                    color: c.text2,
                  ),
                ),
                const Spacer(),
                Text(
                  '${cat.forums.length} 个板块',
                  style: TextStyle(
                    fontSize: YmFont.micro11,
                    fontWeight: FontWeight.w700,
                    color: c.text3,
                  ),
                ),
              ],
            ),
          ),
          for (var i = 0; i < cat.forums.length; i++) ...[
            if (i > 0) Container(height: 1, color: c.borderWeak),
            YmForumBoardRow(
              board: cat.forums[i],
              onTap: () {
                rememberForumBoardVisit(cat.forums[i]);
                ymPush(context, ForumBoardPage(
                  fid: cat.forums[i].fid,
                  name: cat.forums[i].name,
                ));
              },
            ),
          ],
        ],
      ),
    );
  }
}
