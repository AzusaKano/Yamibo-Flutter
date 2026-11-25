import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/http.dart';
import '../data/models.dart';
import '../design/tokens.dart';
import '../design/widgets/chip.dart';
import '../design/widgets/lists.dart';
import '../design/widgets/state_view.dart';
import '../design/widgets/top_bar.dart';
import '../design/widgets/work_row.dart';
import 'openers.dart';
import '../design/widgets/glyph.dart';
import '../design/pressable.dart';

/// 小说列表。排序值直接对齐站点表头（asc / desc 两个取值）：
/// 不加负号 = 升序、加负号 = 降序（2026-10-20 实测）。
class ListPage extends StatefulWidget {
  const ListPage({super.key, required this.title, this.q = 'all'});

  final String title;
  final String q;

  @override
  State<ListPage> createState() => _ListPageState();
}

class _ListPageState extends State<ListPage> {
  static const _sorts = <(String, String, String, String, bool)>[
    // key, label, asc, desc, 首次点选默认降序
    ('updated', '最近更新', 'updated_at', '-updated_at', true),
    ('title', '书名', 'workTitle', '-workTitle', false),
    ('author', '作者', 'uid', '-uid', false),
    ('status', '状态', 'nvStatus', '-nvStatus', false),
  ];

  String _sortKey = 'updated';
  bool _desc = true;

  final List<YmWork> _items = <YmWork>[];
  int _page = 0;
  int _total = 0;
  int _totalPages = 0;
  bool _loading = false;
  String? _error;

  String get _sortValue {
    final s = _sorts.firstWhere((e) => e.$1 == _sortKey);
    return _desc ? s.$4 : s.$3;
  }

  bool get _hasMore => _page > 0 && (_totalPages == 0 || _page < _totalPages);

  @override
  void initState() {
    super.initState();
    _load(1);
  }

  Future<void> _load(int next) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await fetchList(q: widget.q, page: next, sort: _sortValue);
      if (!mounted) return;
      setState(() {
        if (next == 1) _items.clear();
        _items.addAll(data.items);
        _page = data.page;
        _total = data.total;
        _totalPages = data.totalPages;
        if (next > 1 && data.items.isEmpty) _totalPages = data.page;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is YmHttpError ? e.message : '加载失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _changeSort(String key) {
    setState(() {
      if (_sortKey == key) {
        _desc = !_desc;
      } else {
        _sortKey = key;
        _desc = _sorts.firstWhere((e) => e.$1 == key).$5;
      }
      _items.clear();
      _page = 0;
      _total = 0;
      _totalPages = 0;
    });
    _load(1);
  }

  String get _subtitle {
    if (_loading && _total == 0) return '正在加载…';
    if (_total > 0) return '共 $_total 篇 · 每页 50 篇';
    return '数据来自 www.yamibo.com';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          YmTopBar(
            leading: const YmBackButton(),
            title: widget.title,
            subtitle: _subtitle,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 14, YmLayout.pagePad, 14),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final s in _sorts) ...[
                          YmChip(
                            style: YmChipStyle.pill,
                            pressKind: YmPressKind.solid,
                            label: s.$2,
                            active: _sortKey == s.$1,
                            onTap: () => _changeSort(s.$1),
                            trailing: _sortKey == s.$1
                                ? YmSortCaret(desc: _desc, color: Colors.white)
                                : null,
                          ),
                          if (s != _sorts.last) const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ),
                ),
                if (_items.isEmpty && _loading) const YmSkeletonRows(count: 6),
                if (_items.isEmpty && !_loading && _error != null)
                  YmStateView(
                    title: '列表加载失败',
                    desc: _error,
                    actionLabel: '重试',
                    onAction: () => _load(1),
                  ),
                if (_items.isEmpty && !_loading && _error == null)
                  const YmStateView(
                    title: '没有作品',
                    desc: '这个分类暂时没有内容',
                  ),
                if (_items.isNotEmpty)
                  YmCardList(
                    children: [
                      for (final work in _items)
                        YmWorkRow(
                          work: work,
                          onTap: () => openWork(context, id: work.id, title: work.title),
                        ),
                    ],
                  ),
                if (_items.isNotEmpty)
                  YmLoadMore(
                    loading: _loading,
                    hasMore: _hasMore,
                    doneText: '已全部加载 · $_total 篇',
                    onTap: () => _load(_page + 1),
                  ),
                if (_error != null && _items.isNotEmpty) YmTip(_error!),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
