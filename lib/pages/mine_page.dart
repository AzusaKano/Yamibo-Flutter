import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/cache/ym_cache_store.dart';
import '../data/library.dart';
import '../data/session.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/widgets/button.dart';
import '../design/widgets/lists.dart';
import '../design/widgets/offline_controls.dart';
import '../design/widgets/rows.dart';
import '../design/widgets/sheet.dart';
import '../design/widgets/top_bar.dart';
import 'about_page.dart';
import 'fav_page.dart';
import 'history_page.dart';
import 'login_page.dart';
import 'offline_page.dart';
import 'routes.dart';
import '../design/pressable.dart';

/// 「我的」。版式对齐 uni `pages/mine/mine.vue` 的 mine 模式：
/// 账号 summary 卡 + 入口列表（我的书架 / 历史记录 / 清除阅读记录 / 关于）+ 主题块。
/// 「开发指标」与「控件样板」收到关于页（2026-11-09 拍板）。
class MinePage extends StatefulWidget {
  const MinePage({super.key});

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  static const _themes = <(YmThemeId, String, List<Color>)>[
    (YmThemeId.yamibo, '百合会', [Color(0xFF551300), Color(0xFFF25614)]),
    (YmThemeId.rail, '轨交速查', [Color(0xFF3970E5), Color(0xFF3970E5)]),
  ];

  @override
  void initState() {
    super.initState();
    // 登录 / 退出 / 后台校验都会改账号视图，本页跟着重建
    YmSession.account.addListener(_onAccount);
  }

  @override
  void dispose() {
    YmSession.account.removeListener(_onAccount);
    super.dispose();
  }

  void _onAccount() {
    if (mounted) setState(() {});
  }

  Future<void> _clearHistory(BuildContext context) async {
    final ok = await showYmConfirm(
      context,
      title: '清除阅读记录',
      content: '会清空全部历史与阅读进度，书架收藏会保留。',
      confirmText: '清除',
      danger: true,
    );
    if (ok == true) YmLibrary.instance.clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    final scope = YmScope.of(context);
    final c = scope.colors;
    final acc = YmSession.account.value;
    final loggedIn = acc.loggedIn;
    final nameLine = acc.name.isNotEmpty ? acc.name : (loggedIn ? '已登录' : '未登录');

    return AnimatedBuilder(
      // 书架 / 历史数来自 YmLibrary，离线内容的「N 本 · X MB」来自 YmCache
      animation: Listenable.merge(<Listenable>[
        YmLibrary.instance,
        YmCache.instance,
      ]),
      builder: (context, _) {
        final lib = YmLibrary.instance;
        final offline = ymOfflineWorks();
        return Column(
          children: [
            YmTopBar(title: '我的', subtitle: nameLine),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 16),
                children: [
                  Container(
                    margin: const EdgeInsets.fromLTRB(YmLayout.pagePad, 14, YmLayout.pagePad, 0),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: c.card,
                      borderRadius: BorderRadius.circular(YmRadius.box),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          loggedIn ? (acc.name.isNotEmpty ? acc.name : '已登录') : '登录百合会',
                          style: TextStyle(
                            fontSize: YmFont.strong17,
                            fontWeight: FontWeight.w800,
                            height: 1.35,
                            color: c.text,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          loggedIn
                              ? (acc.uid.isNotEmpty ? 'UID ${acc.uid}' : '已登录')
                              : '登录后可使用搜索与排行',
                          style: TextStyle(
                            fontSize: YmFont.small12,
                            height: 1.6,
                            color: c.text2,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: YmButton(
                                label: loggedIn ? '账号' : '登录',
                                kind: loggedIn ? YmButtonKind.tint : YmButtonKind.primary,
                                expanded: true,
                                onTap: () => ymPush(context, const LoginPage()),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  YmCardList(
                    children: [
                      YmActionRow(
                        title: '我的书架',
                        value: '${lib.shelf.length} 本',
                        onTap: () => rootTab.value = 2,
                      ),
                      YmActionRow(
                        title: '我的收藏',
                        value: '站内收藏的小说与漫画',
                        onTap: () => ymPush(context, const FavPage()),
                      ),
                      YmActionRow(
                        title: '历史记录',
                        value: '${lib.history.length} 条',
                        onTap: () => ymPush(context, const HistoryPage()),
                      ),
                      // 离线内容（缓存第一期 1F）：空的一份不占版面，只留标题行
                      YmActionRow(
                        title: '离线内容',
                        value: offline.isEmpty
                            ? null
                            : '${offline.length} 本 · ${ymBytes(offline.fold<int>(0, (sum, w) => sum + w.bytes))}',
                        onTap: () => ymPush(context, const OfflinePage()),
                      ),
                      YmActionRow(
                        title: '清除阅读记录',
                        value: '清空历史与进度，书架收藏保留',
                        onTap: () => _clearHistory(context),
                      ),
                      YmActionRow(
                        title: '关于',
                        onTap: () => ymPush(context, const AboutPage()),
                      ),
                    ],
                  ),
                  // 主题块：两枚样本色点 + 名称，选中态品牌实心
                  Container(
                    margin: const EdgeInsets.fromLTRB(YmLayout.pagePad, 16, YmLayout.pagePad, 0),
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                    decoration: BoxDecoration(
                      color: c.card,
                      borderRadius: BorderRadius.circular(YmRadius.box),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '主题',
                          style: TextStyle(
                            fontSize: YmFont.body14,
                            fontWeight: FontWeight.w700,
                            color: c.text,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            for (final t in _themes) ...[
                              Expanded(
                                child: _ThemeOption(
                                  label: t.$2,
                                  dots: t.$3,
                                  active: scope.themeId == t.$1,
                                  onTap: () => scope.onThemeChanged(t.$1),
                                ),
                              ),
                              if (t != _themes.last) const SizedBox(width: 10),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.label,
    required this.dots,
    required this.active,
    required this.onTap,
  });

  final String label;
  final List<Color> dots;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final fg = active ? Colors.white : c.text2;

    return YmPressable(
      kind: YmPressKind.row,
      baseColor: active ? c.brand : c.fill,
      radius: BorderRadius.circular(YmRadius.ctrl),
      onTap: onTap,
      child: SizedBox(
        height: 46,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final d in dots) ...[
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: d,
                  shape: BoxShape.circle,
                  boxShadow: active
                      ? const [BoxShadow(color: Color(0xEBFFFFFF), spreadRadius: 1.5)]
                      : null,
                ),
              ),
              const SizedBox(width: 3),
            ],
            const SizedBox(width: 4),
            Text(
              label,
              // 主题选项是整块可点的控件，标签按控件标签取 w700
              //（选中态只靠 brand 底 + 白字，不改字重）。
              // ⚠ 裸 TextStyle 不写 fontWeight 会在 400，不会继承 preset。
              style: TextStyle(
                fontSize: YmFont.body14,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
