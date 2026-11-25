import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/cache/ym_cache_store.dart' show YmCache;
import '../data/http.dart';
import '../data/models.dart';
import '../data/write.dart';
import '../design/widgets/async_view.dart';
import '../design/widgets/lists.dart';
import '../design/widgets/sheet.dart';
import '../design/widgets/state_view.dart';
import '../design/widgets/top_bar.dart';
import 'login_page.dart';
import 'openers.dart';
import 'routes.dart';

/// 「我的」→「我的收藏」= 站内收藏（`/my/fav`）。
///
/// 与书架是两个东西（规划文档 §4）：书架是**本机**的（本地条目 + 站内书签），
/// 收藏是**站内**的、只读那条线拉下来展示；两者不合并、不双写。
///
/// 版式**照本地书架行**（[YmBookRow]）：封面 + 书名 + 最近更新章节 + 类型/作者。
/// 站点收藏条目里没有阅读进度（那在本机历史里），所以这一行不画进度条。
/// 条目本来就有 workId 与封面 ⇒ 点开直接进详情页，不用像书签那样先换 id。
class FavPage extends StatefulWidget {
  const FavPage({super.key});

  @override
  State<FavPage> createState() => _FavPageState();
}

class _FavPageState extends State<FavPage> {
  final List<YmFavItem> _items = <YmFavItem>[];

  /// 已经加载到第几页（0 = 还没拿到第一页）。
  int _page = 0;
  int _total = 0;

  /// 取消收藏要 CSRF；第一页的 HTML 里就有 meta，顺手存下，不再单独回源。
  String _csrf = '';

  bool _hasMore = false;
  bool _loadingMore = false;

  /// 顶栏副行。条数要等异步拿到，所以走 [ValueNotifier] 而不是 setState
  /// （取数与重建都发生在 [YmAsync] 内部，本页拿不到那个时机）。
  final ValueNotifier<String> _subtitle = ValueNotifier<String>('正在读取…');

  /// 第一页（含整表重取）。由 [YmAsync] 调用，成功后它的 FutureBuilder 会重建，
  /// 所以这里只赋值、不 setState。
  Future<YmFavFeed> _loadFirst() async {
    final feed = await fetchFavs();
    _items
      ..clear()
      ..addAll(feed.items);
    _page = feed.page;
    _total = feed.total;
    _csrf = feed.csrfToken;
    _hasMore = feed.hasMore;
    return feed;
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final feed = await fetchFavs(page: _page + 1);
      if (!mounted) return;
      setState(() {
        _items.addAll(feed.items);
        _page = feed.page;
        // 站点总数字段只在页脚，翻到底时可能变（别处取消了一条），以最新的为准
        if (feed.total > 0) _total = feed.total;
        _hasMore = feed.hasMore;
        if (feed.items.isEmpty) _hasMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      await showYmAlert(context, title: '没能加载更多', content: _reason(e));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 取消收藏。**列表里这一条本来就是「已收藏」**，所以走 `setFav(on: false)`；
  /// 接口是翻转语义，`currently` 传 true 才不会被翻反（见 [YmWrite.setFav]）。
  Future<void> _cancel(YmFavItem it, VoidCallback reload) async {
    final ok = await showYmConfirm(
      context,
      title: '从收藏里移除',
      content: '确定把《${it.title}》从收藏里移除吗？书签与阅读记录不受影响。',
      confirmText: '移除',
      cancelText: '保留',
      danger: true,
    );
    if (ok != true || !mounted) return;

    try {
      final result = await YmWrite.setFav(
        workId: it.workId,
        manga: it.manga,
        on: false,
        currently: true,
        csrfToken: _csrf,
      );
      if (!mounted) return;
      if (!result.ok) {
        await showYmAlert(context, title: '没能取消收藏', content: '请稍后再试。');
        return;
      }
      reload();
    } catch (e) {
      if (!mounted) return;
      await showYmAlert(context, title: '没能取消收藏', content: _reason(e));
    }
  }

  String _reason(Object e) => e is YmHttpError ? e.message : '请稍后再试。';

  void _syncSubtitle() {
    final text = _total > 0 ? '共 $_total 篇' : (_page > 0 ? '还没有收藏' : '正在读取…');
    if (_subtitle.value != text) _subtitle.value = text;
  }

  Widget _body(BuildContext context) {
    return YmAsync<YmFavFeed>(
      load: _loadFirst,
      errorTitle: '收藏加载失败',
      loginDesc: '收藏需要登录百合会账号',
      onLogin: () => ymPush(context, const LoginPage()),
      builder: (context, feed, reload) {
        // 条数在 Future 里才拿到，等这一帧画完再写副行（在 build 里写会触发本帧二次通知）
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _syncSubtitle();
        });

        if (_items.isEmpty) {
          return ListView(
            children: [
              YmStateView(
                title: '还没有收藏',
                desc: '在作品详情点「收藏」，就会出现在这里。',
              ),
            ],
          );
        }

        return ListView(
          // 顶栏线到第一条之间留 14（对齐首页 / 列表页）
          padding: const EdgeInsets.only(top: 14, bottom: 8),
          children: [
            const YmTip('点击打开作品，长按取消收藏。'),
            YmCardList(
              children: [
                for (final it in _items)
                  YmBookRow(
                    title: it.title,
                    cover: it.cover,
                    // 本机封面（离线保存过才有）
                    coverLocal: YmCache.instance.peekCoverFile(
                      it.manga ? 'manga' : 'novel',
                      it.workId,
                    ),
                    line: it.latestChapterTitle.isEmpty
                        ? (it.status.isEmpty ? null : it.status)
                        : '最近更新 ${it.latestChapterTitle}',
                    footTag: it.manga ? '漫画' : '小说',
                    footText: it.author,
                    onTap: () => openWork(
                      context,
                      id: it.workId,
                      title: it.title,
                      manga: it.manga,
                    ),
                    onLongPress: () => _cancel(it, reload),
                  ),
              ],
            ),
            YmLoadMore(
              loading: _loadingMore,
              hasMore: _hasMore,
              doneText: '已全部加载 · $_total 篇',
              onTap: _loadMore,
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _subtitle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          ValueListenableBuilder<String>(
            valueListenable: _subtitle,
            builder: (context, subtitle, _) =>
                YmTopBar(leading: const YmBackButton(), title: '我的收藏', subtitle: subtitle),
          ),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }
}
