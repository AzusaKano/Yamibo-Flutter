import 'dart:async';

import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/cache/offline_detail.dart';
import '../data/cache/ym_cache_store.dart';
import '../data/http.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/resume.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/widgets/async_view.dart';
import '../design/widgets/cover.dart';
import '../design/widgets/detail_actions.dart';
import '../design/widgets/glyph.dart';
import '../design/widgets/lists.dart';
import '../design/widgets/menu.dart'
    show
        YmMenuIconTrigger,
        YmMenuItemData,
        YmMenuOrigin,
        YmMenuPlacement,
        YmMenuSection,
        showYmMenu;
import '../design/widgets/offline_controls.dart';
import '../design/widgets/toast.dart';
import '../design/widgets/top_bar.dart';
import 'login_page.dart';
import 'novel_reader_page.dart';
import 'routes.dart';
import 'web_page.dart';

/// 小说详情。字段与层级对齐 uni `pages/detail/detail.vue`：
/// 顶栏副行 = 分类 · 状态 · 授权；卡内标签只放作品标签；
/// 目录内联展开（分卷先铺 4 章 / 扁平先铺 30 章），行内带序号与「读到这里」。
class NovelDetailPage extends StatefulWidget {
  const NovelDetailPage({
    super.key,
    required this.id,
    this.title = '',
    this.fromShelf = false,
    this.resumeChaptId = '',
  });

  final String id;
  final String title;
  final bool fromShelf;

  /// 从在线书签进来时带的章节 id —— 续读点取它而不是本地历史（见 [_fromBookmark]）。
  final String resumeChaptId;

  @override
  State<NovelDetailPage> createState() => _NovelDetailPageState();
}

class _NovelDetailPageState extends State<NovelDetailPage> {
  final ValueNotifier<String> _sub = ValueNotifier<String>('正在读取…');
  bool _desc = false;
  bool _showAll = false;
  final Map<String, bool> _expanded = <String, bool>{};

  /// 是否还在用「书签带来的那个续读点」。
  ///
  /// 从在线书签进来时置真：书签钉的位置才是用户心里的「接着读这里」，
  /// 和本机历史可能差很远（本机读到第 10 章、书签钉在第 30 章）。
  ///
  /// 这是个**临时**覆盖：用户真点了「继续阅读」读下去，本机会写下新的阅读记录，
  /// 那一刻本地就已经是被刷新过的那一份了 ⇒ 覆盖失效、交还给本地。
  /// 判断「有没有被写过」用进页面时的快照比对，而不是按章节先后排序
  /// （章节号不一定可比：分卷、倒序、书签指向已删章节都会让比较失真）。
  bool _fromBookmark = false;
  YmHistoryEntry? _localSnap;

  /// 上一次刷新**失败**了（自动进页面 / 菜单手动，都算）：副行挂「离线」，
  /// 让用户知道眼前这份是本机的、可能旧了。刷新成功后置回 false。
  bool _refreshFailed = false;

  /// 内容区句柄：右上角菜单里的「刷新」通过它触发（重新拉一次在线版本）。
  final GlobalKey<YmLocalFirstAsyncState<YmNovelDetail>> _contentKey =
      GlobalKey<YmLocalFirstAsyncState<YmNovelDetail>>();

  /// 右上角菜单的触发器句柄（T24 菜单位置由它算，不做自动翻转）。
  final GlobalKey _menuKey = GlobalKey();

  /// 菜单是否打开（触发器要跟着换成「按下去」的底色）。
  bool _menuOpen = false;

  /// 取在线版本。
  ///
  /// `force` = 真的要一次网络（自动进页面 / 手动刷新都走这条，见
  /// `ym_local_first_boot_force`）：命中五分钟缓存时 `fetchDetail` 根本不发请求，
  /// 断网也会「刷新成功」、弹一句「数据更新成功」——那只是内存里的旧数据，等于骗人。
  /// 没有本机副本时的首屏加载不传 `force`，照旧吃缓存。
  Future<YmNovelDetail> _loadRemote({bool force = false}) {
    if (force) evictCache('detail:${widget.id}');
    return fetchDetail(widget.id);
  }

  @override
  void initState() {
    super.initState();
    _fromBookmark = widget.resumeChaptId.isNotEmpty;
    _localSnap = YmLibrary.instance.historyOf(widget.id);
    // 阅读历史变化要反映到本页：退出阅读器回来时，
    // 「继续阅读」指向的章节与目录里的「读到这里」必须是刚存下的那一份。
    YmLibrary.instance.addListener(_onLibrary);
  }

  @override
  void dispose() {
    YmLibrary.instance.removeListener(_onLibrary);
    _sub.dispose();
    super.dispose();
  }

  void _onLibrary() {
    if (!mounted) return;
    if (_fromBookmark) {
      final now = YmLibrary.instance.historyOf(widget.id);
      if (!_sameProgress(now, _localSnap)) {
        // 本机写下了新进度（用户读了）⇒ 立刻交还给本地
        _fromBookmark = false;
        _localSnap = now;
      }
    }
    setState(() {});
  }

  static bool _sameProgress(YmHistoryEntry? a, YmHistoryEntry? b) {
    if (a == null || b == null) return identical(a, b);
    return a.chapterId == b.chapterId &&
        a.page == b.page &&
        a.lastReadAt == b.lastReadAt &&
        a.seq == b.seq;
  }

  /// 右上角菜单：刷新 / 在网页打开（2026-11-24 用户口径：把地球钮换成菜单，
  /// 让「刷新」变成可发现的按钮 —— 断网进详情后的第一反应就是想找它）。
  ///
  /// ⚠ 用资产包 **T24 菜单**（`design/widgets/menu.dart`，与帖子页同一个件），
  /// 不是底部弹层；行上**不配副行说明**（T24 的说明行是给「选项」用的，
  /// 两个短动作只要一行字）。位置由触发器 RenderBox 算出，菜单不做自动翻转。
  Future<void> _openMenu() async {
    if (_menuOpen || !mounted) return;
    setState(() => _menuOpen = true);
    final box = _menuKey.currentContext?.findRenderObject();
    final screen = MediaQuery.sizeOf(context);
    double? top;
    double? right;
    if (box is RenderBox && box.attached) {
      final pos = box.localToGlobal(Offset.zero);
      // 贴在触发器正下方、右缘对齐；origin=topRight 从右上角展开。
      top = pos.dy + box.size.height + 4;
      right = screen.width - pos.dx - box.size.width;
    }
    await showYmMenu(
      context,
      placement: YmMenuPlacement(
        top: top ?? screen.height * 0.12,
        right: right ?? 14,
        origin: YmMenuOrigin.topRight,
      ),
      sections: [
        YmMenuSection(
          items: [
            YmMenuItemData(label: '刷新', onTap: () => unawaited(_refreshNow())),
            YmMenuItemData(
              label: '在网页打开',
              onTap: () => ymPush(
                context,
                WebPage(
                  url: '$kYmBase/novel/${widget.id}',
                  title: widget.title.isEmpty ? '网页' : widget.title,
                ),
              ),
            ),
          ],
        ),
      ],
      semanticLabel: '作品操作',
    );
    if (mounted) setState(() => _menuOpen = false);
  }

  /// 手动刷新：成功 / 失败都由内容区统一提示（「数据更新成功」/「数据更新失败」），
  /// 这里不另弹一句，免得同一次刷新弹两句。
  Future<void> _refreshNow() async {
    await _contentKey.currentState?.refresh(force: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          ValueListenableBuilder<String>(
            valueListenable: _sub,
            builder: (context, sub, _) => YmTopBar(
              leading: const YmBackButton(),
              title: widget.title.isEmpty ? '作品' : widget.title,
              subtitle: sub,
              // 更多菜单：T24 菜单里放「刷新」与「在网页打开」（原来这里只有地球钮）
              trailing: YmMenuIconTrigger(
                key: _menuKey,
                isOpen: _menuOpen,
                onTap: _openMenu,
                semanticLabel: '更多操作',
              ),
            ),
          ),
          Expanded(
            child: YmLocalFirstAsync<YmNovelDetail>(
              key: _contentKey,
              // 先画本机那份（有就秒开），再后台换成在线版本
              loadLocal: () => ymOfflineNovelDetail(
                widget.id,
                title: widget.title,
              ),
              loadRemote: _loadRemote,
              errorTitle: '作品加载失败',
              // 刷新成功 / 失败对称提示：有本机副本的书
              // 每次联网进入都会弹一次「数据更新成功」，这是用户要的反馈
              onRefreshDone: () {
                if (!mounted) return;
                // 换到在线版本了，副行的「离线」要摘掉（失败一次后不摘会一直挂着）
                if (_refreshFailed) setState(() => _refreshFailed = false);
                showYmToast(context, '数据更新成功');
              },
              onLogin: () => ymPush(context, const LoginPage()),
              onRefreshFailed: () {
                if (!mounted) return;
                setState(() => _refreshFailed = true);
                showYmToast(context, '数据更新失败');
              },
              builder: (context, detail, fresh) {
                final meta = [
                  detail.cat,
                  detail.status,
                  detail.license,
                ].where((e) => e.isNotEmpty).join(' · ');
                // 刷新失败才挂「离线」：只是还在刷新的那半秒不挂，
                // 免得在线用户以为出了毛病
                final line = _refreshFailed
                    ? (meta.isEmpty ? '离线' : '离线 · $meta')
                    : meta;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  if (_sub.value != line) _sub.value = line;
                });
                return _Body(
                  detail: detail,
                  // 数据还没换成在线版本 ⇒ 服务端写操作先不放行（令牌可能是旧的）
                  locked: !fresh,
                  // 只在「从书签进来、且本机还没写下新进度」时生效
                  resumeChaptId: _fromBookmark ? widget.resumeChaptId : '',
                  desc: _desc,
                  showAll: _showAll,
                  expanded: _expanded,
                  onToggleOrder: () => setState(() {
                    _desc = !_desc;
                    _showAll = false;
                  }),
                  onShowAll: () => setState(() => _showAll = true),
                  onToggleVolume: (key) => setState(
                    () => _expanded[key] = !(_expanded[key] ?? false),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.detail,
    required this.resumeChaptId,
    required this.desc,
    required this.showAll,
    required this.expanded,
    required this.onToggleOrder,
    required this.onShowAll,
    required this.onToggleVolume,
    this.locked = false,
  });

  final YmNovelDetail detail;

  /// 数据还不是在线版本（本机副本 / 刷新失败）：收藏这类服务端写操作先不放行。
  final bool locked;

  /// 续读点用的章节 id（从在线书签进来时才有值）；空串 = 用本地历史。
  final String resumeChaptId;

  final bool desc;
  final bool showAll;
  final Map<String, bool> expanded;
  final VoidCallback onToggleOrder;
  final VoidCallback onShowAll;
  final ValueChanged<String> onToggleVolume;

  static const _volPreview = 4;
  static const _flatLimit = 30;

  void _read(BuildContext context, [YmChapterRef? chapter]) {
    final ch =
        chapter ?? (detail.chapters.isEmpty ? null : detail.chapters.first);
    if (ch == null) return;
    // ⚠ 不拦「没下载过的章」（2026-11-24 用户定案）：照常进阅读器，
    // 本机有就秒开，没有就让阅读器自己报「这一章没有离线内容」——
    // 详情页不替用户做判断，也不给假反馈。
    ymPush(context, NovelReaderPage(detail: detail, initial: ch));
  }

  List<(String, List<(int, YmChapterRef)>)> _groups() {
    final indexed = <(int, YmChapterRef)>[
      for (var i = 0; i < detail.chapters.length; i++)
        (i + 1, detail.chapters[i]),
    ];
    final ordered = desc ? indexed.reversed.toList() : indexed;

    final out = <(String, List<(int, YmChapterRef)>)>[];
    for (final item in ordered) {
      final name = item.$2.volume;
      if (out.isEmpty || out.last.$1 != name) {
        out.add((name, [item]));
      } else {
        out.last.$2.add(item);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    // 书签带来的续读点优先，否则用本地历史（规则见 data/resume.dart）
    final point = resolveResume(
      chapters: detail.chapters,
      hintChaptId: resumeChaptId,
      history: YmLibrary.instance.historyOf(detail.id),
    );
    // 「读到这里」跟着续读点走：从书签进来时它就该落在书签那一章
    final lastChapterId = point.chapter?.id ?? '';
    final primaryLabel = point.has ? '继续阅读' : '开始阅读';

    return ListView(
      padding: const EdgeInsets.only(bottom: 10),
      children: [
        // summary 卡：封面 / 标题 / 作者 · 发布日期 / 标签 / 操作 / 三项指标
        Container(
          margin: const EdgeInsets.fromLTRB(
            YmLayout.pagePad,
            14,
            YmLayout.pagePad,
            12,
          ),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(YmRadius.box),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  YmCover(
                    title: detail.title,
                    url: detail.cover,
                    // 本机封面优先（下载这本时存的）：断网 / 签名过期也能出图
                    local: YmCache.instance.peekCoverFile('novel', detail.id),
                    width: 76,
                    height: 102,
                    radius: YmRadius.ctrl,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          detail.title,
                          style: TextStyle(
                            fontSize: YmFont.strong17,
                            fontWeight: FontWeight.w800,
                            height: 1.35,
                            color: c.text,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          detail.publishedAt.isEmpty
                              ? (detail.author.isEmpty ? '佚名' : detail.author)
                              : '${detail.author.isEmpty ? '佚名' : detail.author} · 发布 ${detail.publishedAt}',
                          style: TextStyle(
                            fontSize: YmFont.small12,
                            height: 1.6,
                            color: c.text2,
                          ),
                        ),
                        if (detail.tags.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [for (final t in detail.tags) YmTag(t)],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              YmDetailActions(
                workId: detail.id,
                manga: false,
                title: detail.title,
                author: detail.author,
                cover: detail.cover,
                primaryLabel: primaryLabel,
                onRead: () => _read(context, point.chapter),
                csrfToken: detail.csrfToken,
                favored: detail.favored,
                hits: detail.hits,
                favs: detail.favs,
                score: detail.score,
                onLogin: () => ymPush(context, const LoginPage()),
                locked: locked,
              ),
            ],
          ),
        ),
        const YmSectionHeader(
          title: '简介',
          padding: EdgeInsets.fromLTRB(
            YmLayout.pagePad,
            0,
            YmLayout.pagePad,
            10,
          ),
        ),
        Container(
          margin: const EdgeInsets.fromLTRB(
            YmLayout.pagePad,
            0,
            YmLayout.pagePad,
            10,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(YmRadius.box),
          ),
          child: Text(
            detail.intro.isEmpty ? '作者还没有填写简介。' : detail.intro,
            style: TextStyle(
              fontSize: YmFont.body14,
              height: 1.85,
              color: c.text,
            ),
          ),
        ),
        if (detail.notice.isNotEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(
              YmLayout.pagePad,
              0,
              YmLayout.pagePad,
              10,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: YmLayout.pagePad,
              vertical: 12,
            ),
            decoration: BoxDecoration(
              color: c.brandTint,
              borderRadius: BorderRadius.circular(YmRadius.box),
            ),
            child: Text(
              '作者公告：${detail.notice}',
              style: TextStyle(
                fontSize: YmFont.sub13,
                height: 1.5,
                color: c.brandInk,
              ),
            ),
          ),
        // 目录标题行：标题 + 排序 + 离线（缓存第一期 1E）。
        // 本体 YmSectionHeader 只有一个动作位且不允许改，所以这里用它的样式
        // （YmHeaderTextAction 与 .action 逐字同档）自己排一行。
        Padding(
          padding: const EdgeInsets.fromLTRB(
            YmLayout.pagePad,
            4,
            YmLayout.pagePad,
            10,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '目录 · 共 ${detail.chapterCount} 章',
                  style: c.sub13Strong,
                ),
              ),
              // 排序：图标取资产包 T18-13 / T18-14（左箭头 + 右三条等长横线）。
              // 方向按 2026-11-24 用户口径：**正序 = 箭头朝下**（sortDesc），
              // **倒序 = 箭头朝上**（sortAsc）—— 图标只表示当前方向，不表示「点了会怎样」。
              YmHeaderTextAction(
                label: desc ? '倒序' : '正序',
                icon: desc ? YmGlyphKind.sortAsc : YmGlyphKind.sortDesc,
                onTap: onToggleOrder,
                semanticLabel: '切换章节目录顺序',
              ),
              // 离线入口：只写「离线」+ 下载图标（2026-11-24 用户要求去掉 12/53、
              // 已离线这类计数状态 —— 存了多少章在弹层与离线内容页里都看得到）。
              YmHeaderTextAction(
                label: '离线',
                icon: YmGlyphKind.download,
                onTap: () => showYmNovelOfflineSheet(
                  context,
                  detail: detail,
                  chapters: detail.chapters,
                ),
                semanticLabel: '离线下载',
              ),
            ],
          ),
        ),
        for (final (volume, items) in _groups()) ...[
          if (volume.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(21, 18, 14, 8),
              child: Text(
                volume,
                // ⚠ 例外（书面）：分卷名是**目录分组标题**，资产包的分组标题档是
                // 12·650→w700（SlateSettingsGroupTitle），但本处母本取 15px 加重版；
                // 15px 不在资产包标题阶里，落回 body15 默认的 500 会让卷名与正文同重。
                // 本次口径只纠四档小字，15px 档维持 w800，登记为待统一（见核对文档）。
                style: TextStyle(
                  fontSize: YmFont.body15,
                  fontWeight: FontWeight.w800,
                  color: c.text,
                ),
              ),
            ),
          _tocGroup(context, volume, items, lastChapterId),
          if (volume.isNotEmpty && items.length > _volPreview)
            YmMoreButton(
              label: (expanded[volume] ?? false)
                  ? '收起，只看前 $_volPreview 章'
                  : '查看全部 ${items.length} 章',
              onTap: () => onToggleVolume(volume),
            )
          else if (volume.isEmpty && items.length > _flatLimit && !showAll)
            YmMoreButton(label: '展开全部 ${items.length} 章', onTap: onShowAll),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _tocGroup(
    BuildContext context,
    String volume,
    List<(int, YmChapterRef)> items,
    String lastChapterId,
  ) {
    final expandedVol = expanded[volume] ?? false;
    final visible = volume.isEmpty
        ? (showAll ? items : items.take(_flatLimit).toList())
        : (expandedVol ? items : items.take(_volPreview).toList());

    return YmCardList(
      children: [
        for (final (no, ch) in visible)
          YmTocRow(
            title: ch.title,
            index: no,
            current: ch.id == lastChapterId,
            onTap: () => _read(context, ch),
            // ⚠ 目录行上**不挂**逐章下载位（2026-11-24 用户纠偏）：
            // 下载动作只在标题行右侧那枚「离线」动作里，点开弹层后按章节勾选。
            // 这里留一个「整行点击 = 阅读」的干净行，别在目录里再塞第二个动作位。
          ),
      ],
    );
  }
}
