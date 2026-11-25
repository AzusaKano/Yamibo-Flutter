import 'package:flutter/material.dart';

import '../../data/forum/forum_api.dart';
import '../../data/forum/forum_auth.dart' show ForumSession;
import '../../data/forum/forum_models.dart';
import '../../data/http.dart' show YmHttpError;
import '../../design/pressable.dart';
import '../../design/theme.dart' show YmScope;
import '../../design/tokens.dart';
import '../../design/widgets/chip.dart';
import '../../design/widgets/hscroll_fade.dart';
import '../../design/widgets/async_view.dart';
import '../../design/widgets/forum/forum_thread_row.dart';
import '../../design/widgets/lists.dart';
import '../../design/widgets/nav_icon.dart';
import '../../design/widgets/state_view.dart';
import '../../design/widgets/top_bar.dart';
import '../../design/ym_route.dart' show ymRoute;
import '../routes.dart';
import 'forum_login_page.dart';
import 'forum_recent.dart' show rememberForumBoardVisit;
import 'forum_web.dart' show openForumWeb, openForumWafVerifyPage;
import 'forum_thread_page.dart' show openForumThread;

/// B 板块页：排序胶囊（站点自己的五档）+ 置顶条 + 主题列表 + 加载更多。
/// 游客不可读的板块：站点 302 跳登录 → 显示「登录后使用」，不露白屏。
class ForumBoardPage extends StatefulWidget {
  const ForumBoardPage({super.key, required this.fid, required this.name});

  final String fid;
  final String name;

  @override
  State<ForumBoardPage> createState() => _ForumBoardPageState();
}

class _ForumBoardPageState extends State<ForumBoardPage> {
  /// 排序胶囊：label + 拼进 URL 的站点参数（从板块页真实锚点抄，别自己造）。
  static const _filters = <(String, String)>[
    ('全部', ''),
    ('最新', '&filter=lastpost&orderby=lastpost'),
    ('热门', '&filter=heat&orderby=heats'),
    ('新帖', '&orderby=dateline&filter=dateline'),
    ('精华', '&filter=digest&digest=1'),
  ];

  int _filterIndex = 0;

  /// 主题分类（站点 `#dhnavs_li`）。第 1 页返回什么就照什么画；
  /// 0 = 「全部」，不拼 typeid。分类与排序**互斥**（站点把两者塞进同一个 filter 参数）。
  List<ForumTypeTag> _typeTags = const <ForumTypeTag>[];
  int _typeIndex = 0;

  /// 子版块（站点「子版块」那一行）。大多数板块没有，所以是「有才画」。
  List<ForumSubBoard> _subBoards = const <ForumSubBoard>[];

  /// 置顶只在第 1 页有；翻页时保持不动。
  List<ForumThreadSummary> _pinned = <ForumThreadSummary>[];
  final List<ForumThreadSummary> _threads = <ForumThreadSummary>[];
  int _page = 0;
  int _totalPages = 0;
  bool _loading = false;
  bool _loginRequired = false;
  String? _error;

  /// 错误码（WAF → 错误态出「去网页过一次验证」；SITE_MESSAGE → 站方消息兜底态，
  /// 见 _load 的 catch）。阅读侧口径：错误分支只认码不猜内容。
  String? _errorCode;

  @override
  void initState() {
    super.initState();
    _load(1);
  }

  /// 拼进 URL 的筛选参数。
  ///
  /// ⚠ 站点的 `filter` 是一个槽位：排序用它（`filter=lastpost` / `heat` / `digest`），
  /// 分类也用它（`filter=typeid&typeid=N`）。**同时给会互相覆盖**，所以选分类时排序
  /// 必须复位、选排序时分类必须复位（见 [_changeType] / [_changeFilter]）。
  String get _extra {
    if (_typeIndex > 0 && _typeIndex <= _typeTags.length) {
      return '&filter=typeid&typeid=${_typeTags[_typeIndex - 1].typeid}';
    }
    return _filters[_filterIndex].$2;
  }

  Future<void> _load(int next) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _errorCode = null;
      _loginRequired = false;
    });
    try {
      final data = await fetchForumBoard(
        widget.fid,
        page: next,
        extra: _extra,
      );
      if (!mounted) return;
      setState(() {
        if (next == 1) {
          _pinned = data.threads.where((t) => t.pinned).toList();
          _threads.clear();
          // 子版块 / 分类条只在第 1 页重取（分类筛选后的页面照样印这两条，
          // 但筛选态下重取没有意义，也避免把「全部」冲掉）
          _subBoards = data.subBoards;
          _typeTags = data.typeTags;
          if (_typeIndex > _typeTags.length) _typeIndex = 0;
        }
        _threads.addAll(data.threads.where((t) => !t.pinned));
        _page = data.page;
        _totalPages = data.totalPages;
        if (next > 1 && data.threads.isEmpty) _totalPages = data.page;
      });
    } catch (e) {
      if (!mounted) return;
      if (e is YmHttpError && e.isLoginRequired) {
        setState(() => _loginRequired = true);
      } else {
        setState(() {
          _error = e is YmHttpError ? e.message : '加载失败';
          _errorCode = e is YmHttpError ? e.code : null;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// WAF 错误态唯一按钮「去验证」（借证与自动关页原理见
  /// forum_web.openForumWafVerifyPage）：打开网页壳拿新通行证自动关页，
  /// 返回后自动重试。
  Future<void> _openWafVerify() async {
    await openForumWafVerifyPage(context);
    if (mounted) _load(1);
  }

  void _changeFilter(int i) {
    // 排序与分类互斥：重新点排序就意味着离开分类
    if (i == _filterIndex && _typeIndex == 0) return;
    setState(() {
      _filterIndex = i;
      _typeIndex = 0;
      _pinned = <ForumThreadSummary>[];
      _threads.clear();
      _page = 0;
      _totalPages = 0;
    });
    _load(1);
  }

  /// 切主题分类（0 = 全部）。**再点一次已选中的那颗 = 取消**，回到全部。
  ///
  /// 用户口径（2026-11-17）：分类条不设「全部」按钮——多一颗胶囊占位、还跟站点的条子对不上；
  /// 取消靠「点自己」，与状态胶囊的 toggle 同一套手感。与排序互斥，见 [_extra]。
  void _changeType(int i) {
    final next = i == _typeIndex ? 0 : i;
    if (next == _typeIndex) return;
    setState(() {
      _typeIndex = next;
      _filterIndex = 0;
      _pinned = <ForumThreadSummary>[];
      _threads.clear();
      _page = 0;
      _totalPages = 0;
    });
    _load(1);
  }

  bool get _hasMore => _page > 0 && (_totalPages == 0 || _page < _totalPages);

  String get _subtitle {
    if (_loading && _page == 0) return '正在加载…';
    if (_totalPages > 0) return '共 $_totalPages 页';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          YmTopBar(
            leading: const YmBackButton(),
            title: widget.name,
            subtitle: _subtitle.isEmpty ? null : _subtitle,
            // 搜索入口（草稿 B 屏顶栏放大镜；板块页也印 nav-search）——
            // 直跳网页版版内搜索（mod=curforum&srhfid=板块id，站点自己的形状）；
            // 游客先过原生登录门（同首页口径）
            trailing: YmCircleButton(
              semanticLabel: '搜索本板块',
              onTap: () async {
                if (!ForumSession.loggedIn) {
                  await Navigator.of(context).push(ymRoute(const ForumLoginPage(), snapshot: false));
                  if (!ForumSession.loggedIn) return;
                }
                if (!context.mounted) return;
                openForumWeb(
                  context,
                  path: '/search.php?mod=curforum&srhfid=${widget.fid}&mobile=2',
                  title: '搜索：${widget.name}',
                );
              },
              icon: YmNavIcon(name: 'search', color: YmScope.of(context).colors.textStrong, size: 19),
            ),
          ),
          Expanded(
            child: _loginRequired && _threads.isEmpty
                ? ListView(children: [
                    YmLoginRequired(
                      desc: '「${widget.name}」需要登录论坛后查看。',
                      onLogin: () async {
                        await Navigator.of(context).push(ymRoute(const ForumLoginPage(), snapshot: false));
                        // 登录成功回来直接重取，不用退出去重进
                        if (ForumSession.loggedIn) _load(1);
                      },
                    ),
                  ])
                : ListView(
                    padding: const EdgeInsets.only(bottom: 8),
                    children: [
                      _buildSubBoards(),
                      _buildFilters(),
                      _buildTypes(),
                      if (_pinned.isNotEmpty) ...[
                        YmCardList(
                          children: [
                            for (final t in _pinned)
                              YmForumThreadRow(
                                thread: t,
                                compact: true,
                                onTap: t.tid.isEmpty
                                    ? null
                                    : () => openForumThread(context, t),
                              ),
                          ],
                        ),
                        const SizedBox(height: 14),
                      ],
                      if (_threads.isEmpty && _loading) const YmSkeletonRows(count: 6),
                      if (_threads.isEmpty && !_loading && _error != null) ...[
                        // 站方消息兜底（SITE_MESSAGE）：关站/维护/公告，摘站点原文、
                        // 中性标题、不做重试承诺。
                        // WAF：单按钮「去验证」收束（0.1.19 拍板），替代「重试」；
                        // 其余错误照旧「重试」
                        YmStateView(
                          title: _errorCode == 'SITE_MESSAGE' ? '论坛暂时无法访问' : '板块加载失败',
                          desc: _error,
                          actionLabel: _errorCode == 'SITE_MESSAGE'
                              ? null
                              : (_errorCode == 'WAF' ? '去验证' : '重试'),
                          onAction: _errorCode == 'WAF' ? _openWafVerify : () => _load(1),
                        ),
                      ],
                      if (_threads.isEmpty && !_loading && _error == null && _page > 0)
                        const YmStateView(
                          title: '这个板块还没有主题',
                        ),
                      if (_threads.isNotEmpty)
                        YmCardList(
                          children: [
                            for (final t in _threads)
                              YmForumThreadRow(
                                thread: t,
                                onTap: () => openForumThread(context, t),
                              ),
                          ],
                        ),
                      if (_threads.isNotEmpty)
                        YmLoadMore(
                          loading: _loading,
                          hasMore: _hasMore,
                          doneText: _totalPages > 0
                              ? '已是最后一页 · 共 $_totalPages 页'
                              : '已全部加载',
                          onTap: () => _load(_page + 1),
                        ),
                      if (_error != null && _threads.isNotEmpty) YmTip(_error!),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 子版块：一行文字链（`子版块 · 名字 ›`），不做成胶囊。
  ///
  /// 理由：胶囊是「筛同一种东西」的形态（排序 / 分类都是），而子版块是**换一个板块**，
  /// 做成第三排胶囊会被误读成第三个筛选器。站点把它排在列表正上方，我们上移到筛选条之前
  /// ——它决定的是「接下来看哪个板」，比「怎么筛」更靠前。
  Widget _buildSubBoards() {
    if (_subBoards.isEmpty) return const SizedBox.shrink();
    final c = YmScope.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 14, YmLayout.pagePad, 0),
      child: Wrap(
        spacing: 18,
        runSpacing: 4,
        children: [
          for (final s in _subBoards)
            YmPressable(
              // 整行可点用 row 档（T13）；热区 44 是触控红线，不是样子
              kind: YmPressKind.row,
              radius: BorderRadius.circular(YmRadius.chip),
              onTap: () {
                rememberForumBoardVisit(ForumBoardRef(fid: s.fid, name: s.name));
                ymPush(context, ForumBoardPage(fid: s.fid, name: s.name));
              },
              child: SizedBox(
                height: 44,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '子版块',
                      style: TextStyle(
                        fontSize: YmFont.sub13,
                        fontWeight: FontWeight.w700,
                        color: c.text2,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      s.name,
                      style: TextStyle(
                        fontSize: YmFont.body14,
                        fontWeight: FontWeight.w700,
                        color: c.brandInk,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '›',
                      style: TextStyle(fontSize: YmFont.body14, color: c.brandInk),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 主题分类条（站点 `#dhnavs_li`）。0 = 全部。
  ///
  /// 用 `line` 细边胶囊而不是排序那种实底大胶囊：两条筛选条上下相邻，
  /// 靠形态区分「排序（实底）/ 分类（细边）」，不至于看成一排。
  Widget _buildTypes() {
    if (_typeTags.isEmpty) return const SizedBox.shrink();
    final c = YmScope.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 0, YmLayout.pagePad, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 前置小标固定 44：与下行胶囊左缘对齐，「分类: 一组可选项」读得出来
          SizedBox(
            width: 44,
            child: Padding(
              padding: const EdgeInsets.only(top: 9),
              child: Text(
                '分类',
                style: TextStyle(
                  fontSize: YmFont.sub13,
                  fontWeight: FontWeight.w700,
                  color: c.text2,
                ),
              ),
            ),
          ),
          Expanded(
            // 横滑条必须带右缘渐隐（YmHScrollFade）：论坛一个板最多十几个分类，
            // 溢出时没有渐隐就看不出后面还有；到最右端渐隐自动收起。
            child: YmHScrollFade(
              padding: const EdgeInsets.all(3),
              spacing: 8,
              // 选中项滚到可视区中间（与作品搜索的类别条同一套口径）
              focusIndex: _typeIndex > 0 ? _typeIndex - 1 : null,
              children: [
                for (var i = 0; i < _typeTags.length; i++)
                  YmChip(
                    style: YmChipStyle.line,
                    pressKind: YmPressKind.solid,
                    label: _typeTags[i].name,
                    active: _typeIndex == i + 1,
                    onTap: () => _changeType(i + 1),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(YmLayout.pagePad, 14, YmLayout.pagePad, 14),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < _filters.length; i++) ...[
              // 排序条是大胶囊 44（工程口径：排序/筛选/页内 tab 一律 solid 大胶囊）；
              // compact 34 是「最近访问」那类小胶囊的档，别用在这里
              YmChip(
                style: YmChipStyle.pill,
                pressKind: YmPressKind.solid,
                label: _filters[i].$1,
                active: _filterIndex == i,
                onTap: () => _changeFilter(i),
              ),
              if (i != _filters.length - 1) const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }
}
