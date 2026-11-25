import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/cache/ym_cache_store.dart' show YmCache;
import '../data/models.dart';
import '../design/pressable.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/widgets/async_view.dart';
import '../design/widgets/chip.dart';
import '../design/widgets/cover.dart';
import '../design/widgets/hscroll_fade.dart';
import '../design/widgets/lists.dart';
import '../design/widgets/state_view.dart';
import '../design/widgets/top_bar.dart';
import 'list_page.dart';
import 'login_page.dart';
import 'manga_list_page.dart';
import 'openers.dart';
import 'rank_page.dart';
import 'rcmds_page.dart';
import 'routes.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _novel = true;

  static const _novelCats = <(String, String)>[
    ('1', '原创小说'),
    ('2', '二次元同人'),
    ('3', '三次元同人'),
    ('all', '全部作品'),
    ('finish', '完结'),
    ('signed', '签约'),
  ];

  static const _mangaTypes = ['翻页漫画', '条漫', '四格', '绘本', '杂志', '合志'];

  void _openNovelList(String label) {
    final q = _novelCats.firstWhere((e) => e.$2 == label, orElse: () => ('all', label)).$1;
    ymPush(context, ListPage(title: label, q: q));
  }

  void _openMangaList(String title, [String bucket = '']) {
    ymPush(context, MangaListPage(title: title, initialBucket: bucket));
  }

  void _openLogin() => ymPush(context, const LoginPage());

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;

    return Column(
      children: [
        YmTopBar(
          title: '首页',
          trailing: YmPressable(
            radius: BorderRadius.circular(YmRadius.chip),
            // 文字动作：资产包 T22-04 / T24-06 走 dim .6。
            kind: YmPressKind.dim,
            dimOpacity: 0.6,
            onTap: () => ymPush(context, const RankPage()),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
              // 光学对齐：13px 文字与 24/1.12 的标题同框时，墨迹中心比标题高 1dp
              // （Noto Sans SC 实测：排行 59.5 / 首页 60.5，盒子中心都是 59.5），下移 1。
              child: Transform.translate(
                offset: const Offset(0, 1),
                child: Text('排行 ›', style: c.sub13Strong.copyWith(color: c.text2)),
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 8),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 14, YmLayout.pagePad, 14),
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
              if (_novel)
                _NovelCatGrid(cats: _novelCats, onTap: _openNovelList)
              else
                _MangaCatGrid(
                  onTap: (label) => _openMangaList(
                    label,
                    switch (label) {
                      '原创' => '4',
                      '同人' => '6',
                      '完结' => 'finish',
                      '签约' => 'signed',
                      _ => '',
                    },
                  ),
                ),
              if (!_novel)
                Padding(
                  padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 0, YmLayout.pagePad, 14),
                  // 类型胶囊在大字体档会超出一屏，右缘给渐隐（页面底 ⇒ 实色端取 --bg）
                  child: YmHScrollFade(
                    children: [
                      for (final t in _mangaTypes)
                        YmChip(
                          style: YmChipStyle.pill,
                          pressKind: YmPressKind.solid,label: t, onTap: () => _openMangaList(t, t)),
                    ],
                  ),
                ),
              if (_novel)
                YmAsync<YmHomeFeed>(
                  embedded: true,
                  load: fetchNovelHome,
                  onLogin: _openLogin,
                  loading: const _HomeSkeleton(picks: 4),
                  builder: (ctx, feed, reload) => _NovelHomeSections(
                    feed: feed,
                    onMoreRcmds: () => ymPush(context, const RcmdsPage(manga: false)),
                    onMoreLatest: () => _openNovelList('全部作品'),
                  ),
                )
              else
                YmAsync<YmMangaHomeFeed>(
                  embedded: true,
                  load: fetchMangaHome,
                  onLogin: _openLogin,
                  loading: const _HomeSkeleton(picks: 3),
                  builder: (ctx, feed, reload) => _MangaHomeSections(
                    feed: feed,
                    onMoreRcmds: () => ymPush(context, const RcmdsPage(manga: true)),
                    onMoreLatest: () => _openMangaList('全部作品'),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NovelHomeSections extends StatelessWidget {
  const _NovelHomeSections({
    required this.feed,
    required this.onMoreRcmds,
    required this.onMoreLatest,
  });

  final YmHomeFeed feed;
  final VoidCallback onMoreRcmds;
  final VoidCallback onMoreLatest;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final picks = feed.picks.take(4).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        YmSectionHeader(title: '编辑推荐', action: '更多 ›', onAction: onMoreRcmds),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: YmLayout.pagePad),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < picks.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(
                  child: _PickCard(
                    pick: picks[i],
                    onTap: () => openWork(context, id: picks[i].id, title: picks[i].title),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        YmSectionHeader(title: '最近更新', action: '更多 ›', onAction: onMoreLatest),
        const SizedBox(height: 6),
        // 表头在卡外（uni `.lt-head`），底边与卡的顶边重合，读作同一块列表。
        Padding(
          padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 2, YmLayout.pagePad, 8),
          child: Container(
            padding: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.border)),
            ),
            child: Row(
              children: [
                Expanded(child: Text('作品', style: _headStyle(c))),
                const SizedBox(width: 8),
                SizedBox(width: 56, child: Text('章节', style: _headStyle(c))),
                const SizedBox(width: 8),
                SizedBox(width: 76, child: Text('作者', style: _headStyle(c))),
              ],
            ),
          ),
        ),
        YmCardList(
          children: [
            for (final row in feed.latest.take(12)) _LatestRow(item: row),
          ],
        ),
      ],
    );
  }
}

class _MangaHomeSections extends StatelessWidget {
  const _MangaHomeSections({
    required this.feed,
    required this.onMoreRcmds,
    required this.onMoreLatest,
  });

  final YmMangaHomeFeed feed;
  final VoidCallback onMoreRcmds;
  final VoidCallback onMoreLatest;

  @override
  Widget build(BuildContext context) {
    final picks = feed.picks.take(3).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        YmSectionHeader(title: '编辑推荐', action: '更多 ›', onAction: onMoreRcmds),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: YmLayout.pagePad),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < picks.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(
                  child: _PickCard(
                    pick: picks[i],
                    onTap: () =>
                        openWork(context, id: picks[i].id, title: picks[i].title, manga: true),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        YmSectionHeader(title: '最近更新', action: '更多 ›', onAction: onMoreLatest),
        const SizedBox(height: 6),
        YmCardList(
          children: [
            for (final item in feed.latest.take(10))
              YmBookRow(
                title: item.title,
                cover: item.cover,
                // 这一栏是漫画「最近更新」：离线保存过的作品用本机封面
                coverLocal: YmCache.instance.peekCoverFile('manga', item.id),
                footTag: item.cat,
                onTap: () => openWork(context, id: item.id, title: item.title, manga: true),
              ),
          ],
        ),
      ],
    );
  }
}

class _NovelCatGrid extends StatelessWidget {
  const _NovelCatGrid({required this.cats, required this.onTap});

  final List<(String, String)> cats;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    Widget cell(String label) => Expanded(
          child: YmPressable(
            kind: YmPressKind.row,
            baseColor: c.card,
            radius: BorderRadius.zero,
            onTap: () => onTap(label),
            child: SizedBox(
              height: 44,
              child: Center(
                child: Text(
                  label,
                  // 分类网格的格子＝可点入口（控件标签），取 body14 档 w700；
                  // 原 body14Regular + w600 是「400 档上盖一个非声明中间值」。
                  style: c.body14,
                ),
              ),
            ),
          ),
        );

    return Container(
      margin: const EdgeInsets.fromLTRB(YmLayout.pagePad, 0, YmLayout.pagePad, 16),
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: c.border,
        borderRadius: BorderRadius.circular(YmRadius.box),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(YmRadius.box - 1),
        child: Column(
          children: [
            Row(children: [cell(cats[0].$2), const SizedBox(width: 1), cell(cats[1].$2), const SizedBox(width: 1), cell(cats[2].$2)]),
            Container(height: 1, color: c.border),
            Row(children: [cell(cats[3].$2), const SizedBox(width: 1), cell(cats[4].$2), const SizedBox(width: 1), cell(cats[5].$2)]),
          ],
        ),
      ),
    );
  }
}

class _MangaCatGrid extends StatelessWidget {
  const _MangaCatGrid({required this.onTap});

  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    Widget cell(String label, int flex) => Expanded(
          flex: flex,
          child: YmPressable(
            kind: YmPressKind.row,
            baseColor: c.card,
            radius: BorderRadius.zero,
            onTap: () => onTap(label),
            child: SizedBox(
              height: 44,
              child: Center(
                child: Text(
                  label,
                  // 分类网格的格子＝可点入口（控件标签），取 body14 档 w700；
                  // 原 body14Regular + w600 是「400 档上盖一个非声明中间值」。
                  style: c.body14,
                ),
              ),
            ),
          ),
        );

    return Container(
      margin: const EdgeInsets.fromLTRB(YmLayout.pagePad, 0, YmLayout.pagePad, 16),
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        color: c.border,
        borderRadius: BorderRadius.circular(YmRadius.box),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(YmRadius.box - 1),
        child: Column(
          children: [
            Row(children: [cell('原创', 3), const SizedBox(width: 1), cell('同人', 3)]),
            Container(height: 1, color: c.border),
            Row(children: [
              cell('全部作品', 2),
              const SizedBox(width: 1),
              cell('完结', 2),
              const SizedBox(width: 1),
              cell('签约', 2),
            ]),
          ],
        ),
      ),
    );
  }
}

class _PickCard extends StatelessWidget {
  const _PickCard({required this.pick, required this.onTap});

  final YmPick pick;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return YmPressable(
      kind: YmPressKind.neutral,
      radius: BorderRadius.circular(YmRadius.inner),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 3 / 4,
            child: YmCover(title: pick.title, url: pick.cover),
          ),
          const SizedBox(height: 6),
          Text(
            pick.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: YmFont.small12,
              fontWeight: FontWeight.w700,
              height: 1.35,
              color: c.text,
            ),
          ),
          if (pick.line.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              pick.line,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: c.micro11.copyWith(color: c.text2, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}

class _LatestRow extends StatelessWidget {
  const _LatestRow({required this.item});

  final YmLatest item;

  /// 行内「第一行」的高度（标题 14 / 行高 1.4）。
  /// 右侧章节与作者是单行文字，要跟标题第一行的中线对齐：
  /// 单行标题时读作居中，多行标题时停在第一行（与左侧标签同一套逻辑）。
  static const double _firstLineH = YmFont.body14 * 1.4;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    // 列内文字：定高 = 第一行，竖向居中 ⇒ 中线正好落在标题第一行的中线上。
    Widget cell(String text, {required double width, required Color color}) {
      return SizedBox(
        width: width,
        height: _firstLineH,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: YmFont.small12,
              height: 1.4,
              color: color,
            ),
          ),
        ),
      );
    }

    return YmPressable(
      kind: YmPressKind.row,
      radius: BorderRadius.zero,
      onTap: () => openWork(context, id: item.id, title: item.title),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: YmLayout.pagePad, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (item.cat.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: YmTag(item.cat),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      // 行标题＝w700（与 rows / work_row 的书名同档）。
                      // ⚠ 裸 TextStyle 不写 fontWeight 会落到 400，不会继承 preset。
                      style: TextStyle(
                        fontSize: YmFont.body14,
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                        color: c.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            cell(item.chapter, width: 56, color: c.text),
            const SizedBox(width: 8),
            cell(item.author, width: 76, color: c.text2),
          ],
        ),
      ),
    );
  }
}

/// 分区标题（12 档）：资产包 SlateSettingsGroupTitle 声明 12·650 → snap w700（settings.dart）。
TextStyle _headStyle(YmColors c) => TextStyle(
      fontSize: YmFont.small12,
      fontWeight: FontWeight.w700,
      color: c.text2,
    );

/// 首页载入态：与 uni 一致——分区标题「正在加载…」+ 编辑推荐骨架 + 最近更新骨架。
class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton({required this.picks});

  final int picks;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 4, YmLayout.pagePad, 10),
          child: Text(
            '正在加载…',
            style: TextStyle(
              fontSize: YmFont.sub13,
              fontWeight: FontWeight.w700,
              color: c.text,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: YmLayout.pagePad),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < picks; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      AspectRatio(
                        aspectRatio: 3 / 4,
                        child: YmSkeleton(height: double.infinity, radius: 16),
                      ),
                      SizedBox(height: 6),
                      YmSkeleton(height: 13),
                      SizedBox(height: 4),
                      FractionallySizedBox(
                        widthFactor: 0.55,
                        child: YmSkeleton(height: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 4, YmLayout.pagePad, 10),
          child: Text(
            '最近更新',
            style: TextStyle(
              fontSize: YmFont.sub13,
              fontWeight: FontWeight.w700,
              color: c.text,
            ),
          ),
        ),
        const YmSkeletonRows(count: 5),
      ],
    );
  }
}
