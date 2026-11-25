import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/app_state.dart';
import '../data/cache/ym_cache_store.dart' show YmCache;
import '../data/cn.dart';
import '../data/forum/forum_track.dart';
import '../data/http.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/write.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/widgets/async_view.dart';
import '../design/widgets/chip.dart';
import '../design/widgets/forum/forum_track_row.dart';
import '../design/widgets/hscroll_fade.dart';
import '../design/widgets/lists.dart';
import '../design/widgets/rows.dart' show YmActionRow;
import '../design/widgets/selection.dart';
import '../design/widgets/sheet.dart';
import '../design/widgets/state_view.dart';
import '../design/widgets/toast.dart';
import '../design/widgets/top_bar.dart';
import 'forum/forum_thread_page.dart' show ForumThreadPage;
import 'login_page.dart';
import 'openers.dart';
import 'routes.dart';
import '../design/pressable.dart';

/// 书架（底栏第二项）。三枚胶囊 tab：
///
/// - **本地** = `ym_library.json` 的书架（手动 / 详情页「加入书架」写入，只在本机）；
/// - **在线** = 站内书签（`/my/bookmark`）。在线**不支持多选**：站点只认单条翻转删除；
/// - **追帖** = `ym_forum_track.json` 的论坛追帖（本地能力，与站内收藏互不替代）。
///
/// ⚠ 三套数据**并列展示、不合并、不双写** —— 哪套在哪个 tab 里，用户看得见，
/// 所以不需要冲突规则。
///
/// 本地版式对齐 uni `pages/mine` 的 shelf 模式：顶栏副行 = N 本；提示条；行内 =
/// 封面 + 书名 + 读到哪 + 进度 + 类型/作者。在线版式见 [YmBookmarkRow]。
class ShelfPage extends StatefulWidget {
  const ShelfPage({super.key});

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends State<ShelfPage> {
  static const int _tabLocal = 0;
  static const int _tabOnline = 1;
  static const int _tabTracked = 2;

  int _tab = _tabLocal;

  /// 本地 tab 的选择模式（T22）：右上是「选择 / 取消」，长按进选择，底部条批量移出。
  /// 在线书签不支持多选，切到在线 tab 时退出。
  bool _selecting = false;
  final Set<String> _sel = <String>{};

  /// 在线 tab 的顶栏副行（条数要等异步拿到，本地是同步的）。
  final ValueNotifier<String> _onlineSub = ValueNotifier<String>('正在读取…');

  /// 打开作品 / 取消书签时铺一层遮罩：这两件事都得先回源取一次章节页
  /// （书签条目只有章节 id，没有作品 id），不是瞬时动作。
  bool _busy = false;

  /* ------------------------------ 搜索 / 筛选 ------------------------------ */

  /// 搜索态：顶栏**原地**变输入行（`YmTopBar` 没有搜索槽，也不给它加参数——
  /// 全工程十几个页面都在用它）。搜索态与选择模式互斥。
  bool _searching = false;
  final TextEditingController _kw = TextEditingController();
  final FocusNode _kwFocus = FocusNode();

  /// 本地 tab 的类型筛选（任务 2）：`''` = 不筛。单选可取消 —— 点同一枚即取消。
  String _kind = '';

  /// 追帖 tab 的板块筛选（任务 3）：`''` = 不筛；值是 [ymBoardName] 的结果。
  String _board = '';

  /// 书架在底栏里的位置（`app.dart` 的 IndexedStack 顺序）。离开这一枚就退出
  /// 搜索态：本页常驻在 IndexedStack 里，返回键拦截不能在别的 tab 上生效。
  static const int _rootTabShelf = 2;

  @override
  void initState() {
    super.initState();
    rootTab.addListener(_onRootTabChanged);
  }

  @override
  void dispose() {
    rootTab.removeListener(_onRootTabChanged);
    _kw.dispose();
    _kwFocus.dispose();
    _onlineSub.dispose();
    super.dispose();
  }

  void _onRootTabChanged() {
    if (rootTab.value != _rootTabShelf) _exitSearch();
  }

  void _enterSearch() {
    _exitSelect();
    setState(() => _searching = true);
  }

  void _exitSearch() {
    if (!_searching && _kw.text.isEmpty) return;
    _kwFocus.unfocus();
    _kw.clear();
    setState(() => _searching = false);
  }

  /// 类型筛选：选中某一枚即只看该类；再点同一枚取消（没有「全部」项）。
  void _pickKind(String kind) {
    // 筛选换了可见集合，选择模式必须退出（否则会留下看不见的已选项）。
    _exitSelect();
    setState(() => _kind = _kind == kind ? '' : kind);
  }

  /// 板块筛选：规则同 [_pickKind]。
  void _pickBoard(String board) {
    setState(() => _board = _board == board ? '' : board);
  }

  /* ------------------------------ 本地 tab ----------------------------- */

  void _exitSelect() {
    if (!_selecting && _sel.isEmpty) return;
    setState(() {
      _selecting = false;
      _sel.clear();
    });
  }

  void _toggleSelect(String id) {
    setState(() {
      _selecting = true;
      if (!_sel.remove(id)) _sel.add(id);
      if (_sel.isEmpty) _selecting = false;
    });
  }

  void _enterSelect(String id) {
    // 搜索态下长按不进选择：两种模式不允许同时存在。
    if (_searching) return;
    setState(() {
      _selecting = true;
      _sel.add(id);
    });
  }

  void _selectAll(List<YmShelfEntry> items) {
    setState(() {
      if (_sel.length == items.length) {
        _sel.clear();
        _selecting = false;
      } else {
        _sel
          ..clear()
          ..addAll(items.map((e) => e.id));
      }
    });
  }

  Future<void> _removeSelectedLocal() async {
    final ids = _sel.toList();
    if (ids.isEmpty) return;
    final ok = await showYmConfirm(
      context,
      title: '移出书架',
      content: '把选中的 ${ids.length} 本移出书架？阅读记录与进度会保留。',
      confirmText: '移出',
      danger: true,
    );
    if (ok != true || !mounted) return;
    YmLibrary.instance.removeFromShelf(ids);
    _exitSelect();
  }

  Widget _localBody(BuildContext context, YmLibrary lib, List<YmShelfEntry> items) {
    if (items.isEmpty) {
      // 书架本来就没书 → 还是原来的空态；有书但被筛没了 → 一句空结果。
      if (lib.shelfEntries.isEmpty) {
        return ListView(
          children: [
            YmStateView(
              title: '书架是空的',
              desc: '在作品详情点「加入书架」，就会收在这里。',
              actionLabel: '去首页找书',
              onAction: () => rootTab.value = 0,
            ),
          ],
        );
      }
      return ListView(
        children: const [YmStateView(title: '没有匹配的内容')],
      );
    }
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    return ListView(
      padding: EdgeInsets.only(
        bottom: _selecting ? YmSelectMetrics.pageBottomInset + safeBottom : 10,
      ),
      children: [
        YmCardList(
          children: [
            for (final item in items)
              Builder(
                builder: (context) {
                  final h = lib.historyOf(item.id);
                  return YmBookRow(
                    title: item.title,
                    cover: lib.coverOf(item.id, item.kind, cover: item.cover),
                    // 本机封面（离线保存过才有）：断网 / 签名过期也能出图
                    coverLocal: YmCache.instance.peekCoverFile(
                      item.kind,
                      item.id,
                    ),
                    line: h == null || h.chapterTitle.isEmpty
                        ? '还没开始读'
                        : '读到 ${h.chapterTitle}',
                    progress: h?.percent,
                    footTag: item.kind == 'manga' ? '漫画' : '小说',
                    footText: item.author,
                    selectionMode: _selecting,
                    selected: _sel.contains(item.id),
                    onTap: () {
                      if (_selecting) {
                        _toggleSelect(item.id);
                        return;
                      }
                      // 口径：一律先进详情页，由用户自己决定读不读
                      openWork(
                        context,
                        id: item.id,
                        title: item.title,
                        manga: item.kind == 'manga',
                      );
                    },
                    onLongPress: () {
                      if (_selecting) {
                        _toggleSelect(item.id);
                      } else {
                        _enterSelect(item.id);
                      }
                    },
                  );
                },
              ),
          ],
        ),
      ],
    );
  }

  /* ------------------------------ 追帖 tab ----------------------------- */

  /// 点追帖行：有进度就回到保存楼层（resumeToast），没有就从第 1 页。
  void _openTracked(ForumTrackRecord rec) {
    if (rec.lastPage > 0 && rec.lastPid.isNotEmpty) {
      ymPush(
        context,
        ForumThreadPage(
          tid: rec.tid,
          initialPage: rec.lastPage,
          anchorPid: rec.lastPid,
          resumeToast: true,
        ),
      );
      return;
    }
    ymPush(context, ForumThreadPage(tid: rec.tid));
  }

  /// 长按追帖行：两行动作弹层。「从头看」从第 1 页进；「移出追帖」只清 tracked，
  /// 记录留在历史。
  void _trackActions(ForumTrackRecord rec) {
    showYmSheet<void>(
      context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const YmSheetHeader(title: '追帖'),
              YmCardList(
                margin: EdgeInsets.zero,
                children: [
                  YmActionRow(
                    title: '从头看',
                    onTap: () {
                      Navigator.of(ctx).pop();
                      // startFresh：不读已存进度、从第 1 页开始，首载把历史重置到
                      // 第 1 页第一楼——否则默认恢复会把人送回原来那一楼。
                      ymPush(
                        context,
                        ForumThreadPage(tid: rec.tid, startFresh: true),
                      );
                    },
                  ),
                  YmActionRow(
                    title: '移出追帖',
                    onTap: () {
                      Navigator.of(ctx).pop();
                      ForumTrackStore.instance.untrack(rec.tid);
                      showYmToast(context, '已移出追帖');
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _trackedBody(
    BuildContext context,
    ForumTrackStore store,
    List<ForumTrackRecord> items,
  ) {
    if (items.isEmpty) {
      if (store.trackedRecords.isEmpty) {
        return ListView(
          children: const [
            YmStateView(
              title: '还没有追帖',
              desc: '在帖子页点「追帖」，就会出现在这里',
            ),
          ],
        );
      }
      return ListView(
        children: const [YmStateView(title: '没有匹配的内容')],
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 10),
      children: [
        YmCardList(
          children: [
            for (final rec in items)
              YmForumTrackRow(
                record: rec,
                onTap: () => _openTracked(rec),
                onLongPress: () => _trackActions(rec),
              ),
          ],
        ),
      ],
    );
  }

  /* ------------------------------ 在线 tab ----------------------------- */

  /// 书签条目只有章节 id ⇒ 作品 id 要回源取一次。
  ///
  /// 用 `fetchChapter` / `fetchMangaChapter` 而不是裸取页面：这两个的返回值本来就带
  /// `workId` **和** `csrfToken`，而且正文 / 页图会进缓存 —— 用户接着点「阅读」时
  /// 正好命中，不会白发这次请求。
  Future<({String workId, String csrf})> _resolve(YmBookmarkItem it) async {
    if (it.manga) {
      final r = await fetchMangaChapter(it.chaptId, page: it.page);
      return (workId: r.workId, csrf: r.csrfToken);
    }
    final c = await fetchChapter(it.chaptId);
    return (workId: c.workId, csrf: c.csrfToken);
  }

  String _reason(Object e) =>
      e is YmHttpError ? e.message : '请稍后再试。';

  Future<void> _openBookmark(YmBookmarkItem it) async {
    setState(() => _busy = true);
    try {
      final r = await _resolve(it);
      if (!mounted) return;
      if (r.workId.isEmpty) {
        await showYmAlert(
          context,
          title: '打不开这条书签',
          content: '没能找到它对应的作品，这一章可能已经不存在了。',
        );
        return;
      }
      if (!mounted) return;
      openWork(
        context,
        id: r.workId,
        title: it.workTitle,
        manga: it.manga,
        // 书签钉的位置就是「接着读这里」⇒ 详情页的续读点与目录高亮用它，
        // 而不是本机历史（两者可能差很远）
        resumeChaptId: it.chaptId,
        resumePage: it.page,
      );
    } catch (e) {
      if (!mounted) return;
      await showYmAlert(context, title: '打不开这条书签', content: _reason(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeBookmark(YmBookmarkItem it, VoidCallback reload) async {
    final ok = await showYmConfirm(
      context,
      title: '取消书签',
      content: '确定取消《${it.workTitle}》「${it.chaptTitle}」的书签吗？',
      confirmText: '取消书签',
      cancelText: '保留',
      danger: true,
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final r = await _resolve(it);
      if (!mounted) return;
      if (r.workId.isEmpty) {
        await showYmAlert(
          context,
          title: '没能取消书签',
          content: '没能找到它对应的作品，这一章可能已经不存在了。',
        );
        return;
      }
      final result = await YmWrite.setBookmark(
        workId: r.workId,
        chaptId: it.chaptId,
        manga: it.manga,
        on: false,
        // 列表里这一条就是「当前钉着的那一章」，所以能删；
        // 换成别的章发请求只会把它覆盖过去，不是取消（见 YmWrite.setBookmark）。
        pinnedChaptId: it.chaptId,
        page: it.page,
        csrfToken: r.csrf,
      );
      if (!mounted) return;
      if (!result.ok) {
        await showYmAlert(context, title: '没能取消书签', content: '请稍后再试。');
        return;
      }
      reload();
    } catch (e) {
      if (!mounted) return;
      await showYmAlert(context, title: '没能取消书签', content: _reason(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _onlineBody(BuildContext context) {
    return YmAsync<YmBookmarkFeed>(
      load: () => fetchBookmarks(),
      errorTitle: '书签加载失败',
      loginDesc: '书签需要登录百合会账号',
      onLogin: () => ymPush(context, const LoginPage()),
      builder: (context, feed, reload) {
        final shown = ymFilterBookmarks(feed.items, keyword: _kw.text);

        // 顶栏副行：没关键词 = 总条数（现状口径）；有关键词 = 找到 N 条。
        // 值没变就不写，避免每帧都通知。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final kw = _kw.text.trim();
          final text = kw.isEmpty
              ? '${feed.total > 0 ? feed.total : feed.items.length} 条'
              : '找到 ${ymFilterBookmarks(feed.items, keyword: kw).length} 条';
          if (_onlineSub.value != text) _onlineSub.value = text;
        });

        if (feed.items.isEmpty) {
          return ListView(
            children: const [
              YmStateView(
                title: '还没有书签',
                desc: '在章节页加书签，就会出现在这里。',
              ),
            ],
          );
        }

        if (shown.isEmpty) {
          return ListView(
            children: const [YmStateView(title: '没有匹配的内容')],
          );
        }

        return ListView(
          padding: const EdgeInsets.only(bottom: 10),
          children: [
            YmCardList(
              children: [
                for (final it in shown)
                  YmBookmarkRow(
                    title: it.chaptTitle,
                    subtitle: [it.workTitle, it.author]
                        .where((e) => e.isNotEmpty)
                        .join(' · '),
                    tag: it.manga ? '漫画' : '小说',
                    onTap: () => _openBookmark(it),
                    onLongPress: () => _removeBookmark(it, reload),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  /* -------------------------------- 骨架 -------------------------------- */

  Widget _tabs() {
    // 用**标准胶囊**（`.chip` 44/13），不要 `compact` —— 书架这两枚是页内 tab，
    // 与列表页排序、搜索大类的胶囊是同一套语言，压成 34/12 就不像同一种控件了
    // （2026-10-25 实机反馈）。
    Widget chip(String label, int index) => YmChip(
          style: YmChipStyle.pill,
          pressKind: YmPressKind.solid,
          label: label,
          active: _tab == index,
          onTap: () {
            if (_tab == index) return;
            _exitSelect();
            setState(() => _tab = index);
          },
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 14, YmLayout.pagePad, 14),
      child: Row(
        children: [
          chip('本地', _tabLocal),
          const SizedBox(width: 8),
          chip('在线（书签）', _tabOnline),
          const SizedBox(width: 8),
          chip('追帖', _tabTracked),
        ],
      ),
    );
  }

  /// 细边胶囊筛选行（任务 2 / 3）：横滑 + 右缘渐隐，与首页类型胶囊同一套；
  /// 纵向 14 节奏（tab 行自己已留 14，这里只补到列表的 14）。
  Widget _filterRow(List<Widget> chips) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 0, YmLayout.pagePad, 14),
      // ⚠ `YmHScrollFade` 内部是 Stack，不给紧约束时会按内容宽度收缩，
      // 而 Column 默认把子项居中 ⇒ 胶囊会跑到屏幕中间（2026-11-25 真机反馈）。
      // 撑满一行后由内部 SingleChildScrollView 顶左排。
      child: SizedBox(
        width: double.infinity,
        child: YmHScrollFade(spacing: 8, children: chips),
      ),
    );
  }

  Widget _lineChip(String label, bool active, VoidCallback onTap) => YmChip(
        style: YmChipStyle.line,
        pressKind: YmPressKind.solid,
        label: label,
        active: active,
        onTap: onTap,
      );

  /// 搜索态顶栏：与 `YmTopBar` 同壳（同底色 / 描边 / 投影 / 高度 / 内距），
  /// 标题让位给输入行，副行留着报「找到 N」。不改 `TopBar` 本体。
  Widget _searchTopBar(YmColors c, String subtitle) {
    final statusBar = MediaQuery.paddingOf(context).top;
    return Container(
      constraints: BoxConstraints(minHeight: statusBar + YmLayout.topBarMin),
      padding: EdgeInsets.only(
        top: statusBar,
        left: YmLayout.pagePad,
        right: YmLayout.pagePad,
      ),
      decoration: BoxDecoration(
        color: c.topbarBg,
        border: Border(bottom: BorderSide(color: c.topbarBd)),
        boxShadow: YmShadows.topbar,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _searchField(c)),
              const SizedBox(width: 8),
              YmTopBarAction(label: '取消', onTap: _exitSearch),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: c.small12,
          ),
        ],
      ),
    );
  }

  /// 输入框抄搜索页（44 高、`inputOnBg`、`YmRadius.ctrl`、`body14` 字），
  /// 右侧多一枚 × 清空。清空从不清搜索态，只清关键词。
  Widget _searchField(YmColors c) {
    return Container(
      padding: const EdgeInsets.only(left: 12, right: 4),
      constraints: const BoxConstraints(minHeight: 44),
      decoration: BoxDecoration(
        color: c.inputOnBg,
        borderRadius: BorderRadius.circular(YmRadius.ctrl),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _kw,
              focusNode: _kwFocus,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _kwFocus.unfocus(),
              style: TextStyle(fontSize: YmFont.body14, color: c.text),
              cursorColor: c.brandInk,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '搜索',
                hintStyle: TextStyle(fontSize: YmFont.body14, color: c.text2),
              ),
            ),
          ),
          if (_kw.text.isNotEmpty)
            SizedBox(
              // 点按下限 44（YmLayout.hitMin）；输入框本身 44 高，正好撑满。
              width: YmLayout.hitMin,
              height: YmLayout.hitMin,
              child: YmPressable(
                kind: YmPressKind.dim,
                radius: BorderRadius.circular(YmRadius.pill),
                semanticLabel: '清空搜索',
                onTap: () {
                  _kw.clear();
                  setState(() {});
                  _kwFocus.requestFocus();
                },
                child: Center(
                  child: Icon(Icons.close, size: 16, color: c.text3),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 常态顶栏右侧：放大镜在左、选择在右（最右上角始终是「选择」）。
  /// 没有「选择」的时刻（在线 / 追帖 tab、本地空书架）放大镜自然贴到最右。
  /// 选择模式下只剩「取消」。
  Widget? _topTrailing(YmColors c, bool hasLocalItems) {
    if (_selecting && _tab == _tabLocal) {
      return YmTopBarAction(label: '取消', onTap: _exitSelect);
    }
    final showSelect = _tab == _tabLocal && hasLocalItems;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        YmCircleButton(
          icon: Icon(Icons.search, size: 22, color: c.textStrong),
          semanticLabel: '搜索书架',
          onTap: _enterSearch,
        ),
        if (showSelect) ...[
          const SizedBox(width: 4),
          YmTopBarAction(
            label: '选择',
            onTap: () => setState(() => _selecting = true),
          ),
        ],
      ],
    );
  }

  Widget _busyMask(YmColors c) => ColoredBox(
        color: c.mask,
        child: Center(
          child: Text(
            '正在处理…',
            style: TextStyle(fontSize: YmFont.sub13, color: c.text2),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return ValueListenableBuilder<int>(
      valueListenable: rootTab,
      // 搜索态只拦本页所在的那一枚底栏项：离开书架时上面的监听器已退出搜索态，
      // 否则常驻 IndexedStack 的本页会把别的 tab 的返回键一起吞掉。
      builder: (context, _, child) => PopScope(
        canPop: !_searching,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _exitSearch();
        },
        child: child!,
      ),
      child: Stack(
        // ⚠ 必须 expand：默认的 loose 会让里面的 Column 拿不到确定高度，
        // 展开成 ListView 时才报 "Vertical viewport was given unbounded height"。
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            // 三个 tab 的可见集合都随各自 store 刷新；在线 tab 的副行靠 _onlineSub。
            animation: Listenable.merge([YmLibrary.instance, ForumTrackStore.instance]),
            builder: (context, _) {
              final lib = YmLibrary.instance;
              final rawShelf = lib.shelfEntries;
              final track = ForumTrackStore.instance;
              final rawTracked = track.trackedRecords;
              final keyword = _kw.text;

              // 筛选行出现条件（任务 2 / 3）。不满足时旧筛选不生效：否则数据变了
              // 以后列表会被一个看不见的筛选清空，又没有入口取消。
              final showKindRow = ymShelfHasBothKinds(rawShelf);
              final kind = showKindRow ? _kind : '';
              final boards = ymTrackedBoards(rawTracked);
              final showBoardRow = boards.length >= 2;
              final board = showBoardRow && boards.contains(_board) ? _board : '';

              final localItems = ymFilterShelf(rawShelf, keyword: keyword, kind: kind);
              final trackedItems =
                  ymFilterTracked(rawTracked, keyword: keyword, board: board);

              // 副行：没筛选也没关键词 = 现状口径；任一条件生效 = 「找到 N」。
              final localHit = kind.isNotEmpty || keyword.trim().isNotEmpty;
              final trackedHit = board.isNotEmpty || keyword.trim().isNotEmpty;
              String subtitleOf(String onlineSub) {
                if (_tab == _tabLocal) {
                  return localHit
                      ? '找到 ${localItems.length} 本'
                      : '${rawShelf.length} 本';
                }
                if (_tab == _tabTracked) {
                  return trackedHit
                      ? '找到 ${trackedItems.length} 条'
                      : '${rawTracked.length} 条';
                }
                return onlineSub;
              }

              return Stack(
                fit: StackFit.expand,
                children: [
                  Column(
                    children: [
                      ValueListenableBuilder<String>(
                        valueListenable: _onlineSub,
                        builder: (context, onlineSub, _) => _searching
                            ? _searchTopBar(c, subtitleOf(onlineSub))
                            : YmTopBar(
                                title: '书架',
                                subtitle: subtitleOf(onlineSub),
                                trailing: _topTrailing(c, rawShelf.isNotEmpty),
                              ),
                      ),
                      _tabs(),
                      if (_tab == _tabLocal && showKindRow)
                        _filterRow([
                          _lineChip('小说', kind == 'novel', () => _pickKind('novel')),
                          _lineChip('漫画', kind == 'manga', () => _pickKind('manga')),
                        ]),
                      if (_tab == _tabTracked && showBoardRow)
                        _filterRow([
                          for (final b in boards)
                            _lineChip(b, board == b, () => _pickBoard(b)),
                        ]),
                      Expanded(
                        child: _tab == _tabLocal
                            ? _localBody(context, lib, localItems)
                            : (_tab == _tabTracked
                                ? _trackedBody(context, track, trackedItems)
                                : _onlineBody(context)),
                      ),
                    ],
                  ),
                  if (_selecting && _tab == _tabLocal)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: YmSelectBar(
                        countText: '已选 ${_sel.length} 项',
                        leading: YmSelectAction(
                          label: _sel.length == localItems.length ? '取消全选' : '全选',
                          kind: YmSelectActionKind.selectAll,
                          onTap: () => _selectAll(localItems),
                        ),
                        trailing: YmSelectAction(
                          label: '移出',
                          kind: YmSelectActionKind.delete,
                          enabled: _sel.isNotEmpty,
                          onTap: _removeSelectedLocal,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          if (_busy) Positioned.fill(child: _busyMask(c)),
        ],
      ),
    );
  }
}

/* --------------------------- 过滤（纯函数，可单测） --------------------------- */

/// 搜索关键词归一：去首尾空白 → 转简体 → 小写。
///
/// ⚠ `toSimplified` 对**已经是简体**的输入并非逐字不变：`data/cn.dart` 的覆盖表
/// 会把 `瞭→了`、`藉→借`（「瞭望塔→了望塔」「慰藉→慰借」，2026-11-25 实测）。
/// 所以匹配走两道：原文小写先比一次，简繁归一后再比一次 —— 简体书永远不会
/// 因为归一被漏掉，繁体关键词也仍能命中简体记录。
String ymShelfKey(String s) => toSimplified(s.trim()).toLowerCase();

/// 关键词是否命中任一字段：不区分大小写、整串子串、简繁互搜；不做空格分词。
/// 空关键词恒命中。
bool ymShelfHit(String keyword, Iterable<String> fields) {
  final raw = keyword.trim().toLowerCase();
  if (raw.isEmpty) return true;
  final norm = ymShelfKey(keyword);
  for (final f in fields) {
    final text = f.toLowerCase();
    if (text.contains(raw) || (norm.isNotEmpty && ymShelfKey(f).contains(norm))) {
      return true;
    }
  }
  return false;
}

/// 本地书架 = 书名 + 作者；[kind] 非空时先按类型筛，再按关键词筛（AND）。
List<YmShelfEntry> ymFilterShelf(
  List<YmShelfEntry> items, {
  String keyword = '',
  String kind = '',
}) =>
    [
      for (final e in items)
        if ((kind.isEmpty || e.kind == kind) &&
            ymShelfHit(keyword, [e.title, e.author]))
          e,
    ];

/// 在线书签 = 章节名 + 作品名 + 作者。
List<YmBookmarkItem> ymFilterBookmarks(
  List<YmBookmarkItem> items, {
  String keyword = '',
}) =>
    [
      for (final e in items)
        if (ymShelfHit(keyword, [e.chaptTitle, e.workTitle, e.author])) e,
    ];

/// 追帖 = 标题 + 板块 + 作者；[board] 非空时先按板块筛，再按关键词筛（AND）。
List<ForumTrackRecord> ymFilterTracked(
  List<ForumTrackRecord> items, {
  String keyword = '',
  String board = '',
}) =>
    [
      for (final e in items)
        if ((board.isEmpty || ymBoardName(e) == board) &&
            ymShelfHit(keyword, [e.title, e.boardName, e.author]))
          e,
    ];

/// `boardName` 为空串的记录归到「未知板块」这一项（筛选行与筛选都用它）。
const String ymUnknownBoard = '未知板块';

String ymBoardName(ForumTrackRecord rec) =>
    rec.boardName.isEmpty ? ymUnknownBoard : rec.boardName;

/// 追帖里出现过的板块名（去重）：按条数降序、同数按名字。
List<String> ymTrackedBoards(List<ForumTrackRecord> items) {
  final counts = <String, int>{};
  for (final e in items) {
    final name = ymBoardName(e);
    counts[name] = (counts[name] ?? 0) + 1;
  }
  final names = counts.keys.toList()
    ..sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      if (byCount != 0) return byCount;
      return a.compareTo(b);
    });
  return names;
}

/// 本地类型筛选行的出现条件：小说 / 漫画**两种都存在**才占这一行。
bool ymShelfHasBothKinds(List<YmShelfEntry> items) =>
    items.any((e) => e.kind == 'novel') && items.any((e) => e.kind == 'manga');
