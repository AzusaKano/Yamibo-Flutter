import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import '../../data/forum/forum_api.dart';
import '../../data/forum/forum_auth.dart' show ForumSession;
import '../../data/forum/forum_models.dart';
import '../../data/forum/forum_user.dart';
import '../../data/http.dart' show YmHttpError;
import '../../design/pressable.dart';
import '../../design/theme.dart';
import '../../design/tokens.dart';
import '../../design/widgets/async_view.dart';
import '../../design/widgets/forum/forum_profile_head.dart';
import '../../design/widgets/forum/forum_thread_row.dart';
import '../../design/widgets/lists.dart';
import '../../design/widgets/top_bar.dart';
import '../../design/ym_route.dart' show ymRoute;
import 'forum_login_page.dart';
import 'forum_thread_page.dart' show openForumThread;
import 'forum_web.dart' show openForumWeb, openForumWafVerifyPage;

/// 个人资料页（`home.php?mod=space&uid=N&do=profile&mobile=2`）。
///
/// [uid] 为空 = 我自己（用登录态里的 uid）。
///
/// 一屏东西全部来自站点：头卡（名字 / 用户组 / 最后访问）、三格、签名、
/// 资料表、「TA 的主题」。**拿不到就不画**——缺一格少一格、缺一行少一行，
/// 不印 `-`、不印「暂无」、不补字段（站点资料页本来就没有帖子数 / 精华数）。
///
/// 「TA 的主题」每页 20 条（站点粒度），滚到底**自动**续一页；站点不给总页数，
/// 所以没有页码、没有「共 N 页」，翻到底就安静停下。
class ForumProfilePage extends StatefulWidget {
  const ForumProfilePage({super.key, this.uid = ''});

  final String uid;

  @override
  State<ForumProfilePage> createState() => _ForumProfilePageState();
}

class _ForumProfilePageState extends State<ForumProfilePage> {
  /// 距底多少像素开始续载（与帖子页同一数值，别另调一套）。
  static const double _loadMoreThreshold = 600;

  final GlobalKey<YmAsyncState<_ProfileBundle>> _asyncKey =
      GlobalKey<YmAsyncState<_ProfileBundle>>();
  final GlobalKey _threadsKey = GlobalKey();
  final ScrollController _scroll = ScrollController();

  /// 第 2 页起追加的行。第一页不复制进来（它跟着 bundle 走）。
  final List<ForumThreadSummary> _more = <ForumThreadSummary>[];

  /// 已追加的页数（0 = 只有第一页）。
  int _morePages = 0;

  /// null = 沿用第一页的结论。
  bool? _hasMoreOverride;

  bool _loadingMore = false;
  String? _moreError;
  String? _moreErrorCode;

  /// 当前 bundle 的身份：换了一份（登录回来重取）就把追加态清空。
  _ProfileBundle? _seen;
  String _threadsUid = '';

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<_ProfileBundle> _load() async {
    final profile = await fetchForumProfile(uid: widget.uid);
    ForumUserThreads? threads;
    try {
      threads = await fetchForumProfileThreads(
        profile.uid.isNotEmpty ? profile.uid : widget.uid,
      );
    } catch (_) {
      // 主题拿不到就当没有：资料本身是真的，不该被这一块拖成整页报错
      threads = null;
    }
    return _ProfileBundle(profile: profile, threads: threads);
  }

  /// 换 bundle 就重置续载游标（只在 build 里调用，直接赋值、不 setState）。
  void _adopt(_ProfileBundle bundle) {
    if (identical(_seen, bundle)) return;
    _seen = bundle;
    _more.clear();
    _morePages = 0;
    _hasMoreOverride = null;
    _loadingMore = false;
    _moreError = null;
    _moreErrorCode = null;
    _threadsUid = bundle.profile.uid.isNotEmpty
        ? bundle.profile.uid
        : widget.uid;
    _fillViewportIfNeeded();
  }

  bool get _hasMore => _hasMoreOverride ?? (_seen?.threads?.hasNext ?? false);

  int get _loadedPage => 1 + _morePages;

  /// 登录门回来重取：YmAsync 只监听阅读侧账号，论坛登录得自己喊一次。
  Future<void> _openLogin() async {
    await Navigator.of(context).push(
      ymRoute(const ForumLoginPage(), snapshot: false),
    );
    if (mounted) _asyncKey.currentState?.reload();
  }

  void _toThreads() {
    final anchor = _threadsKey.currentContext;
    if (anchor == null) return;
    Scrollable.ensureVisible(
      anchor,
      duration: YmMotion.screen,
      curve: YmMotion.screenCurve,
    );
  }

  void _openWeb(String path, String title) {
    openForumWeb(context, path: path, title: title);
  }

  /* ------------------------------ 续载 ------------------------------ */

  /// 触底续载：与帖子页（`forum_thread_page.dart`）**同一套**判定，别自创。
  ///
  /// 只认 `UserScrollNotification`（程序化滚动恒 idle，用它才不会首屏连环触发），
  /// 方向 `reverse`（⚠ 枚举与直觉相反：reverse = 往列表深处滚），
  /// 且距底不足 [_loadMoreThreshold]。
  bool _onScroll(ScrollNotification n) {
    if (n is! UserScrollNotification) return false;
    if (n.direction != ScrollDirection.reverse) return false;
    _maybeLoadMore(n.metrics);
    return false;
  }

  void _maybeLoadMore(ScrollMetrics metrics) {
    if (_loadingMore || !_hasMore) return;
    // 上一次失败了就等用户点「重试」，别在滚动里连环重试
    if (_moreError != null) return;
    if (metrics.pixels <= metrics.maxScrollExtent - _loadMoreThreshold) return;
    unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final next = _loadedPage + 1;
    setState(() {
      _loadingMore = true;
      _moreError = null;
      _moreErrorCode = null;
    });
    try {
      final page = await fetchForumProfileThreads(_threadsUid, page: next);
      if (!mounted) return;
      setState(() {
        _more.addAll(page.threads);
        _morePages = next - 1;
        _hasMoreOverride = page.hasNext;
        _loadingMore = false;
      });
      _fillViewportIfNeeded();
    } catch (e) {
      if (!mounted) return;
      // 续页失败**不清空已加载的行**：底部提示 + 页脚变重试
      setState(() {
        _loadingMore = false;
        _moreError = e is YmHttpError ? e.message : '加载失败';
        _moreErrorCode = e is YmHttpError ? e.code : null;
      });
    }
  }

  /// 内容没铺满一屏时补一页（每页渲染后判一次，逐页推进，不写 while 循环）。
  void _fillViewportIfNeeded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loadingMore || !_hasMore || _moreError != null) return;
      if (!_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent <= 0) unawaited(_loadMore());
    });
  }

  /// 续页失败的出口：WAF 去过验证、登录失效去登录，其余原样重试**同一页**。
  Future<void> _retryMore() async {
    if (_loadingMore) return;
    if (_moreErrorCode == 'WAF') {
      await openForumWafVerifyPage(context);
    } else if (_moreErrorCode == 'LOGIN_REQUIRED') {
      await Navigator.of(context).push(
        ymRoute(const ForumLoginPage(), snapshot: false),
      );
    }
    if (!mounted) return;
    setState(() {
      _moreError = null;
      _moreErrorCode = null;
    });
    await _loadMore();
  }

  /* ------------------------------ 构建 ------------------------------ */

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const YmTopBar(leading: YmBackButton(), title: '个人资料'),
          Expanded(
            child: YmAsync<_ProfileBundle>(
              key: _asyncKey,
              load: _load,
              errorTitle: '资料加载失败',
              loginDesc: '登录后查看资料。',
              onLogin: _openLogin,
              onWaf: (ctx, reload) async {
                await openForumWafVerifyPage(ctx);
                reload();
              },
              builder: (context, data, reload) => _buildBody(context, data),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, _ProfileBundle data) {
    _adopt(data);
    final p = data.profile;
    final stats = _buildStats(context, p);
    final rows = <ForumThreadSummary>[
      ...?data.threads?.threads,
      ..._more,
    ];
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
        children: [
          YmForumProfileHead(profile: p),
          if (stats != null) ...[const SizedBox(height: 14), stats],
          const SizedBox(height: 14),
          _buildActions(
            context,
            p,
            self: _isSelf(p),
            hasThreads: rows.isNotEmpty,
          ),
          if (p.signature.isNotEmpty) ...[
            const SizedBox(height: 14),
            _SignatureCard(text: p.signature),
          ],
          if (p.fields.isNotEmpty) ...[
            const SizedBox(height: 14),
            _FieldsCard(fields: p.fields),
          ],
          if (rows.isNotEmpty) ...[
            const SizedBox(height: 14),
            _buildThreads(context, p, self: _isSelf(p), rows: rows),
          ],
          if (rows.isNotEmpty) _buildMoreFooter(context),
        ],
      ),
    );
  }

  /// 是不是「我自己」：页面自己印了 `设置` / `btn_exit` 就算，
  /// 另外 uid 与登录态一致也算——站点对 `mycenter=1` 会给 302 把参数丢掉，
  /// 自视角那一页不一定还带着这两个标记，只靠页面标记会把自己的页认成别人的。
  bool _isSelf(ForumProfile p) =>
      p.isSelf ||
      (p.uid.isNotEmpty && p.uid == ForumSession.account.value.uid);

  /// 三格：总积分 / 积分 / 对象。站点把「值」印在标签前，缺格整格不画——
  /// 一格都没有就整条不出现（不画空卡）。
  Widget? _buildStats(BuildContext context, ForumProfile p) {
    final c = YmScope.of(context).colors;
    final cells = <(String, int)>[
      if (p.totalPoints != null) ('总积分', p.totalPoints!),
      if (p.points != null) ('积分', p.points!),
      if (p.partner != null) ('对象', p.partner!),
    ];
    if (cells.isEmpty) return null;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(YmRadius.box),
        boxShadow: YmShadows.pop,
      ),
      child: Row(
        children: [
          for (final (label, value) in cells)
            Expanded(
              child: Column(
                children: [
                  Text(
                    '$value',
                    style: TextStyle(
                      fontSize: YmFont.strong17,
                      fontWeight: FontWeight.w800,
                      color: c.text,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    label,
                    style: TextStyle(fontSize: YmFont.micro11, color: c.text3),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 动作格：两列，自己的页是「设置资料 / 退出登录」，别人的页是
  /// 「主题 / 日志 / 短消息 / 加为好友」。
  ///
  /// 除「主题」是页内跳转，其余都走网页壳——资料页上的写操作要令牌，
  /// 而**别人**的资料页根本没有 formhash，只能在网页里做。
  Widget _buildActions(
    BuildContext context,
    ForumProfile p, {
    required bool self,
    required bool hasThreads,
  }) {
    final c = YmScope.of(context).colors;
    final uid = p.uid;
    final actions = <(String, VoidCallback?)>[];
    if (self) {
      actions.add((
        '设置资料',
        () => _openWeb('/home.php?mod=spacecp&mobile=2', '设置资料'),
      ));
      actions.add((
        '退出登录',
        p.formhash.isEmpty
            ? null
            : () => _openWeb(
                '/member.php?mod=logging&action=logout'
                '&formhash=${p.formhash}&mobile=2',
                '退出登录',
              ),
      ));
    } else {
      if (hasThreads) actions.add(('主题', _toThreads));
      if (uid.isNotEmpty) {
        actions.add((
          '日志',
          () => _openWeb(
            '/home.php?mod=space&uid=$uid&do=blog&mobile=2',
            '日志',
          ),
        ));
        actions.add((
          '短消息',
          () => _openWeb(
            '/home.php?mod=space&do=pm&subop=view&touid=$uid&mobile=2',
            '短消息',
          ),
        ));
        actions.add((
          '加为好友',
          () => _openWeb(
            '/home.php?mod=spacecp&ac=friend&op=add&uid=$uid'
            '&handlekey=addfriendhk_$uid&mobile=2',
            '加为好友',
          ),
        ));
      }
    }
    if (actions.isEmpty) return const SizedBox.shrink();

    final rows = <Widget>[];
    for (var i = 0; i < actions.length; i += 2) {
      if (i > 0) {
        rows.add(Divider(height: 1, thickness: 1, color: c.borderWeak));
      }
      final left = actions[i];
      final right = i + 1 < actions.length ? actions[i + 1] : null;
      rows.add(
        Row(
          children: [
            _actionCell(c, left.$1, left.$2),
            if (right != null) ...[
              Container(width: 1, height: 22, color: c.borderWeak),
              _actionCell(c, right.$1, right.$2),
            ] else
              const Spacer(),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(YmRadius.box),
        boxShadow: YmShadows.pop,
      ),
      child: Column(children: rows),
    );
  }

  Widget _actionCell(YmColors c, String label, VoidCallback? onTap) {
    return Expanded(
      child: YmPressable(
        kind: YmPressKind.row,
        radius: BorderRadius.circular(YmRadius.inner),
        onTap: onTap,
        enabled: onTap != null,
        child: SizedBox(
          height: 46,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: YmFont.body14,
                fontWeight: FontWeight.w700,
                color: onTap == null ? c.text3 : c.text,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// TA 的主题：第一页 20 条 + 已追加的页，点行进原生帖子页（与板块页同一入口）。
  Widget _buildThreads(
    BuildContext context,
    ForumProfile p, {
    required bool self,
    required List<ForumThreadSummary> rows,
  }) {
    final c = YmScope.of(context).colors;
    return Column(
      key: _threadsKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
          child: Text(
            self ? '我的主题' : 'TA 的主题',
            style: TextStyle(
              fontSize: YmFont.body15,
              fontWeight: FontWeight.w700,
              color: c.text,
            ),
          ),
        ),
        YmCardList(
          margin: EdgeInsets.zero,
          children: [
            for (final t in rows)
              YmForumThreadRow(
                thread: t,
                onTap: () => openForumThread(context, t),
              ),
          ],
        ),
      ],
    );
  }

  /// 页脚：还有下一页才挂；翻到底、或第一页就是最后一页时**一个都不出现**。
  ///
  /// 续页失败时保留已加载的行，页脚换成出口（WAF 去验证 / 登录失效去登录 / 重试）。
  Widget _buildMoreFooter(BuildContext context) {
    if (!_hasMore) return const SizedBox.shrink();
    final error = _moreError;
    if (error == null) {
      return YmLoadMore(
        loading: _loadingMore,
        hasMore: true,
        doneText: '',
        onTap: _loadMore,
      );
    }
    final label = switch (_moreErrorCode) {
      'WAF' => '去验证',
      'LOGIN_REQUIRED' => '去登录',
      _ => '重试',
    };
    return Column(
      children: [
        YmTip(error),
        _TextAction(label: label, onTap: _retryMore),
      ],
    );
  }
}

/// 资料 + 主题第一页：两次请求的结果装在一起交给界面。
class _ProfileBundle {
  const _ProfileBundle({required this.profile, required this.threads});

  final ForumProfile profile;

  /// null = 第一页没拿到（主题区整块不画）。
  final ForumUserThreads? threads;
}

/// 页脚文字动作（重试 / 去验证 / 去登录），与 `YmLoadMore` 的「加载更多」同档。
class _TextAction extends StatelessWidget {
  const _TextAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      margin: const EdgeInsets.fromLTRB(14, 6, 14, 0),
      alignment: Alignment.center,
      child: YmPressable(
        kind: YmPressKind.row,
        radius: BorderRadius.circular(YmRadius.ctrl),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            height: 44,
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: YmFont.sub13,
                  fontWeight: FontWeight.w700,
                  color: c.brandInk,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 文字动作（展开 / 收起），与帖子页「还有 N 条点评」同一档。
class _MoreAction extends StatelessWidget {
  const _MoreAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    return YmPressable(
      kind: YmPressKind.dim,
      dimOpacity: 0.6,
      radius: BorderRadius.circular(YmRadius.chip),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text(
          label,
          style: TextStyle(
            fontSize: YmFont.small12,
            fontWeight: FontWeight.w700,
            color: c.brand,
          ),
        ),
      ),
    );
  }
}

/// 签名卡：非空才出现，超过 6 行折起来。
class _SignatureCard extends StatefulWidget {
  const _SignatureCard({required this.text});

  final String text;

  @override
  State<_SignatureCard> createState() => _SignatureCardState();
}

class _SignatureCardState extends State<_SignatureCard> {
  static const int _maxLines = 6;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final style = TextStyle(
      fontSize: YmFont.sub13,
      height: 1.7,
      color: c.text2,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(YmRadius.box),
        boxShadow: YmShadows.pop,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 折几行由实际排版决定（不按字数猜）：量一遍 6 行放不放得下
          final painter = TextPainter(
            text: TextSpan(text: widget.text, style: style),
            maxLines: _maxLines,
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: constraints.maxWidth);
          final overflows = painter.didExceedMaxLines;
          final folded = overflows && !_expanded;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '个人签名',
                style: TextStyle(
                  fontSize: YmFont.micro11,
                  fontWeight: FontWeight.w700,
                  color: c.text3,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                widget.text,
                style: style,
                maxLines: folded ? _maxLines : null,
                overflow: folded ? TextOverflow.ellipsis : TextOverflow.clip,
              ),
              if (overflows) ...[
                const SizedBox(height: 6),
                _MoreAction(
                  label: _expanded ? '收起' : '展开',
                  onTap: () => setState(() => _expanded = !_expanded),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// 资料表：两列（标签 / 值），站点原文照排，默认 8 行，超出可展开。
class _FieldsCard extends StatefulWidget {
  const _FieldsCard({required this.fields});

  final List<ForumProfileField> fields;

  @override
  State<_FieldsCard> createState() => _FieldsCardState();
}

class _FieldsCardState extends State<_FieldsCard> {
  static const int _maxRows = 8;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = YmScope.of(context).colors;
    final fold = widget.fields.length > _maxRows;
    final rows = fold && !_expanded
        ? widget.fields.take(_maxRows).toList()
        : widget.fields;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(YmRadius.box),
        boxShadow: YmShadows.pop,
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: 14,
                endIndent: 14,
                color: c.borderWeak,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      rows[i].label,
                      style: TextStyle(fontSize: YmFont.small12, color: c.text3),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      rows[i].value,
                      style: TextStyle(
                        fontSize: YmFont.sub13,
                        height: 1.5,
                        color: c.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (fold)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _MoreAction(
                  label: _expanded ? '收起' : '展开全部 ${widget.fields.length} 行',
                  onTap: () => setState(() => _expanded = !_expanded),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
