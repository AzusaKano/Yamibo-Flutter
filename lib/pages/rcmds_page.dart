import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/http.dart';
import '../data/models.dart';
import '../data/session.dart';
import '../design/widgets/async_view.dart';
import '../design/tokens.dart';
import '../design/widgets/chip.dart';
import '../design/widgets/lists.dart';
import '../design/widgets/rows.dart';
import '../design/widgets/state_view.dart';
import '../design/widgets/top_bar.dart';
import 'login_page.dart';
import 'openers.dart';
import 'routes.dart';
import '../design/widgets/glyph.dart';
import '../design/pressable.dart';

/// 编辑推荐（需登录）。对齐 uni `pages/rcmds/rcmds.vue`：
/// 固定 10 条一页；未登录不露排序；行内 = 书名 + 推荐语 + 推荐时间。
class RcmdsPage extends StatefulWidget {
  const RcmdsPage({super.key, required this.manga});

  final bool manga;

  @override
  State<RcmdsPage> createState() => _RcmdsPageState();
}

class _RcmdsPageState extends State<RcmdsPage> {
  final ValueNotifier<String> _sub = ValueNotifier<String>('正在加载…');
  String _sortKey = 'created';
  bool _desc = true;

  final List<YmRcmdItem> _items = <YmRcmdItem>[];
  int _page = 0;
  int _total = 0;
  int _totalPages = 0;
  bool _loading = false;
  bool _needLogin = false;
  String? _error;

  @override
  void dispose() {
    _sub.dispose();
    super.dispose();
  }

  String get _sortValue {
    if (_sortKey == 'title') return _desc ? '-title' : 'title';
    return _desc ? '-created_at' : 'created_at';
  }

  String get _unit => widget.manga ? '部' : '篇';

  bool get _hasMore => _page > 0 && (_totalPages == 0 || _page < _totalPages);

  @override
  void initState() {
    super.initState();
    _load(1);
  }

  void _syncSub() {
    final text = _needLogin
        ? '登录后查看'
        : (_loading && _total == 0)
            ? '正在加载…'
            : _total > 0
                ? '共 $_total $_unit · 每页 10 $_unit'
                : '编辑们挑的作品';
    if (_sub.value != text) _sub.value = text;
  }

  Future<void> _load(int next) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    _syncSub();
    try {
      final data = await fetchRcmds(
        kind: widget.manga ? 'manga' : 'novel',
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
      if (mounted) {
        setState(() => _loading = false);
        _syncSub();
      }
    }
  }

  void _pickSort(String key) {
    setState(() {
      if (_sortKey == key) {
        _desc = !_desc;
      } else {
        _sortKey = key;
        _desc = key == 'created';
      }
      _items.clear();
      _page = 0;
      _total = 0;
      _totalPages = 0;
    });
    _load(1);
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
              title: widget.manga ? '漫画编辑推荐' : '编辑推荐',
              subtitle: sub,
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 8),
              children: [
                // 未登录不露排序：内容都还没拿到
                if (!_needLogin && YmSession.loggedIn)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 14, YmLayout.pagePad, 10),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          YmChip(
                            style: YmChipStyle.pill,
                            pressKind: YmPressKind.solid,
                            label: '推荐时间',
                            active: _sortKey == 'created',
                            onTap: () => _pickSort('created'),
                            trailing: _sortKey == 'created'
                                ? YmSortCaret(desc: _desc, color: Colors.white)
                                : null,
                          ),
                          const SizedBox(width: 8),
                          YmChip(
                            style: YmChipStyle.pill,
                            pressKind: YmPressKind.solid,
                            label: '书名',
                            active: _sortKey == 'title',
                            onTap: () => _pickSort('title'),
                            trailing: _sortKey == 'title'
                                ? YmSortCaret(desc: _desc, color: Colors.white)
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_needLogin)
                  YmLoginRequired(
                    desc: '编辑推荐需要登录百合会账号后查看。',
                    onLogin: () => ymPush(context, const LoginPage()),
                  ),
                if (_items.isEmpty && _loading) const YmSkeletonRows(count: 6),
                if (_items.isEmpty && !_loading && !_needLogin && _error != null)
                  YmStateView(
                    title: '加载失败',
                    desc: _error,
                    actionLabel: '重试',
                    onAction: () => _load(1),
                  ),
                if (_items.isEmpty && !_loading && !_needLogin && _error == null)
                  const YmStateView(
                    title: '还没有推荐',
                    desc: '编辑们暂时没有新推荐',
                  ),
                if (_items.isNotEmpty)
                  YmCardList(
                    children: [
                      for (final item in _items)
                        YmRcmdRow(
                          item: item,
                          onTap: () => openWork(
                            context,
                            id: item.id,
                            title: item.title,
                            manga: widget.manga,
                          ),
                        ),
                    ],
                  ),
                if (_items.isNotEmpty)
                  YmLoadMore(
                    loading: _loading,
                    hasMore: _hasMore,
                    doneText: '已全部加载 · $_total $_unit',
                    onTap: () => _load(_page + 1),
                  ),
                if (_error != null && _items.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: YmTip(_error!),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
