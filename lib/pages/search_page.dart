import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/http.dart';
import '../data/models.dart';
import '../data/session.dart';
import '../design/pressable.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../design/widgets/async_view.dart';
import '../design/widgets/chip.dart';
import '../design/widgets/hscroll_fade.dart';
import '../design/widgets/lists.dart';
import '../design/widgets/state_view.dart';
import '../design/widgets/top_bar.dart';
import '../design/widgets/work_row.dart';
import 'login_page.dart';
import 'openers.dart';
import 'routes.dart';
import '../design/widgets/glyph.dart';

/// 搜索 / 类别。版式对齐 uni `pages/search/search.vue`：
/// 顶栏「搜索 / 类别」→ 作品名单框 + 高级搜索折叠条 → 类别紧凑胶囊 → 结果。
/// 未登录 = 整屏「登录后使用」，不露表单。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  static const _types = <String>[
    '全部', '校园', '都市', '玄幻', '武侠', '宫廷', '穿越', '重生', '悬疑', '搞笑',
    '科幻', '历史', '奇幻', '种田', '娱乐圈', '现代', '古代', '短篇', '正剧', '恐怖',
  ];
  static const _statuses = <(String, String)>[
    ('全部状态', ''),
    ('连载中', '0'),
    ('已完结', '1'),
    ('暂停', '2'),
  ];
  static const _workCats = <(String, String)>[
    ('全部分类', ''),
    ('原创小说', '1'),
    ('二次元同人', '2'),
    ('三次元同人', '3'),
  ];

  final _keyword = TextEditingController();
  final _author = TextEditingController();
  String _type = '全部';
  String _status = '全部状态';
  String _workCat = '全部分类';
  bool _advanced = false;
  bool _catOpen = false;

  bool _searched = false;
  bool _loading = false;
  bool _needLogin = false;
  String? _error;

  String _sortKey = 'updated';
  bool _desc = true;

  final List<YmWork> _items = <YmWork>[];
  int _page = 0;
  int _total = 0;
  int _totalPages = 0;

  @override
  void initState() {
    super.initState();
    // 登录门上的「去登录」回来后要自动展开表单（uni 口径：登录前整屏提示）
    YmSession.account.addListener(_onAccount);
  }

  @override
  void dispose() {
    YmSession.account.removeListener(_onAccount);
    _keyword.dispose();
    _author.dispose();
    super.dispose();
  }

  void _onAccount() {
    if (mounted) setState(() {});
  }

  bool get _gated => !YmSession.loggedIn;

  int get _advancedCount =>
      (_author.text.trim().isNotEmpty ? 1 : 0) +
      (_status.isEmpty ? 0 : 1) +
      (_workCat.isEmpty ? 0 : 1);

  String get _sortValue {
    // ⚠ 搜索结果页符号与列表页**相反**：不加负号 = 降序（2026-10-20 实测）
    if (_sortKey == 'hit') return _desc ? 'workHit' : '-workHit';
    return _desc ? 'updated_at' : '-updated_at';
  }

  bool get _hasMore => _page > 0 && (_totalPages == 0 || _page < _totalPages);

  Future<void> _search({int next = 1}) async {
    FocusScope.of(context).unfocus();
    if (_loading && next > 1) return;
    setState(() {
      _searched = true;
      _loading = true;
      _error = null;
      _needLogin = false;
      if (next == 1) {
        _items.clear();
        _page = 0;
        _total = 0;
        _totalPages = 0;
      }
    });
    try {
      final data = await searchAdvanced(
        keyword: _keyword.text.trim(),
        author: _author.text.trim(),
        cat: _workCats.firstWhere((e) => e.$1 == _workCat).$2,
        status: _statuses.firstWhere((e) => e.$1 == _status).$2,
        type: _type == '全部' ? '' : _type,
        page: next,
        sort: _sortValue,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(data.items);
        _page = data.page;
        _total = data.total;
        _totalPages = data.totalPages;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (e is YmHttpError && e.isLoginRequired) {
          _needLogin = true;
        } else {
          _error = e is YmHttpError ? e.message : '加载失败';
        }
      });
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
        _desc = true;
      }
    });
    if (_searched) _search();
  }

  void _pickType(String type) {
    setState(() => _type = type);
    _search();
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        Expanded(
          child: _gated || _needLogin
              ? YmLoginRequired(
                  desc: '搜索作品与作者需要登录百合会账号',
                  onLogin: () => ymPush(context, const LoginPage()),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 10),
                  children: [
                    _searchBox(context),
                    _advToggle(context),
                    if (_advanced) _advPanel(context),
                    _catBar(context),
                    if (_searched) ..._results(context),
                  ],
                ),
        ),
      ],
    );

    if (!widget.embedded) return body;

    return Column(
      children: [
        const YmTopBar(title: '搜索 / 类别'),
        Expanded(child: body),
      ],
    );
  }

  Widget _searchBox(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(YmLayout.pagePad, 14, YmLayout.pagePad, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      constraints: const BoxConstraints(minHeight: 44),
      decoration: BoxDecoration(
        color: c.inputOnBg,
        borderRadius: BorderRadius.circular(YmRadius.ctrl),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _keyword,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              style: TextStyle(fontSize: YmFont.body14, color: c.text),
              cursorColor: c.brandInk,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '作品名称',
                hintStyle: TextStyle(fontSize: YmFont.body14, color: c.text2),
              ),
            ),
          ),
          YmPressable(
            kind: YmPressKind.row,
            radius: BorderRadius.circular(YmRadius.chip),
            onTap: () => _search(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
              child: Text(
                '搜索',
                style: TextStyle(
                  fontSize: YmFont.small12,
                  fontWeight: FontWeight.w700,
                  color: c.brandInk,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _advToggle(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(YmLayout.pagePad, 0, YmLayout.pagePad, 10),
      child: YmPressable(
        kind: YmPressKind.row,
        baseColor: _advanced ? c.brandTint : c.fill,
        radius: BorderRadius.circular(YmRadius.ctrl),
        onTap: () => setState(() => _advanced = !_advanced),
        child: SizedBox(
          height: 40,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '高级搜索',
                style: TextStyle(
                  fontSize: YmFont.small12,
                  fontWeight: FontWeight.w700,
                  color: _advanced ? c.brandInk : c.text2,
                ),
              ),
              if (_advancedCount > 0) ...[
                const SizedBox(width: 6),
                Container(
                  constraints: const BoxConstraints(minWidth: 16),
                  height: 16,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.brand,
                    borderRadius: BorderRadius.circular(YmRadius.pill),
                  ),
                  child: Text(
                    '$_advancedCount',
                    // 计数角标：与资产包实心圆点徽标同档（SlateBadge trip circle：
                    // tag10·w800，chips.dart），故保留显式 800。
                    style: TextStyle(
                      fontSize: YmFont.tag10,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 6),
              _AdvChevron(open: _advanced, color: _advanced ? c.brandInk : c.text2),
            ],
          ),
        ),
      ),
    );
  }

  Widget _advPanel(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(YmLayout.pagePad, 0, YmLayout.pagePad, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(YmRadius.box),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _advLabel(c, '作者'),
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: c.inputOnBg,
              borderRadius: BorderRadius.circular(YmRadius.ctrl),
            ),
            // 定高盒子里 TextField 会被顶到上沿（Container 不居中放子项）⇒ 输入位置偏高。
            // 套一层 Row，靠交叉轴居中把输入框摆到 44 高的中间（与上方搜索框同一做法）。
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _author,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    style: TextStyle(fontSize: YmFont.body14, color: c.text),
                    cursorColor: c.brandInk,
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '作者昵称',
                      hintStyle: TextStyle(fontSize: YmFont.body14, color: c.text2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _advLabel(c, '状态'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in _statuses)
                YmChip(
                  style: YmChipStyle.pill,
                  pressKind: YmPressKind.solid,
                  label: s.$1,
                  active: _status == s.$1,
                  onTap: () {
                    setState(() => _status = s.$1);
                    _search();
                  },
                ),
            ],
          ),
          const SizedBox(height: 14),
          _advLabel(c, '作品分类'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in _workCats)
                YmChip(
                  style: YmChipStyle.pill,
                  pressKind: YmPressKind.solid,
                  label: s.$1,
                  active: _workCat == s.$1,
                  onTap: () {
                    setState(() => _workCat = s.$1);
                    _search();
                  },
                ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: YmPressable(
              kind: YmPressKind.solid,
              baseColor: c.brand,
              radius: BorderRadius.circular(YmRadius.ctrl),
              onTap: () {
                setState(() => _advanced = false);
                _search();
              },
              child: Center(
                child: Text(
                  '搜索',
                  style: TextStyle(
                    fontSize: YmFont.body14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _advLabel(YmColors c, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: TextStyle(
            fontSize: YmFont.small12,
            fontWeight: FontWeight.w700,
            color: c.text2,
          ),
        ),
      );

  Widget _catBar(BuildContext context) {
    final c = YmScope.of(context).colors;
    final selected = _types.indexOf(_type);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(YmLayout.pagePad, 0, YmLayout.pagePad, 10),
          child: Row(
            children: [
              Expanded(
                // 类别条在大字体档/窄屏下会超出一屏，右缘给渐隐（页面底 ⇒ 实色端取 --bg）
                child: YmHScrollFade(
                  // 资产包 .cat-scroll-inner 的 padding: 3px（上下给 34px 胶囊留出 40px 行高）
                  padding: const EdgeInsets.all(3),
                  spacing: 7,
                  // 选中项自动滚到可视区中间（与选站弹层的线路胶囊同一套口径）
                  focusIndex: selected >= 0 ? selected : null,
                  children: [
                    for (final t in _types)
                      YmChip(
                        pressKind: YmPressKind.solid,
                        label: t,
                        active: _type == t,
                        style: YmChipStyle.line,
                        onTap: () => _pickType(t),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              YmPressable(
                kind: YmPressKind.neutral,
                baseColor: c.pillsBg,
                radius: BorderRadius.circular(17),
                onTap: () => setState(() => _catOpen = !_catOpen),
                child: SizedBox(
                  width: 34,
                  height: 34,
                  // T18-04 具名档（14 盒 / 屏幕线宽 2，墨迹 9×5.5）；收起态翻 180°。
                  child: Center(
                    child: YmGlyph.lineExpandChevron(
                      color: c.textStrong,
                      rotate: _catOpen ? 3.141592653589793 : 0,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_catOpen)
          Container(
            margin: const EdgeInsets.fromLTRB(YmLayout.pagePad, 0, YmLayout.pagePad, 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(YmRadius.box),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 2, bottom: 8),
                  child: Text(
                    '选择类别',
                    // 类别面板标题：与资产包 SlateCategoryBar 的面板标题逐值一致——
                    // 「13 / 800 / --text-2、margin 0 2 8」（composites/category_bar.dart，
                    // 第二宿主 app.css），故保留 800。
                    style: TextStyle(
                      fontSize: YmFont.sub13,
                      fontWeight: FontWeight.w800,
                      color: c.text2,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(3, 2, 3, 4),
                  child: Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final t in _types)
                        YmChip(
                          pressKind: YmPressKind.solid,
                          label: t,
                          active: _type == t,
                          style: YmChipStyle.line,
                          onTap: () => _pickType(t),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _results(BuildContext context) {
    final c = YmScope.of(context).colors;
    final head = _loading && _items.isEmpty
        ? '正在搜索…'
        : '共 ${_total > 0 ? _total : _items.length} 条';

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 4, YmLayout.pagePad, 10),
        child: Row(
          children: [
            YmChip(
              style: YmChipStyle.pill,
              pressKind: YmPressKind.solid,
              label: '最近更新',
              active: _sortKey == 'updated',
              onTap: () => _changeSort('updated'),
              trailing: _sortKey == 'updated'
                  ? YmSortCaret(desc: _desc, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 8),
            YmChip(
              style: YmChipStyle.pill,
              pressKind: YmPressKind.solid,
              label: '热度',
              active: _sortKey == 'hit',
              onTap: () => _changeSort('hit'),
              trailing: _sortKey == 'hit'
                  ? YmSortCaret(desc: _desc, color: Colors.white)
                  : null,
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 0, YmLayout.pagePad, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                head,
                style: TextStyle(fontSize: YmFont.small12, color: c.text2),
              ),
            ),
            if (_totalPages > 1)
              Text(
                '第 $_page / $_totalPages 页',
                style: TextStyle(fontSize: YmFont.small12, color: c.text3),
              ),
          ],
        ),
      ),
      if (_loading && _items.isEmpty) const YmSkeletonRows(count: 5),
      if (_items.isEmpty && !_loading && _error != null)
        YmStateView(
          title: '搜索失败',
          desc: _error,
          actionLabel: '重试',
          onAction: () => _search(),
        ),
      if (_items.isEmpty && !_loading && _error == null)
        const YmStateView(
          title: '没有找到结果',
          desc: '换个关键词或类别再试。',
        ),
      if (_items.isNotEmpty)
        YmCardList(
          children: [
            for (final w in _items)
              YmWorkRow(
                work: w,
                onTap: () => openWork(context, id: w.id, title: w.title),
              ),
          ],
        ),
      if (_items.isNotEmpty)
        YmLoadMore(
          loading: _loading,
          hasMore: _hasMore,
          doneText: '没有更多了',
          onTap: () => _search(next: _page + 1),
        ),
      if (_error != null && _items.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: YmTip(_error!),
        ),
    ];
  }
}

/// 高级搜索折叠箭头：自绘，形状与资产包 `.adv-chev` 一致。
///
/// `.adv-chev` 是 7px 方块只画右 + 下两条 1.5px 边，闭合时 45°（= ▾），展开时 -135°（= ▴），
/// 位移 -3px / +3px。不用 Material 图标：那套箭头笔画更粗、字号也压不住 40px 的条。
class _AdvChevron extends StatelessWidget {
  const _AdvChevron({required this.open, required this.color});

  final bool open;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // uni 版是 `margin-top: ±3px`，但它挂在**居中**的 flex 项上 —— 负/正外边距只让它移动**一半**
    // （居中按 margin box 算），所以视觉位移是 ±1.5px。这里按实测口径取 1.5：
    // 7×7 方块转到 45° 后墨迹是 9.9×4.95 的 V，墨迹中线偏离盒心 ±2.475，
    // 配 ±1.5 后两种状态都落在**中线下方/上方约 1px**，与 uni 版一致（原来 ±3 会整体偏高 1.5px）。
    return Transform.translate(
      offset: Offset(0, open ? 1.5 : -1.5),
      child: AnimatedRotation(
        turns: open ? -0.375 : 0.125,
        duration: YmMotion.chevron,
        curve: Curves.easeOut,
        child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(color: color, width: 1.5),
              bottom: BorderSide(color: color, width: 1.5),
            ),
          ),
        ),
      ),
    );
  }
}
