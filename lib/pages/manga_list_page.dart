import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/http.dart';
import '../data/models.dart';
import '../design/widgets/async_view.dart';
import '../design/tokens.dart';
import '../design/widgets/chip.dart';
import '../design/widgets/lists.dart';
import '../design/widgets/state_view.dart';
import '../design/widgets/top_bar.dart';
import '../design/widgets/work_row.dart';
import 'login_page.dart';
import 'openers.dart';
import 'routes.dart';
import '../design/widgets/glyph.dart';
import '../design/pressable.dart';

/// 漫画列表 / 分类。
/// - 分类桶：`bucket` = ''（全部）/ 4（原创）/ 6（同人）/ finish / signed → `/manga/list`
/// - 作品类型：`tag` = 翻页漫画 / 条漫 / … → `/search/type?type=3`，**需要登录**
class MangaListPage extends StatefulWidget {
  const MangaListPage({
    super.key,
    this.title = '全部作品',
    this.initialBucket = '',
    this.initialTag = '',
  });

  final String title;
  final String initialBucket;
  final String initialTag;

  @override
  State<MangaListPage> createState() => _MangaListPageState();
}

class _MangaListPageState extends State<MangaListPage> {
  late final String _bucket = widget.initialBucket;
  String _sortKey = 'updated';
  bool _desc = true;

  final List<YmManga> _items = <YmManga>[];
  int _page = 0;
  int _total = 0;
  int _totalPages = 0;
  bool _loading = false;
  String? _error;
  bool _needLogin = false;

  String get _sortValue {
    if (_sortKey == 'title') return _desc ? '-workTitle' : 'workTitle';
    return _desc ? '-updated_at' : 'updated_at';
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
      final data = await fetchMangaList(
        bucket: _bucket,
        tag: widget.initialTag,
        page: next,
        sort: _sortValue,
      );
      if (!mounted) return;
      setState(() {
        _needLogin = false;
        if (next == 1) _items.clear();
        _items.addAll(data.items);
        _page = data.page;
        _total = data.total;
        _totalPages = data.totalPages;
        if (next > 1 && data.items.isEmpty) _totalPages = data.page;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (e is YmHttpError && e.isLoginRequired) {
          _needLogin = true;
          _items.clear();
        } else {
          _error = e is YmHttpError ? e.message : '加载失败';
        }
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _pickSort(String key) {
    setState(() {
      if (_sortKey == key) {
        _desc = !_desc;
      } else {
        _sortKey = key;
        _desc = key == 'updated';
      }
      _items.clear();
      _page = 0;
      _total = 0;
      _totalPages = 0;
    });
    _load(1);
  }

  String get _subtitle {
    if (_total > 0) return '共 $_total 部';
    return _loading ? '正在加载…' : '漫画';
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
                  child: Row(
                    children: [
                      YmChip(
                        style: YmChipStyle.pill,
                        pressKind: YmPressKind.solid,
                        label: '最近更新',
                        active: _sortKey == 'updated',
                        onTap: () => _pickSort('updated'),
                        trailing: _sortKey == 'updated'
                            ? YmSortCaret(desc: _desc, color: Colors.white)
                            : null,
                      ),
                      const SizedBox(width: 8),
                      YmChip(
                        style: YmChipStyle.pill,
                        pressKind: YmPressKind.solid,
                        label: '漫画名',
                        active: _sortKey == 'title',
                        onTap: () => _pickSort('title'),
                        trailing: _sortKey == 'title'
                            ? YmSortCaret(desc: _desc, color: Colors.white)
                            : null,
                      ),
                    ],
                  ),
                ),
                if (_needLogin)
                  YmLoginRequired(
                    desc: '登录百合会账号后可查看这个分类。',
                    onLogin: () => ymPush(context, const LoginPage()),
                  ),
                if (_items.isEmpty && _loading) const YmSkeletonRows(count: 6),
                if (_items.isEmpty && !_loading && !_needLogin && _error != null)
                  YmStateView(
                    title: '列表加载失败',
                    desc: _error,
                    actionLabel: '重试',
                    onAction: () => _load(1),
                  ),
                if (_items.isEmpty && !_loading && !_needLogin && _error == null)
                  const YmStateView(title: '这个分类还没有作品'),
                if (_items.isNotEmpty)
                  YmCardList(
                    children: [
                      for (final item in _items)
                        YmMangaRow(
                          item: item,
                          onTap: () => openWork(context, id: item.id, title: item.title, manga: true),
                        ),
                    ],
                  ),
                if (_items.isNotEmpty)
                  YmLoadMore(
                    loading: _loading,
                    hasMore: _hasMore,
                    doneText: '没有更多了',
                    onTap: () => _load(_page + 1),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
