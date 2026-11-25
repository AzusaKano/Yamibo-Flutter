import 'package:flutter/material.dart';

import '../../data/forum/forum_api.dart';
import '../../data/forum/forum_models.dart'
    show ForumBlock, ForumParaBlock, ForumPost, ForumTocEntry;
import '../../data/forum/forum_track.dart';
import '../../data/http.dart' show YmHttpError;
import '../../data/reader_prefs.dart' show readerPrefs;
import '../../data/models.dart' show YmChapterRef;
import '../../design/system_ui.dart';
import '../../design/widgets/forum/forum_body.dart';
import '../../design/widgets/forum/forum_post_card.dart';
import '../../design/widgets/reader_paged_body.dart';
import '../../design/widgets/reader_page_slider.dart';
import '../../design/widgets/reader_restore.dart';
import '../../design/widgets/reader_shell.dart';
import '../../design/widgets/sheet.dart';
import '../../design/widgets/state_view.dart';
import 'forum_image_viewer.dart' show openForumImageViewer;
import 'forum_web.dart' show openForumBodyLink, openForumFindpost;

/// 论坛作品帖的阅读器（0.1.36 · 第十二期）。
///
/// 独立页面类型（push），不是帖子页的一种显示态。外观全部来自 [YmReaderShell]：
/// 正文用 [YmForumBody]（字号行距跟随全局阅读偏好），章末依次放评分、点评、章节导航；
/// 工具格是「目录 / 阅读设置 / 查看原帖」。
///
/// 加载一章：先定位「这一楼在哪一页」，再取那一页、按 pid 找楼。
/// * **本机有离线副本** ⇒ 在已下载的页里直接找 pid，**零请求**（断网可读）；
/// * 否则 `resolveFindpost(pid)` 拿服务端算好的页码 → 取那一页。
/// 楼不在这页就报错态，不静默空白、不自己算页码（置顶楼可能打乱顺序）。
class ForumReaderPage extends StatefulWidget {
  const ForumReaderPage({
    super.key,
    required this.tid,
    required this.title,
    required this.toc,
    required this.initialIndex,
  });

  final String tid;

  /// 帖子标题（顶栏主标题；章名走副标题）。
  final String title;

  /// 本次目录（页面会话内传入，不持久化）。
  final List<ForumTocEntry> toc;

  final int initialIndex;

  @override
  State<ForumReaderPage> createState() => _ForumReaderPageState();
}

class _ForumReaderPageState extends State<ForumReaderPage> {
  late int _index = widget.initialIndex;

  ForumPost? _post;
  bool _loading = true;
  String? _error;

  final ScrollController _scroll = ScrollController();
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  bool _chrome = true;

  /// 分页引擎的遥控器（第十六期）：滑杆与页码读数的数据源 + 跳页出口。
  /// 引擎装箱 / 翻页时回填（见引擎类注释），[YmReaderPageSlider.onDone]
  /// 直接接 `jumpTo`（±1 走动画、远距直接落位，漫画 `_goPage` 口径）。
  final YmReaderPagedController _pagedCtrl = YmReaderPagedController();

  /// 剧透展开态（分页模式外置给 [YmForumBody]：每页是独立实例，
  /// 展开态必须活过翻页重建；键 = pid + 片段序号，换章清空）。
  final Set<String> _revealed = <String>{};

  /// 块高度变化计数（图片解码完 / 折叠块收展）：折进分页引擎的
  /// 重排信号，变了就重测重排（保位）。
  int _layoutTick = 0;

  /// 本次进章要恢复的章内进度（分页引擎按它落页；滚动模式仍走
  /// restoreReaderScroll）。换章即换值，不跨章。
  double? _restorePercent;

  /// 当前生效的翻页模式（换模式时把章内位置递给另一侧，见 [_handleModeSwitch]）。
  bool _lastPagedMode = false;

  /// 请求序号：换章后旧请求回来不许覆盖新章。
  int _loadSeq = 0;

  /// pid → 页码（本页会话内缓存，目录来回翻不重复扫盘 / 不重复查跳转）。
  final Map<String, int> _pageOfPidMemo = <String, int>{};

  /// 章内位置恢复期间为 true：这段时间的进度写入一律不落盘
  /// （`jumpTo` 会带出一帧 `ScrollEnd`，那时位置还没到位，写下去就是错的）。
  bool _restoring = false;

  ForumTocEntry get _entry => widget.toc[_index];
  String get _chapterTitle => _entry.title;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _lastPagedMode = readerPrefs.paged; // 首帧不算「切换」
    setReaderImmersive(false); // 进阅读器先保证系统栏在
    _load(_index);
  }

  @override
  void dispose() {
    _recordOnExit();
    setReaderImmersive(false); // 离开阅读器恢复系统栏
    _scroll.dispose();
    _progress.dispose();
    _pagedCtrl.dispose();
    super.dispose();
  }

  Future<void> _load(int index) async {
    final seq = ++_loadSeq;
    final entry = widget.toc[index];
    // 先取旧进度再动任何状态：往下走一步就会把 `percent` 写成 0，取晚了就没了。
    final saved = ForumTrackStore.instance.recordOf(widget.tid);
    // 守卫：位置只属于它那一章。从目录点进别的章时，那是「另一章的位置」。
    final restoreTo = saved != null && saved.readerTocPid == entry.pid
        ? saved.readerPercent
        : null;
    setState(() {
      _loading = true;
      _error = null;
      _post = null;
    });
    try {
      final page = await _pageOfPid(entry.pid);
      final pages = await fetchForumThread(widget.tid, page: page);
      final post = pages.posts.where((p) => p.pid == entry.pid).firstOrNull;
      if (!mounted || seq != _loadSeq) return;
      if (post == null) {
        // 置顶楼可能把 pid 与页内顺序打乱：不在这一页就报错态，不瞎算页码。
        setState(() {
          _loading = false;
          _error = '这一章节加载失败';
        });
        return;
      }
      setState(() {
        _post = post;
        _loading = false;
        // 分页引擎按它落页；滚动模式照旧走 restoreReaderScroll
        _restorePercent = restoreTo;
        // 换章清剧透：键按 pid 隔离，防跨章累积
        _revealed.clear();
      });
      // 分页模式下先把恢复值放进进度（引擎首包前退出也能写对），引擎首包会覆盖
      _progress.value = readerPrefs.paged ? (restoreTo ?? 0) : 0;
      if (!readerPrefs.paged && _scroll.hasClients) _scroll.jumpTo(0);
      _restoring = readerPrefs.paged
          ? false // 分页位置由引擎首包落，不需要滚动路标
          : readerRestoreTarget(restoreTo) != null;
      if (!readerPrefs.paged) {
        try {
          if (_restoring) {
            await restoreReaderScroll(_scroll, restoreTo);
            if (!mounted || seq != _loadSeq) return;
          }
        } finally {
          _restoring = false;
        }
      }
      // 记一次「进了这一章」：恢复成功时写的是恢复后的位置，没恢复成也照常写。
      if (!mounted) return;
      _record();
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loading = false;
        _error = e is YmHttpError ? e.message : '这一章节加载失败';
      });
    }
  }

  /// 这一楼在哪一页。**本机优先，网络兜底**（2026-11-24 真机反馈修的离线读不了）：
  ///
  /// * 帖子离线保存过 ⇒ 已下载的页里逐页找 pid（零请求，断网可读）；
  /// * 找不到 ⇒ 老路 `resolveFindpost`（服务端算好页码，最准）；
  /// * 网络也失败 ⇒ 再回头扫一次本机（进入时索引还没就绪的情况）。
  ///
  /// 找到的页号按 pid 缓存在本页会话里：目录来回翻不重复扫盘。
  Future<int> _pageOfPid(String pid) async {
    final memo = _pageOfPidMemo[pid];
    if (memo != null) return memo;
    final local = await cachedForumPageOfPost(widget.tid, pid);
    if (local != null) return _pageOfPidMemo[pid] = local;
    try {
      final target = await resolveFindpost(pid);
      return _pageOfPidMemo[pid] = target.page;
    } catch (_) {
      final again = await cachedForumPageOfPost(widget.tid, pid);
      if (again != null) return _pageOfPidMemo[pid] = again;
      rethrow;
    }
  }

  void _go(int index) {
    if (index < 0 || index >= widget.toc.length) return;
    setState(() {
      _index = index;
      _chrome = true;
    });
    setReaderImmersive(false); // 换章把系统栏带回来
    _load(index);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final max = pos.maxScrollExtent;
    _progress.value = max <= 0 ? 0 : (pos.pixels / max).clamp(0.0, 1.0);
  }

  /// 章进度写入：楼层字段一个不碰（[ForumTrackStore.recordReaderProgress]）。
  void _record({bool immediate = false}) {
    // 恢复期间位置还没到位，写下去只会把真实进度抹成 0。
    if (_restoring) return;
    // 正文没到手（加载中 / 失败）时不写，免得把进度抹成 0%。
    if (_post == null) return;
    ForumTrackStore.instance.recordReaderProgress(
      tid: widget.tid,
      tocPid: _entry.pid,
      tocIndex: _index,
      tocTitle: _chapterTitle,
      percent: _progress.value,
      immediate: immediate,
    );
  }

  /// 退出补记：延到帧后（dispose 期间树是锁住的）+ 立即落盘。
  /// 第八期卡顿口径，与小说阅读器同一套，不许改回同步通知。
  void _recordOnExit() {
    if (_post == null) return;
    final tid = widget.tid;
    final pid = _entry.pid;
    final index = _index;
    final title = _chapterTitle;
    final percent = _progress.value;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ForumTrackStore.instance.recordReaderProgress(
        tid: tid,
        tocPid: pid,
        tocIndex: index,
        tocTitle: title,
        percent: percent,
        immediate: true,
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _setChrome(bool value) {
    if (_chrome == value) return;
    setState(() => _chrome = value);
    setReaderImmersive(!value);
  }

  void _openToc() {
    showYmSheet<void>(
      context,
      builder: (ctx) => YmTocSheet(
        chapters: [
          for (final e in widget.toc)
            YmChapterRef(id: e.pid, title: e.title, volume: ''),
        ],
        currentId: _entry.pid,
        unit: '条',
        onPick: (ch) {
          final i = widget.toc.indexWhere((e) => e.pid == ch.id);
          Navigator.of(ctx).pop();
          if (i >= 0 && i != _index) _go(i);
        },
      ),
    );
  }

  /// 阅读设置（与小说阅读器同一张面板、同一份 `readerPrefs`：一个阅读偏好，不分侧）。
  ///
  /// 论坛侧不给「字形」这一组：论坛正文不做简繁转换（逐片段转会改掉作者原文），
  /// 留一个点了没反应的档更糟。
  void _openSettings() {
    showYmSheet<void>(
      context,
      builder: (_) => const YmReaderSettingsSheet(showTraditional: false),
    );
  }

  /// 「查看原帖」：push 新页到该楼（用户已知道并接受会压栈，别改成替换当前页）。
  void _openOriginal() {
    openForumFindpost(context, _entry.pid);
  }

  void _openImage(String url) {
    final images = _post?.images ?? const <String>[];
    final idx = images.indexOf(url);
    openForumImageViewer(context, images, initial: idx < 0 ? 0 : idx);
  }

  @override
  Widget build(BuildContext context) {
    // 阅读偏好（字号 / 行距 / 翻页模式）变了就地重排 / 切换模式，不重请求。
    return AnimatedBuilder(
      animation: readerPrefs,
      builder: (context, _) {
        final post = _post;
        final prev = _index > 0 ? widget.toc[_index - 1] : null;
        final next = _index + 1 < widget.toc.length
            ? widget.toc[_index + 1]
            : null;

        final paged = readerPrefs.paged && post != null;
        _handleModeSwitch(paged);

        Widget? footer;
        if (post != null) {
          footer = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (post.rate != null) YmForumRateLine(rate: post.rate!),
              if (post.comments.isNotEmpty) ...[
                const SizedBox(height: 12),
                YmForumCommentsBox(comments: post.comments),
              ],
              // 章末区自带上边距（YmReaderEndBlock 的 34）
              YmReaderEndBlock(
                prev: prev == null
                    ? null
                    : YmChapterRef(id: prev.pid, title: prev.title, volume: ''),
                next: next == null
                    ? null
                    : YmChapterRef(id: next.pid, title: next.title, volume: ''),
                onPrev: () => _go(_index - 1),
                onNext: () => _go(_index + 1),
                onBack: () => Navigator.of(context).maybePop(),
              ),
            ],
          );
        }

        // 遥控器一变（装箱页数到位 / 翻页落位）就地重排底栏：滑杆与读数跟手。
        // 引擎回填走 postFrame（见引擎类注释），这里的重建不在 build 栈里。
        return AnimatedBuilder(
          animation: _pagedCtrl,
          builder: (context, _) {
            return YmReaderShell(
              controller: _scroll,
              progress: _progress,
              title: widget.title,
              subtitle: _chapterTitle,
              chrome: _chrome,
              onChromeChanged: _setChrome,
              onScrollEnd: () => _record(),
              // 分页多页才有滑杆（对齐漫画 totalPages > 1 口径）；页码读数插
              // 中排（漫画 :1437-1448 说明文字档）。滚动模式保持三格不动。
              tools: paged
                  ? [
                      YmReaderTool(label: '目录', onTap: _openToc),
                      YmReaderTool(
                        // 装箱前 pageCount = 0：先留空串占位，四格几何稳定，
                        // 不编页码（首包一两帧内补上）。
                        label: _pagedCtrl.pageCount > 0
                            ? '${_pagedCtrl.page} / ${_pagedCtrl.pageCount}'
                            : '',
                        onTap: () {},
                        info: true,
                      ),
                      YmReaderTool(label: '查看原帖', onTap: _openOriginal),
                      YmReaderTool(label: '阅读设置', onTap: _openSettings),
                    ]
                  : [
                      YmReaderTool(label: '目录', onTap: _openToc),
                      YmReaderTool(label: '阅读设置', onTap: _openSettings),
                      YmReaderTool(label: '查看原帖', onTap: _openOriginal),
                    ],
              barSlider: paged && _pagedCtrl.pageCount > 1
                  ? YmReaderPageSlider(
                      value: _pagedCtrl.page.toDouble(),
                      total: _pagedCtrl.pageCount,
                      onDone: _pagedCtrl.jumpTo,
                    )
                  : null,
              // 分页模式正文（含章末区装箱）交给 pagedContent；滚动模式原样。
              // pagedContent 给了壳就不渲染 body，给个空壳省一次正文构建。
              body: paged ? const SizedBox.shrink() : _buildBody(),
              footer: paged ? null : footer,
              pagedContent: paged ? _buildPaged(post, footer!) : null,
            );
          },
        );
      },
    );
  }

  /// 模式切换时把章内位置递给另一侧（一次性）。
  ///
  /// 滚动 → 分页：分页引擎吃 [YmReaderPagedBody.initialPercent]（即
  /// `_progress.value`），无需动作。分页 → 滚动：列表重新挂载回顶部，
  /// 按当前进度滚回去再记一笔。
  void _handleModeSwitch(bool paged) {
    if (paged == _lastPagedMode) return;
    final wasPaged = _lastPagedMode;
    _lastPagedMode = paged;
    if (!wasPaged) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _restoring = true;
      try {
        // 同章重挂载的落位：图片已进缓存、布局即时稳定，用短观察窗
        // （进章恢复才需要 1.5s 的图片漂移窗口）
        await restoreReaderScroll(
          _scroll,
          _progress.value,
          watch: const Duration(milliseconds: 200),
        );
      } finally {
        if (mounted) _restoring = false;
      }
      if (mounted) _record();
    });
  }

  /// 分页正文：整章块流（每块一个裸 widget 供测量）喂给引擎，页内切片
  /// 经 [buildPage] 重建可交互版本（剧透外置态 + seqBase，不跨页串键）。
  Widget _buildPaged(ForumPost post, Widget footer) {
    return YmReaderPagedBody(
      controller: _pagedCtrl,
      resetKey: post.pid,
      initialPercent: _restorePercent,
      // 记录值：字号 / 行距 / 块高度漂移计数任一变化都触发重排（保位）
      relayoutRevision: (
        readerPrefs.fontSize,
        readerPrefs.lineHeight,
        _layoutTick,
      ),
      gap: 8,
      blocks: [
        for (var i = 0; i < post.blocks.length; i++) _bodySlice(post, i, i + 1),
      ],
      footer: SizedBox(width: double.infinity, child: footer),
      onPageChanged: (p) {
        _progress.value = p;
        _record();
      },
      onChromeToggle: () => _setChrome(!_chrome),
      buildPage: (start, end) => _bodySlice(post, start, end),
    );
  }

  /// 一段块的可交互渲染（分页测量与页内切片同构，只差切片范围）。
  YmForumBody _bodySlice(ForumPost post, int start, int end) => YmForumBody(
    blocks: post.blocks.sublist(start, end),
    pid: post.pid,
    fontSize: readerPrefs.fontSize,
    lineHeight: readerPrefs.lineHeight,
    revealed: _revealed,
    onReveal: (key) => setState(() => _revealed.add(key)),
    seqBase: _inlineCountUpTo(post.blocks, start),
    onOpenLink: (href) => openForumBodyLink(context, href),
    onOpenImage: _openImage,
    onBlockLayoutChanged: _onBlockLayoutChanged,
  );

  /// 剧透键序号基址：外层序号只数段落内联（引用 / 折叠 / 图 / 附件不占号，
  /// 折叠块内部自成一体沿用旧口径）。
  int _inlineCountUpTo(List<ForumBlock> blocks, int start) {
    var n = 0;
    for (var i = 0; i < start && i < blocks.length; i++) {
      final b = blocks[i];
      if (b is ForumParaBlock) n += b.inlines.length;
    }
    return n;
  }

  /// 图片解码完 / 折叠块收展：高度漂了，折进重排信号（保位重排）。
  void _onBlockLayoutChanged() {
    if (!mounted) return;
    setState(() => _layoutTick++);
  }

  Widget _buildBody() {
    if (_loading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const YmSkeleton(width: 190, height: 28),
          const SizedBox(height: 18),
          const YmSkeleton(width: 120, height: 13),
          const SizedBox(height: 26),
          for (var i = 0; i < 12; i++) ...[
            YmSkeleton(width: i % 4 == 0 ? 190 : double.infinity, height: 15),
            const SizedBox(height: 13),
          ],
        ],
      );
    }
    final error = _error;
    if (error != null) {
      return YmStateView(
        title: '这一章节加载失败',
        desc: error == '这一章节加载失败' ? null : error,
        actionLabel: '重试',
        onAction: () => _load(_index),
      );
    }
    final post = _post;
    if (post == null) return const SizedBox.shrink();
    // 正文只铺楼层原本的块流（章名在顶栏副标题里，不另加标题——作者多半把
    // 章名写进正文第一段，再加一行会重复）。
    // 字号 / 行距跟着全局阅读偏好走：改设置后这一章就地重排（不回顶、不重请求）。
    return AnimatedBuilder(
      animation: readerPrefs,
      builder: (context, _) => YmForumBody(
        blocks: post.blocks,
        pid: post.pid,
        fontSize: readerPrefs.fontSize,
        lineHeight: readerPrefs.lineHeight,
        onOpenLink: (href) => openForumBodyLink(context, href),
        onOpenImage: _openImage,
      ),
    );
  }
}
