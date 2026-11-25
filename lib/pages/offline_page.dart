import 'package:flutter/material.dart';

import '../data/cache/ym_cache_store.dart';
import '../design/pressable.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/widgets/chip.dart';
import '../design/widgets/cover.dart';
import '../design/widgets/lists.dart';
import '../design/widgets/offline_controls.dart';
import '../design/widgets/selection.dart';
import '../design/widgets/sheet.dart';
import '../design/widgets/state_view.dart';
import '../design/widgets/top_bar.dart';
import 'offline_detail_page.dart';
import 'routes.dart';

/// 离线内容管理页（缓存第一期 1F）：三枚分类胶囊 + 汇总行 + 作品行 + 选择模式批量删。
///
/// 口径：
/// * 只列**已落账**的 unit（`state == done`），排队 / 下载中 / 失败的不算「有内容」；
/// * 按 parent 聚合，小说 = 一本一行，漫画 = 一本一行，论坛 = 一帖一行；
/// * 空态**只有一句**「还没有内容」（用户 2026-11-24 明确要求，不要解释性副文案、
///   不要引导按钮）；
/// * 批量删只删选中的作品，删前进确认并报「释放约 X」。
class OfflinePage extends StatefulWidget {
  const OfflinePage({super.key});

  @override
  State<OfflinePage> createState() => _OfflinePageState();
}

class _OfflinePageState extends State<OfflinePage> {
  /// null = 全部；`novel` / `manga` / `forum` = 只看这一类。
  String? _source;

  bool _selecting = false;
  final Set<String> _sel = <String>{};

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

  void _selectAll(List<YmOfflineWork> works) {
    setState(() {
      if (_sel.length == works.length) {
        _sel.clear();
        _selecting = false;
      } else {
        _sel
          ..clear()
          ..addAll(works.map((w) => w.key));
      }
    });
  }

  Future<void> _removeSelected(List<YmOfflineWork> works) async {
    final picked = works.where((w) => _sel.contains(w.key)).toList();
    if (picked.isEmpty) return;
    final bytes = picked.fold<int>(0, (sum, w) => sum + w.bytes);
    final ok = await showYmConfirm(
      context,
      title: '删除离线内容',
      content: '删除 ${picked.length} 项？共 ${ymBytes(bytes)}。',
      confirmText: '删除',
      danger: true,
    );
    if (ok != true || !mounted) return;
    for (final w in picked) {
      await YmCache.instance.removeParent(w.source, w.parent);
    }
    if (!mounted) return;
    _exitSelect();
  }

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    // ⚠ 必须有 Scaffold/Material 祖先：否则 Text 会落回 WidgetsApp 的「错误样式」
    // （红字 + 黄色双下划线），整页文字都带黄线（sheet.dart 里踩过一次同款坑）。
    return Scaffold(
      body: AnimatedBuilder(
        animation: YmCache.instance,
        builder: (context, _) {
          final works = ymOfflineWorks(source: _source);
          final bytes = works.fold<int>(0, (sum, w) => sum + w.bytes);
          final safeBottom = MediaQuery.viewPaddingOf(context).bottom;

          return Stack(
            fit: StackFit.expand,
            children: [
              Column(
                children: <Widget>[
                  YmTopBar(
                    leading: const YmBackButton(),
                    title: '离线内容',
                    subtitle: works.isEmpty
                        ? null
                        : '共 ${works.length} 本 · ${ymBytes(bytes)}',
                    trailing: works.isEmpty
                        ? null
                        : YmTopBarAction(
                            label: _selecting ? '取消' : '选择',
                            onTap: _selecting
                                ? _exitSelect
                                : () => setState(() => _selecting = true),
                          ),
                  ),
                  _filters(),
                  Expanded(child: _body(c, works, safeBottom)),
                ],
              ),
              if (_selecting && works.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: YmSelectBar(
                    countText: '已选 ${_sel.length} 项',
                    leading: YmSelectAction(
                      label: _sel.length == works.length ? '取消全选' : '全选',
                      kind: YmSelectActionKind.selectAll,
                      onTap: () => _selectAll(works),
                    ),
                    trailing: YmSelectAction(
                      label: '删除',
                      kind: YmSelectActionKind.delete,
                      enabled: _sel.isNotEmpty,
                      onTap: () => _removeSelected(works),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 三枚分类胶囊：点未选中的 = 只看这类；点已选中的 = 回到全部。
  Widget _filters() {
    String label(String source) => switch (source) {
      'novel' => '小说',
      'manga' => '漫画',
      _ => '论坛',
    };

    Widget chip(String source) => YmChip(
      style: YmChipStyle.pill,
      pressKind: YmPressKind.solid,
      label: label(source),
      active: _source == source,
      onTap: () {
        _exitSelect();
        setState(() => _source = _source == source ? null : source);
      },
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        YmLayout.pagePad,
        14,
        YmLayout.pagePad,
        14,
      ),
      child: Row(
        children: <Widget>[
          chip('novel'),
          const SizedBox(width: 8),
          chip('manga'),
          const SizedBox(width: 8),
          chip('forum'),
        ],
      ),
    );
  }

  Widget _body(YmColors c, List<YmOfflineWork> works, double safeBottom) {
    if (works.isEmpty) {
      // 空态：只有这一句（用户要求，不加副文案、不加引导按钮）
      return ListView(children: const <Widget>[YmStateView(title: '还没有内容')]);
    }
    return ListView(
      padding: EdgeInsets.only(
        bottom: _selecting
            ? YmSelectMetrics.pageBottomInset + safeBottom
            : 10 + safeBottom,
      ),
      children: <Widget>[
        YmCardList(
          children: <Widget>[
            for (final w in works)
              _OfflineWorkRow(
                work: w,
                selecting: _selecting,
                selected: _sel.contains(w.key),
                onTap: () {
                  if (_selecting) {
                    _toggle(w.key);
                    return;
                  }
                  ymPush(context, OfflineDetailPage(work: w));
                },
                onLongPress: () {
                  if (_selecting) {
                    _toggle(w.key);
                  } else {
                    setState(() {
                      _selecting = true;
                      _sel.add(w.key);
                    });
                  }
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// 作品行：48×64 封面（论坛是 34px 首字方牌）+ 书名 + 副行「已存 12 / 53 章 · 4.2 MB」。
class _OfflineWorkRow extends StatelessWidget {
  const _OfflineWorkRow({
    required this.work,
    required this.selecting,
    required this.selected,
    this.onTap,
    this.onLongPress,
  });

  final YmOfflineWork work;
  final bool selecting;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  String get _unit => switch (work.source) {
    'manga' => '话',
    'forum' => '页',
    _ => '章',
  };

  String get _subtitle {
    final count = work.total > 0
        ? '已存 ${work.done} / ${work.total} $_unit'
        : '已存 ${work.done} $_unit';
    return '$count · ${ymBytes(work.bytes)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return YmPressable(
      kind: selecting ? YmPressKind.none : YmPressKind.row,
      radius: BorderRadius.zero,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (selecting) ...<Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: YmSelectionCheck(selected: selected),
              ),
              const SizedBox(width: 12),
            ],
            if (work.source == 'forum')
              _ForumTile(title: work.parentTitle)
            else
              YmCover(
                title: work.parentTitle,
                // 本机封面（第三期任务 B）：没存过 = null，继续走首字占位
                local: YmCache.instance.peekCoverFile(
                  work.source,
                  work.parent,
                ),
                width: 48,
                height: 64,
                radius: YmRadius.ctrl,
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    work.parentTitle.isEmpty ? '未命名' : work.parentTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: YmFont.strong16,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                      color: c.text,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    _subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: YmFont.small12, color: c.text2),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 论坛行的 34px 首字方牌（与论坛首页的板块行同款）。
class _ForumTile extends StatelessWidget {
  const _ForumTile({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final first = title.isEmpty ? '帖' : title.characters.first;
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(YmRadius.ctrl),
      ),
      child: Text(
        first,
        style: TextStyle(
          fontSize: YmFont.body14,
          fontWeight: FontWeight.w700,
          color: c.textStrong,
        ),
      ),
    );
  }
}
