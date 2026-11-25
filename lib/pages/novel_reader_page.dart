import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/bookmark.dart';
import '../data/cn.dart';
import '../data/http.dart';
import '../data/library.dart';
import '../data/reader_prefs.dart' show readerPrefs;
import '../data/models.dart';
import '../data/session.dart';
import '../design/pressable.dart';
import '../design/system_ui.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/widgets/reader_paged_body.dart';
import '../design/widgets/reader_page_slider.dart';
import '../design/widgets/reader_restore.dart';
import '../design/widgets/reader_shell.dart';
import '../design/widgets/sheet.dart';
import '../design/widgets/state_view.dart';
import '../design/widgets/toast.dart';

class NovelReaderPage extends StatefulWidget {
  const NovelReaderPage({
    super.key,
    required this.detail,
    required this.initial,
  });

  final YmNovelDetail detail;
  final YmChapterRef initial;

  @override
  State<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends State<NovelReaderPage> {
  late YmChapterRef _chapter = widget.initial;
  YmChapterContent? _content;
  bool _loading = true;
  bool _needLogin = false;
  String? _error;

  /// 这一章的**原文**是繁体还是简体 —— 载入正文时按整章判一次。
  /// 不逐段判：一句话只有十几个字时票数容易打平或打反，短段会被转过头。
  bool _srcTraditional = false;

  final _scroll = ScrollController();
  final _progress = ValueNotifier<double>(0);
  bool _chrome = true;

  /// 分页引擎的遥控器（第十六期）：滑杆与页码读数的数据源 + 跳页出口。
  /// 引擎装箱 / 翻页时回填（见引擎类注释），[YmReaderPageSlider.onDone]
  /// 直接接 `jumpTo`（±1 走动画、远距直接落位，漫画 `_goPage` 口径）。
  final YmReaderPagedController _pagedCtrl = YmReaderPagedController();

  /// 本次进章要恢复的章内进度（分页引擎按它落页；滚动模式仍走
  /// restoreReaderScroll）。换章即换值，不跨章。
  double? _restorePercent;

  /// 当前生效的翻页模式（换模式时把章内位置递给另一侧）。
  bool _lastPagedMode = false;

  /// 章内位置恢复期间为 true：这段时间的进度写入一律不落盘
  /// （`jumpTo` 会带出一帧 `ScrollEnd`，那时位置还没到位，写下去就是错的）。
  bool _restoring = false;

  /// 站内书签清单（第 1 页就够判定「当前这一章有没有钉着」，见 `data/bookmark.dart`）。
  /// `null` = 还没取到 / 取不到（未登录、断网）⇒ 按钮按「没钉」显示，点了会先提示登录。
  YmBookmarkFeed? _marks;

  String get _displayTitle => _content?.title ?? _chapter.title;
  String get _author => _content?.author ?? widget.detail.author;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _lastPagedMode = readerPrefs.paged; // 首帧不算「切换」
    setReaderImmersive(false); // 进阅读器先保证系统栏在
    _load(_chapter);
  }

  Future<void> _load(YmChapterRef ch) async {
    // 先取旧进度：往下走一步就会把 `percent` 写成 0，取晚了就没了。
    final saved = YmLibrary.instance.historyOf(widget.detail.id);
    // 守卫：章内位置只属于它那一章 —— 从目录点进别的章时，那位置是「另一章的」。
    final restoreTo = saved != null && saved.chapterId == ch.id
        ? saved.percent
        : null;
    setState(() {
      _loading = true;
      _needLogin = false;
      _error = null;
      _content = null;
    });
    try {
      final data = await fetchChapter(ch.id);
      if (!mounted) return;
      final srcTraditional = isTraditionalText(data.paragraphs.join('\n'));
      setState(() {
        _content = data;
        _srcTraditional = srcTraditional;
        _loading = false;
        // 分页引擎按它落页；滚动模式照旧走 restoreReaderScroll
        _restorePercent = restoreTo;
      });
      // 分页模式下先把恢复值放进进度（引擎首包前退出也能写对），引擎首包会覆盖
      _progress.value = readerPrefs.paged ? (restoreTo ?? 0) : 0;
      if (!readerPrefs.paged && _scroll.hasClients) _scroll.jumpTo(0);
      // 正文先到，再问书签状态：`user` 优先级的请求会抢在正文前面占 lane 槽位，
      // 放在这里（不 await）就不会拖慢首屏。恢复位置要在这里之后、独立进行，
      // 否则恢复窗口会把书签按钮的状态拖晚一秒多。
      _syncMarks();
      _restoring = readerPrefs.paged
          ? false // 分页位置由引擎首包落，不需要滚动路标
          : readerRestoreTarget(restoreTo) != null;
      if (!readerPrefs.paged) {
        try {
          if (_restoring) {
            await restoreReaderScroll(_scroll, restoreTo);
            // 恢复期间换了章：这一章的位置不该落到新章上。
            if (!mounted || _chapter.id != ch.id) return;
          }
        } finally {
          _restoring = false;
        }
      }
      // 记一次「进了这一章」：恢复成功时写的是恢复后的位置，没恢复成也照常写。
      if (!mounted) return;
      _record();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (e is YmHttpError && e.isLoginRequired) {
          _needLogin = true;
        } else {
          _error = e is YmHttpError ? e.message : '加载失败';
        }
      });
    }
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

  /// 退出这一刻的滚动位置就是「本次进度」：滚动只在 ScrollEnd 时记，
  /// 惯性里直接返回、或按返回按钮时那一屏滚动还没停，都会漏掉，所以补记一次。
  ///
  /// 两点讲究：
  /// - **延到本帧结束后再写**：`dispose` 期间 widget 树是锁住的，`recordRead` 里的
  ///   `notifyListeners` 会把详情页的监听者标脏，框架会抛
  ///   「setState() or markNeedsBuild() called when widget tree was locked」。
  /// - **立即落盘**（`immediate`）：退出后进程随时可能被杀，等不了 300ms 防抖。
  void _recordOnExit() {
    if (_content == null) return; // 正文没到手就别把进度记成 0%
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _record(immediate: true);
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final max = pos.maxScrollExtent;
    _progress.value = max <= 0 ? 0 : (pos.pixels / max).clamp(0.0, 1.0);
  }

  void _record({bool immediate = false}) {
    // 恢复期间位置还没到位，写下去只会把真实进度抹成 0。
    if (_restoring) return;
    // 正文还没到手（加载中 / 需登录 / 失败）时不写，免得把进度记成 0%
    if (_content == null) return;
    YmLibrary.instance.recordRead(
      id: widget.detail.id,
      title: widget.detail.title,
      author: widget.detail.author,
      cat: widget.detail.cat,
      kind: 'novel',
      cover: widget.detail.cover,
      chapterTitle: _displayTitle,
      chapterId: _chapter.id,
      percent: _progress.value,
      immediate: immediate,
    );
  }

  YmChapterRef? _neighbor(int delta) {
    final list = widget.detail.chapters;
    final i = list.indexWhere((e) => e.id == _chapter.id);
    if (i < 0) return null;
    final j = i + delta;
    if (j < 0 || j >= list.length) return null;
    return list[j];
  }

  void _go(YmChapterRef? ch) {
    if (ch == null) return;
    setState(() {
      _chapter = ch;
      _chrome = true;
    });
    setReaderImmersive(false); // 换章把系统栏带回来
    _load(ch);
  }

  void _openToc() {
    showYmSheet<void>(
      context,
      builder: (ctx) => YmTocSheet(
        chapters: widget.detail.chapters,
        currentId: _chapter.id,
        onPick: (ch) {
          Navigator.of(ctx).pop();
          _go(ch);
        },
      ),
    );
  }

  /// 阅读设置走底部弹层（与漫画阅读器同一套设计），不再用 uni 那排内联 `font-row`。
  void _openSettings() {
    showYmSheet<void>(
      context,
      builder: (_) => const YmReaderSettingsSheet(),
    );
  }

  void _toast(String text) {
    showYmToast(context, text, bottomOffset: 108);
  }

  /// 当前这一章是否已经钉着书签。切章后 `_chapter.id` 变、清单不变，直接比对。
  bool get _pinned => bookmarkedAt(_marks, chaptId: _chapter.id);

  Future<void> _syncMarks() async {
    final feed = await probeBookmarks();
    if (!mounted) return;
    setState(() => _marks = feed);
  }

  /// 加 / 取消书签。站点是**翻转**接口且一本书只有一条书签（唯一性在「用户×作品」），
  /// 所以「加」在别的章有书签时是**覆盖**（书签移到这一章），正是「从这里继续」的语义。
  Future<void> _bookmark() async {
    if (!YmSession.loggedIn) {
      _toast('登录后可使用书签');
      return;
    }
    final wasPinned = _pinned;
    final chaptId = _chapter.id;
    try {
      final r = await setBookmarkAt(
        workId: _content?.workId ?? widget.detail.id,
        chaptId: chaptId,
        manga: false,
        pinned: wasPinned,
        csrfToken: _content?.csrfToken ?? '',
      );
      if (!mounted) return;
      if (!r.ok) {
        _toast('没能保存书签，请稍后再试');
        return;
      }
      _toast(r.on ? '已加书签' : '已取消书签');
      // 清单在写通道里已作废，重取一份让按钮状态跟上
      _syncMarks();
    } on YmHttpError catch (e) {
      if (!mounted) return;
      _toast(e.isLoginRequired ? '登录后可使用书签' : '没能保存书签，请稍后再试');
    } catch (_) {
      if (!mounted) return;
      _toast('没能保存书签，请稍后再试');
    }
  }

  /// 工具栏显隐与系统栏联动：收起时进入沉浸全屏。
  void _setChrome(bool value) {
    if (_chrome == value) return;
    setState(() => _chrome = value);
    setReaderImmersive(!value);
  }

  /// 翻页模式切换时把章内位置递给另一侧（一次性）。
  ///
  /// 滚动 → 分页：分页引擎吃 initialPercent（即 `_progress.value`），无需动作。
  /// 分页 → 滚动：列表重新挂载回顶部，按当前进度滚回去再记一笔。
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

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;

    return AnimatedBuilder(
      animation: readerPrefs,
      builder: (context, _) {
        final prefs = readerPrefs;

        // 翻页模式（第十五期）：正文整章交给分页引擎按屏装箱；加载 / 登录 / 错误
        // 态仍走滚动骨架（过渡态，占一页即可）。
        final paged =
            prefs.paged &&
            !_loading &&
            !_needLogin &&
            _error == null &&
            (_content?.paragraphs.isNotEmpty ?? false);
        _handleModeSwitch(paged);

        final endBlock = YmReaderEndBlock(
          prev: _neighbor(-1),
          next: _neighbor(1),
          onPrev: () => _go(_neighbor(-1)),
          onNext: () => _go(_neighbor(1)),
          onBack: () => Navigator.of(context).maybePop(),
        );

        Widget? pagedContent;
        if (paged) {
          final gap = prefs.fontSize * 0.85;
          final blocks = <Widget>[
            // 章名头（与滚动模式同一组件、同一间距，作为第 0 块参与装箱）
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _displayTitle,
                  style: TextStyle(
                    fontSize: YmFont.title23,
                    fontWeight: FontWeight.w800,
                    height: 1.4,
                    color: c.text,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _content == null
                      ? _author
                      : '$_author · 本章 ${_content!.words} 字',
                  style: c.small12.copyWith(color: c.text2, height: 1.6),
                ),
              ],
            ),
            for (var i = 0; i < _content!.paragraphs.length; i++)
              Text(
                i < 2
                    ? readerText(
                        _content!.paragraphs[i],
                        prefs.traditional,
                        sourceTraditional: _srcTraditional,
                      )
                    : '　　${readerText(_content!.paragraphs[i], prefs.traditional, sourceTraditional: _srcTraditional)}',
                style: TextStyle(
                  fontSize: prefs.fontSize,
                  height: prefs.lineHeight,
                  color: c.text,
                ),
              ),
          ];
          pagedContent = YmReaderPagedBody(
            controller: _pagedCtrl,
            resetKey: _chapter.id,
            initialPercent: _restorePercent,
            relayoutRevision: (prefs.fontSize, prefs.lineHeight),
            gap: gap,
            blocks: blocks,
            footer: SizedBox(width: double.infinity, child: endBlock),
            onPageChanged: (p) {
              _progress.value = p;
              _record();
            },
            onChromeToggle: () => _setChrome(!_chrome),
            // 页内切片：块间距始终与引擎的 [gap] 同口径（装箱按它折算）
            buildPage: (start, end) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = start; i < end; i++) ...[
                  if (i > start) SizedBox(height: gap),
                  blocks[i],
                ],
              ],
            ),
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
              title: widget.detail.title,
              subtitle: _displayTitle,
              trailing: _DetailAction(
                // 进阅读器的唯一路径是作品详情页（书架 / 历史 / 排行 / 搜索
                // 都是先进详情、再由用户点章节进来）⇒ 上一页必是详情，pop 即回。
                onTap: () => Navigator.of(context).maybePop(),
              ),
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
                      YmReaderTool(
                        label: _pinned ? '取消书签' : '加书签',
                        onTap: _bookmark,
                        active: _pinned,
                      ),
                      YmReaderTool(label: '阅读设置', onTap: _openSettings),
                    ]
                  : [
                      YmReaderTool(label: '目录', onTap: _openToc),
                      YmReaderTool(label: '阅读设置', onTap: _openSettings),
                      YmReaderTool(
                        label: _pinned ? '取消书签' : '加书签',
                        onTap: _bookmark,
                        active: _pinned,
                      ),
                    ],
              barSlider: paged && _pagedCtrl.pageCount > 1
                  ? YmReaderPageSlider(
                      value: _pagedCtrl.page.toDouble(),
                      total: _pagedCtrl.pageCount,
                      onDone: _pagedCtrl.jumpTo,
                    )
                  : null,
              // 分页时正文与章末区都归引擎；滚动模式原样（逐字节不变）。
              body: paged
                  ? const SizedBox.shrink()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _displayTitle,
                          style: TextStyle(
                            fontSize: YmFont.title23,
                            fontWeight: FontWeight.w800,
                            height: 1.4,
                            color: c.text,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _content == null
                              ? _author
                              : '$_author · 本章 ${_content!.words} 字',
                          style: c.small12.copyWith(
                            color: c.text2,
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (_loading)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const YmSkeleton(width: 190, height: 28),
                              const SizedBox(height: 18),
                              const YmSkeleton(width: 120, height: 13),
                              const SizedBox(height: 26),
                              for (var i = 0; i < 12; i++) ...[
                                YmSkeleton(
                                  width: i % 4 == 0 ? 190 : double.infinity,
                                  height: 15,
                                ),
                                const SizedBox(height: 13),
                              ],
                            ],
                          )
                        else if (_needLogin)
                          YmStateView(
                            title: '登录后使用',
                            desc: '这一章的正文需要登录百合会后阅读。',
                          )
                        else if (_error != null)
                          YmStateView(
                            title: '正文加载失败',
                            desc: _error,
                            actionLabel: '重试',
                            onAction: () => _load(_chapter),
                          )
                        else
                          for (
                            var i = 0;
                            i < (_content?.paragraphs.length ?? 0);
                            i++
                          ) ...[
                            Text(
                              i < 2
                                  ? readerText(
                                      _content!.paragraphs[i],
                                      prefs.traditional,
                                      sourceTraditional: _srcTraditional,
                                    )
                                  : '　　${readerText(_content!.paragraphs[i], prefs.traditional, sourceTraditional: _srcTraditional)}',
                              style: TextStyle(
                                fontSize: prefs.fontSize,
                                height: prefs.lineHeight,
                                color: c.text,
                              ),
                            ),
                            SizedBox(height: prefs.fontSize * 0.85),
                          ],
                      ],
                    ),
              footer: !paged && !_loading && !_needLogin && _error == null
                  ? endBlock
                  : null,
              pagedContent: pagedContent,
            );
          },
        );
      },
    );
  }
}

class _DetailAction extends StatelessWidget {
  const _DetailAction({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return YmPressable(
      kind: YmPressKind.row,
      radius: BorderRadius.circular(YmRadius.chip),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
        child: Text('详情', style: c.sub13Strong.copyWith(color: c.text2)),
      ),
    );
  }
}
