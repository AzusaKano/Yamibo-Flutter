
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
import 'manga_reader_page.dart';
import 'routes.dart';
import 'web_page.dart';

/// 漫画详情。字段与层级对齐 uni `pages/manga/detail.vue`：
/// 顶栏副行 = 分类 · 状态 · 形式 · 授权；卡内标签 = 分类 / 形式 / 状态（状态用品牌底色）。
class MangaDetailPage extends StatefulWidget {
  const MangaDetailPage({
    super.key,
    required this.id,
    this.title = '',
    this.fromShelf = false,
    this.resumeChaptId = '',
    this.resumePage = 1,
  });

  final String id;
  final String title;
  final bool fromShelf;

  /// 从在线书签进来时带的那一条（章节 id + 页码）—— 续读点取它而不是本地历史。
  final String resumeChaptId;
  final int resumePage;

  @override
  State<MangaDetailPage> createState() => _MangaDetailPageState();
}

class _MangaDetailPageState extends State<MangaDetailPage> {
  final ValueNotifier<String> _sub = ValueNotifier<String>('正在读取…');

  /// 是否还在用「书签带来的那个续读点」。
  ///
  /// 书签钉的位置才是用户从在线书架点进来时心里的「接着读这里」，可能和本机历史
  /// 差很远。这是个**临时**覆盖：一旦本机写下新的阅读记录（用户真读了），
  /// 覆盖就失效、交还给本地 —— 那时本地已经是被刷新过的那一份。
  /// 用进页面时的快照比对来判断「有没有被写过」，不按章节先后排序
  /// （章节号不一定可比：分卷、倒序、书签指向已删章节都会让比较失真）。
  bool _fromBookmark = false;
  YmHistoryEntry? _localSnap;

  /// 上一次刷新**失败**了（自动 / 手动）：副行挂「离线」。
  bool _refreshFailed = false;

  /// 内容区句柄：右上角菜单里的「刷新」通过它触发。
  final GlobalKey<YmLocalFirstAsyncState<YmMangaDetail>> _contentKey =
      GlobalKey<YmLocalFirstAsyncState<YmMangaDetail>>();

  /// 右上角菜单的触发器句柄（T24 菜单位置由它算，不做自动翻转）。
  final GlobalKey _menuKey = GlobalKey();

  /// 菜单是否打开（触发器要跟着换成「按下去」的底色）。
  bool _menuOpen = false;

  /// 取在线版本；`force` = 手动刷新，先作废进程内缓存再取。
  /// 取在线版本。`force` = 真取一次网络（自动进页面 / 手动刷新都传 true）：
  /// 命中五分钟缓存时 `fetchMangaDetail` 不发请求，断网也会「刷新成功」。
  /// 与小说详情同一口径。
  Future<YmMangaDetail> _loadRemote({bool force = false}) {
    if (force) evictCache('detail:${widget.id}');
    return fetchMangaDetail(widget.id);
  }

  @override
  void initState() {
    super.initState();
    _fromBookmark = widget.resumeChaptId.isNotEmpty;
    _localSnap = YmLibrary.instance.historyOf(widget.id);
    // 阅读历史 / 书架变化都要反映到本页：退出阅读器回来时，
    // 「继续阅读」的章节与页码、「读到这里」标记必须是刚存下的那一份。
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

  /// 右上角菜单：刷新 / 在网页打开。
  ///
  /// ⚠ 用资产包 **T24 菜单**（`design/widgets/menu.dart`，与帖子页 / 小说详情
  /// 同一个件），不是底部弹层；行上**不配副行说明**。位置由触发器算，不自动翻转。
  Future<void> _openMenu() async {
    if (_menuOpen || !mounted) return;
    setState(() => _menuOpen = true);
    final box = _menuKey.currentContext?.findRenderObject();
    final screen = MediaQuery.sizeOf(context);
    double? top;
    double? right;
    if (box is RenderBox && box.attached) {
      final pos = box.localToGlobal(Offset.zero);
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
                  url: '$kYmBase/manga/${widget.id}',
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
              title: widget.title.isEmpty ? '漫画' : widget.title,
              subtitle: sub,
              // 更多菜单：T24 菜单里放「刷新」与「在网页打开」（与小说详情同一套）
              trailing: YmMenuIconTrigger(
                key: _menuKey,
                isOpen: _menuOpen,
                onTap: _openMenu,
                semanticLabel: '更多操作',
              ),
            ),
          ),
          Expanded(
            child: YmLocalFirstAsync<YmMangaDetail>(
              key: _contentKey,
              // 先画本机那份（有就秒开），再后台换成在线版本
              loadLocal: () => ymOfflineMangaDetail(
                widget.id,
                title: widget.title,
              ),
              loadRemote: _loadRemote,
              errorTitle: '漫画加载失败',
              // 刷新成功 / 失败对称提示（与小说详情同一口径）
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
                final meta = [detail.cat, detail.status, detail.form, detail.license]
                    .where((e) => e.isNotEmpty)
                    .join(' · ');
                // 刷新失败才挂「离线」（还在刷新的那半秒不挂）
                final line = _refreshFailed
                    ? (meta.isEmpty ? '离线' : '离线 · $meta')
                    : meta;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  if (_sub.value != line) _sub.value = line;
                });
                return _Body(
                  detail: detail,
                  // 数据没换成在线版本 ⇒ 收藏先不放行（令牌可能是旧的）
                  locked: !fresh,
                  resumeChaptId: _fromBookmark ? widget.resumeChaptId : '',
                  resumePage: _fromBookmark ? widget.resumePage : 1,
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
  const _Body({required this.detail, this.resumeChaptId = '', this.resumePage = 1, this.locked = false});

  final YmMangaDetail detail;

  /// 数据还不是在线版本（本机副本 / 刷新失败）：收藏先不放行。
  final bool locked;

  /// 续读点（从在线书签进来时才有值）；`resumeChaptId` 为空 = 用本地历史。
  final String resumeChaptId;
  final int resumePage;

  void _read(BuildContext context, [YmChapterRef? chapter, int page = 1]) {
    final ch = chapter ?? (detail.chapters.isEmpty ? null : detail.chapters.first);
    if (ch == null) return;
    // ⚠ 不拦「没下载过的话」（2026-11-24 用户定案）：照常进阅读器，
    // 没有本机页图就让阅读器自己报错，不在这里拦。
    ymPush(context, MangaReaderPage(detail: detail, chapter: ch, initialPage: page));
  }

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    // 书签带来的续读点优先（连页码），否则用本地历史（规则见 data/resume.dart）
    final point = resolveResume(
      chapters: detail.chapters,
      hintChaptId: resumeChaptId,
      hintPage: resumePage,
      history: YmLibrary.instance.historyOf(detail.id),
    );
    // 「读到这里」跟着续读点走：从书签进来时它就该落在书签那一话
    final lastChapterId = point.chapter?.id ?? '';
    final primaryLabel = point.has ? '继续阅读' : '开始阅读';

    return ListView(
      padding: const EdgeInsets.only(bottom: 10),
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(YmLayout.pagePad, 14, YmLayout.pagePad, 12),
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
                    local: YmCache.instance.peekCoverFile('manga', detail.id),
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
                          detail.translator.isEmpty
                              ? (detail.author.isEmpty ? '佚名' : detail.author)
                              : '${detail.author.isEmpty ? '佚名' : detail.author} · 汉化 ${detail.translator}',
                          style: TextStyle(
                            fontSize: YmFont.small12,
                            height: 1.6,
                            color: c.text2,
                          ),
                        ),
                        if (detail.cat.isNotEmpty ||
                            detail.form.isNotEmpty ||
                            detail.status.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              if (detail.cat.isNotEmpty) YmTag(detail.cat),
                              if (detail.form.isNotEmpty) YmTag(detail.form),
                              if (detail.status.isNotEmpty)
                                YmTag(detail.status, brand: true),
                            ],
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
                manga: true,
                title: detail.title,
                author: detail.author,
                cover: detail.cover,
                primaryLabel: primaryLabel,
                // 继续阅读：把上次读到的页码一并带进阅读器
                onRead: () => _read(context, point.chapter, point.page),
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
        const YmSectionHeader(title: '简介', padding: EdgeInsets.fromLTRB(YmLayout.pagePad, 0, YmLayout.pagePad, 10)),
        Container(
          margin: const EdgeInsets.fromLTRB(YmLayout.pagePad, 0, YmLayout.pagePad, 10),
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
        // 目录标题行：标题 + 离线（缓存第二期 2E）。首次（2026-11-24）只有这一枚
        // 动作：漫画详情页本来没有排序口径，也不显示「已存 x / y 话」这类计数
        // （存了多少话在弹层与「离线内容」页里都看得到，口径同第一期 §二）。
        // 写法照 `novel_detail_page.dart` 自排 Row —— YmSectionHeader 只有
        // 一个动作位且不许改本体，所以用同一个样式（YmHeaderTextAction）自己排。
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
                  '目录 · 共 ${detail.chapterCount} 话',
                  style: c.sub13Strong,
                ),
              ),
              YmHeaderTextAction(
                label: '离线',
                icon: YmGlyphKind.download,
                onTap: () => showYmMangaOfflineSheet(context, detail: detail),
                semanticLabel: '离线下载',
              ),
            ],
          ),
        ),
        YmCardList(
          children: [
            for (final ch in detail.chapters)
              YmTocRow(
                title: ch.title,
                current: ch.id == lastChapterId,
                onTap: () => _read(context, ch),
              ),
          ],
        ),
      ],
    );
  }
}
