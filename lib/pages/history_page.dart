import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/cache/ym_cache_store.dart' show YmCache;
import '../data/library.dart';
import '../design/widgets/lists.dart';
import '../design/widgets/rows.dart';
import '../design/widgets/selection.dart';
import '../design/widgets/sheet.dart';
import '../design/widgets/state_view.dart';
import '../design/widgets/top_bar.dart';
import 'openers.dart';

/// 历史记录。版式对齐 uni `pages/history/history.vue`：
/// 顶栏副行 = N 条；提示条；行内 = 封面 + 书名 + 读到哪 + 进度 + 类型/作者。
///
/// 管理走 T22 选择模式：右上「选择 / 取消」，长按进选择，底部条全选 / 删除；
/// 单条长按删除不再直接弹框（管理动作收进选择模式）。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  bool _selecting = false;
  final Set<String> _sel = <String>{};

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
    setState(() {
      _selecting = true;
      _sel.add(id);
    });
  }

  void _selectAll(List<YmHistoryEntry> entries) {
    setState(() {
      if (_sel.length == entries.length) {
        _sel.clear();
        _selecting = false;
      } else {
        _sel
          ..clear()
          ..addAll(entries.map((e) => e.id));
      }
    });
  }

  Future<void> _removeSelected() async {
    final ids = _sel.toList();
    if (ids.isEmpty) return;
    final ok = await showYmConfirm(
      context,
      title: '删除记录',
      content: '删除选中的 ${ids.length} 条阅读记录？进度会一起删除。',
      confirmText: '删除',
      danger: true,
    );
    if (ok != true || !mounted) return;
    YmLibrary.instance.removeHistoryItems(ids);
    _exitSelect();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: YmLibrary.instance,
        builder: (context, _) {
          final entries = YmLibrary.instance.history;
          final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
          return Stack(
            fit: StackFit.expand,
            children: [
              Column(
                children: [
                  YmTopBar(
                    leading: const YmBackButton(),
                    title: '历史记录',
                    subtitle: '${entries.length} 条',
                    trailing: entries.isEmpty
                        ? null
                        : YmTopBarAction(
                            label: _selecting ? '取消' : '选择',
                            onTap: _selecting
                                ? _exitSelect
                                : () => setState(() => _selecting = true),
                          ),
                  ),
                  Expanded(
                    child: entries.isEmpty
                        ? ListView(
                            children: [
                              YmStateView(
                                title: '还没有阅读记录',
                                desc: '读过的作品会自动出现在这里。',
                                actionLabel: '去首页找书',
                                onAction: () => rootTab.value = 0,
                              ),
                            ],
                          )
                        : ListView(
                            // 顶栏线到第一条之间留 14（对齐首页 / 列表页）
                            padding: EdgeInsets.only(
                              top: 14,
                              bottom: _selecting
                                  ? YmSelectMetrics.pageBottomInset + safeBottom
                                  : 10,
                            ),
                            children: [
                              YmCardList(
                                children: [
                                  for (final e in entries)
                                    YmHistoryRow(
                                      entry: e,
                                      cover: YmLibrary.instance.coverOf(
                                        e.id,
                                        e.kind,
                                        cover: e.cover,
                                      ),
                                      // 本机封面（离线保存过才有）
                                      coverLocal: YmCache.instance
                                          .peekCoverFile(e.kind, e.id),
                                      selectionMode: _selecting,
                                      selected: _sel.contains(e.id),
                                      onTap: () {
                                        if (_selecting) {
                                          _toggleSelect(e.id);
                                          return;
                                        }
                                        openWork(
                                          context,
                                          id: e.id,
                                          title: e.title,
                                          manga: e.kind == 'manga',
                                        );
                                      },
                                      onLongPress: () {
                                        if (_selecting) {
                                          _toggleSelect(e.id);
                                        } else {
                                          _enterSelect(e.id);
                                        }
                                      },
                                    ),
                                ],
                              ),
                            ],
                          ),
                  ),
                ],
              ),
              if (_selecting)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: YmSelectBar(
                    countText: '已选 ${_sel.length} 条',
                    leading: YmSelectAction(
                      label: _sel.length == entries.length ? '取消全选' : '全选',
                      kind: YmSelectActionKind.selectAll,
                      onTap: () => _selectAll(entries),
                    ),
                    trailing: YmSelectAction(
                      label: '删除',
                      kind: YmSelectActionKind.delete,
                      enabled: _sel.isNotEmpty,
                      onTap: _removeSelected,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
