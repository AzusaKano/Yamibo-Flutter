import 'package:flutter/material.dart';

import '../data/cache/offline_detail.dart';
import '../data/cache/ym_cache_store.dart';
import '../data/models.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/widgets/lists.dart';
import '../design/widgets/offline_controls.dart';
import '../design/widgets/selection.dart';
import '../design/widgets/sheet.dart';
import '../design/widgets/state_view.dart';
import '../design/widgets/top_bar.dart';
import 'manga_reader_page.dart';
import 'novel_reader_page.dart';
import 'routes.dart';
import 'forum/forum_thread_page.dart' show ForumThreadPage;

/// 离线内容子页（缓存第一期 1F / 第三期任务 A）：一本书 / 一个帖子已存了哪些章（页）。
///
/// 非选择态点一行 ⇒ **直接进阅读器**，从这一章 / 这一话开始读（第三期任务 A，
/// 2026-11-24）：断网时详情页拉不出来，正文与页图却都在本机，所以入口不能只挂在
/// 详情页上。详情由 `offline_detail.dart` 从磁盘索引合成，目录只含已存的章。
/// 选择态点行仍然只勾选。
///
/// 论坛（缓存第三期）：一页 = 帖子的一页，点行打开那一页的帖子页（读盘优先，
/// 断网零请求），与小说 / 漫画一样「点一行直接进内容」。
class OfflineDetailPage extends StatefulWidget {
  const OfflineDetailPage({super.key, required this.work});

  final YmOfflineWork work;

  @override
  State<OfflineDetailPage> createState() => _OfflineDetailPageState();
}

class _OfflineDetailPageState extends State<OfflineDetailPage> {
  bool _selecting = false;
  final Set<String> _sel = <String>{};

  String get _unit => switch (widget.work.source) {
    'manga' => '话',
    'forum' => '页',
    _ => '章',
  };

  List<YmCacheEntry> _units() {
    final list = YmCache.instance
        .peekOfParent(widget.work.source, widget.work.parent)
        .where((e) => e.state.isDone)
        .toList();
    return list;
  }

  void _exitSelect() {
    if (!_selecting && _sel.isEmpty) return;
    setState(() {
      _selecting = false;
      _sel.clear();
    });
  }

  void _toggle(String key) {
    setState(() {
      _selecting = true;
      if (!_sel.remove(key)) _sel.add(key);
      if (_sel.isEmpty) _selecting = false;
    });
  }

  void _selectAll(List<YmCacheEntry> units) {
    setState(() {
      if (_sel.length == units.length) {
        _sel.clear();
        _selecting = false;
      } else {
        _sel
          ..clear()
          ..addAll(units.map((e) => e.key));
      }
    });
  }

  Future<void> _removeSelected(List<YmCacheEntry> units) async {
    final picked = units.where((e) => _sel.contains(e.key)).toList();
    if (picked.isEmpty) return;
    final bytes = picked.fold<int>(0, (sum, e) => sum + e.bytes);
    final ok = await showYmConfirm(
      context,
      title: '删除离线内容',
      content: '删除 ${picked.length} 项？共 ${ymBytes(bytes)}。',
      confirmText: '删除',
      danger: true,
    );
    if (ok != true || !mounted) return;
    for (final e in picked) {
      await YmCache.instance.removeUnit(e.key);
    }
    if (!mounted) return;
    _exitSelect();
  }

  /// 非选择态点一行 ⇒ 从这一章 / 这一话开始读（第三期任务 A）。
  ///
  /// 三条讲究：
  /// * detail 从索引合成（只含已存的章 / 话），`id` 用真实的 `parent`，
  ///   这样历史 / 进度与在线阅读写的是同一本，不新建第二套；
  /// * 阅读时一律走既有磁盘优先链路（`fetchChapter` / `fetchMangaChapter`）——
  ///   本机命中就是零请求，**这里不额外发任何请求**；
  /// * 论坛的离线内容是帖子分页，没有阅读器入口，点行不给假反馈。
  Future<void> _openUnit(YmCacheEntry entry) async {
    final work = widget.work;
    final unitId = entry.id;
    switch (work.source) {
      case 'novel':
        final detail = await ymOfflineNovelDetail(
          work.parent,
          title: work.parentTitle,
        );
        if (detail == null) return;
        final initial = _pick(detail.chapters, unitId);
        if (initial == null) return;
        if (!mounted) return;
        ymPush(context, NovelReaderPage(detail: detail, initial: initial));
      case 'manga':
        final detail = await ymOfflineMangaDetail(
          work.parent,
          title: work.parentTitle,
        );
        if (detail == null) return;
        final chapter = _pick(detail.chapters, unitId);
        if (chapter == null) return;
        if (!mounted) return;
        ymPush(context, MangaReaderPage(detail: detail, chapter: chapter));
      default:
        // 论坛（缓存第三期）：一页就是一个帖子页，点行打开那一页。
        // 帖子页自己读盘优先，断网也是零请求；没存过的页会走网络并如实报错。
        final page = int.tryParse(unitId) ?? 1;
        if (!mounted) return;
        ymPush(
          context,
          ForumThreadPage(
            tid: work.parent,
            initialPage: page <= 0 ? 1 : page,
            name: work.parentTitle,
            // 从离线内容进来是「我已经指定了页」，不该再按追帖记录跳回别处
            restoreProgress: false,
          ),
        );
    }
  }

  /// 按 unit id 找到对应的章节；找不到（理论上不会）就退回第一章，
  /// 免得点了没反应。列表本身已经只含已存的章。
  YmChapterRef? _pick(List<YmChapterRef> chapters, String id) {
    if (chapters.isEmpty) return null;
    for (final ch in chapters) {
      if (ch.id == id) return ch;
    }
    return chapters.first;
  }

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    // ⚠ 同离线内容页：必须有 Scaffold/Material 祖先，否则文字落回错误样式（黄线）。
    return Scaffold(
      body: AnimatedBuilder(
        animation: YmCache.instance,
        builder: (context, _) {
          final units = _units();
          final bytes = units.fold<int>(0, (sum, e) => sum + e.bytes);
          final total = widget.work.total;
          final safeBottom = MediaQuery.viewPaddingOf(context).bottom;

          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Column(
                children: <Widget>[
                  YmTopBar(
                    leading: const YmBackButton(),
                    title: widget.work.parentTitle.isEmpty
                        ? '离线内容'
                        : widget.work.parentTitle,
                    subtitle: units.isEmpty
                        ? '已经没有内容'
                        : '已存 ${units.length}${total > 0 ? ' / $total' : ''} $_unit · ${ymBytes(bytes)}',
                    trailing: units.isEmpty
                        ? null
                        : YmTopBarAction(
                            label: _selecting ? '取消' : '选择',
                            onTap: _selecting
                                ? _exitSelect
                                : () => setState(() => _selecting = true),
                          ),
                  ),
                  Expanded(child: _body(c, units, safeBottom)),
                ],
              ),
              if (_selecting && units.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: YmSelectBar(
                    countText: '已选 ${_sel.length} 项',
                    leading: YmSelectAction(
                      label: _sel.length == units.length ? '取消全选' : '全选',
                      kind: YmSelectActionKind.selectAll,
                      onTap: () => _selectAll(units),
                    ),
                    trailing: YmSelectAction(
                      label: '删除',
                      kind: YmSelectActionKind.delete,
                      enabled: _sel.isNotEmpty,
                      onTap: () => _removeSelected(units),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _body(YmColors c, List<YmCacheEntry> units, double safeBottom) {
    if (units.isEmpty) {
      return ListView(children: const <Widget>[YmStateView(title: '还没有内容')]);
    }
    return ListView(
      // 顶栏线到第一条之间留 14（对齐首页 / 列表页的既有口径）
      padding: EdgeInsets.only(
        top: 14,
        bottom: _selecting
            ? YmSelectMetrics.pageBottomInset + safeBottom
            : 10 + safeBottom,
      ),
      children: <Widget>[
        YmCardList(
          children: <Widget>[
            for (final e in units)
              YmTocRow(
                title: e.title.isEmpty ? e.id : e.title,
                index: e.order > 0 ? e.order : null,
                trailing: _selecting
                    ? Padding(
                        padding: const EdgeInsets.only(right: 14),
                        child: YmSelectionCheck(selected: _sel.contains(e.key)),
                      )
                    : null,
                onTap: _selecting
                    ? () => _toggle(e.key)
                    : () => _openUnit(e),
              ),
          ],
        ),
      ],
    );
  }
}
