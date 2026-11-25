import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/models.dart';
import '../design/widgets/async_view.dart';
import '../design/tokens.dart';
import '../design/widgets/chip.dart';
import '../design/widgets/lists.dart';
import '../design/widgets/rows.dart';
import '../design/widgets/state_view.dart';
import '../design/widgets/top_bar.dart';
import 'login_page.dart';
import 'openers.dart';
import 'routes.dart';
import '../design/pressable.dart';

/// 排行（需登录）。字段对齐 uni `pages/rank/rank.vue`：
/// 顶栏副行 = 小说排行 / 漫画排行；行内 = 名次 + 书名 + 状态 + 作者 + 分类·授权标签。
class RankPage extends StatefulWidget {
  const RankPage({super.key});

  @override
  State<RankPage> createState() => _RankPageState();
}

class _RankPageState extends State<RankPage> {
  bool _novel = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          YmTopBar(
            leading: const YmBackButton(),
            title: '排行',
            subtitle: _novel ? '小说排行' : '漫画排行',
          ),
          Expanded(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 14, YmLayout.pagePad, 10),
                  child: Row(
                    children: [
                      YmChip(
                        style: YmChipStyle.pill,
                        pressKind: YmPressKind.solid,
                        label: '小说',
                        active: _novel,
                        onTap: () => setState(() => _novel = true),
                      ),
                      const SizedBox(width: 8),
                      YmChip(
                        style: YmChipStyle.pill,
                        pressKind: YmPressKind.solid,
                        label: '漫画',
                        active: !_novel,
                        onTap: () => setState(() => _novel = false),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: YmAsync<YmRankFeed>(
                    key: ValueKey(_novel ? 'novel' : 'manga'),
                    load: () => fetchRank(kind: _novel ? 'novel' : 'manga'),
                    errorTitle: '排行加载失败',
                    onLogin: () => ymPush(context, const LoginPage()),
                    builder: (context, feed, reload) {
                      if (feed.items.isEmpty) {
                        return ListView(
                          children: const [YmStateView(title: '暂无排行')],
                        );
                      }
                      return ListView(
                        padding: const EdgeInsets.only(bottom: 8),
                        children: [
                          YmCardList(
                            children: [
                              for (final item in feed.items)
                                YmRankRow(
                                  item: item,
                                  onTap: () => openWork(
                                    context,
                                    id: item.id,
                                    title: item.title,
                                    manga: !_novel,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
